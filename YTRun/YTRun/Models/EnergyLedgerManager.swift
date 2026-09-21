//
//  EnergyLedgerManager.swift
//  YTRun
//

import Foundation
import Combine
import CoreMotion
import SwiftData

// A rolling, honesty-based balance of "earned" (steps + explicitly
// claimed exercise/run credit made while *not* locked out — see
// `UsageTracker.isLockedOut`) vs "spent" (actual watch time) over a
// trailing window of days — entirely separate from `UsageTracker`'s
// hard daily/binge gates, which this never touches. It only powers a
// display and the Locked screen's "Use Credit" spend, both read-only
// consumers of `balanceSeconds` — nothing here blocks playback by
// itself.
//
// Recomputed from source data on each `refresh` rather than
// incrementally maintained, since the sources themselves
// (`WatchSegment`, `LedgerEvent`, CMPedometer's own daily history) are
// already the durable record — there's nothing to gain from also
// caching a running total that could drift out of sync with them.
// One day's slice of the ledger — everything the Home dashboard needs
// to show a single day's numbers, whether that's today or a day being
// browsed via the trend chart's prev/next navigation.
struct EnergyLedgerDayStats {
    var earnedSeconds = 0
    var spentSeconds = 0
    var netSeconds = 0
    var stepCount = 0
    var videoCount = 0
    var lateNightPenaltySeconds = 0
}

@MainActor
final class EnergyLedgerManager: ObservableObject {
    @Published private(set) var balanceSeconds: Int = 0
    // Every day in the current window, keyed by its `startOfDay` — lets
    // the Home dashboard show any single day's numbers (today or one
    // navigated to via the trend chart), not just today's.
    @Published private(set) var dailyStats: [Date: EnergyLedgerDayStats] = [:]
    // Today's slice of the same computation `refresh` already does for
    // the whole window — captured for free from that same loop rather
    // than a second pass, for the Home screen's balance-sheet card.
    @Published private(set) var todayEarnedSeconds: Int = 0
    @Published private(set) var todaySpentSeconds: Int = 0
    @Published private(set) var todayStepCount: Int = 0
    @Published private(set) var todayCreditEvents: [(note: String, seconds: Int, source: LedgerEventSource)] = []
    @Published private(set) var todayLateNightPenaltySeconds: Int = 0
    // The whole window's per-day nets, not just their sum — for the Home
    // screen's 7-day trend chart. A red day's contribution simply stops
    // being included once it ages out of the window; there's no separate
    // "carry the penalty forward" step, since `balanceSeconds` is already
    // just the sum of these.
    @Published private(set) var dailyNets: [(day: Date, seconds: Int)] = []

    private let pedometer = CMPedometer()
    private var lastRefreshAt: Date?
    // CMPedometer queries aren't free (each one is a round trip to the
    // motion coprocessor) and `refresh` is driven by LockedView's 1-second
    // timer tick — without this, that'd mean `ledgerWindowDays` fresh
    // queries every single second.
    private static let minimumRefreshInterval: TimeInterval = 8

    func refresh(modelContext: ModelContext, settings: AppSettings, force: Bool = false) {
        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Self.minimumRefreshInterval {
            return
        }
        lastRefreshAt = Date()

        let calendar = Calendar.current
        let windowDays = max(1, settings.ledgerWindowDays)
        let today = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else { return }
        // "Reset Balance" (Settings) sets this to the exact moment it was
        // tapped — everything from before it is excluded, even earlier
        // *today*, not just whole days before it (rounding this down to
        // the start of its day would make a same-day reset a no-op for
        // today's own numbers, which is exactly the bug this fixes).
        // Non-destructive: no real `WatchSegment`/`LedgerEvent` row is
        // touched, so Daily History/Run History (reading those same
        // tables) are unaffected — only this ledger's filtering below
        // stops counting anything from before the cutoff.
        let cutoff = settings.ledgerStartDate.map { max(windowStart, $0) } ?? windowStart

        let watchSegments = (try? modelContext.fetch(FetchDescriptor<WatchSegment>())) ?? []
        let ledgerEvents = (try? modelContext.fetch(FetchDescriptor<LedgerEvent>())) ?? []

        let watchedByDay = Dictionary(grouping: watchSegments.filter { $0.date >= cutoff }) {
            calendar.startOfDay(for: $0.date)
        }.mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }

        let eventsByDay = Dictionary(grouping: ledgerEvents.filter { $0.date >= cutoff }) {
            calendar.startOfDay(for: $0.date)
        }.mapValues { $0.reduce(0) { $0 + $1.seconds } }

        let videoCountByDay = Dictionary(grouping: watchSegments.filter { $0.date >= cutoff }) {
            calendar.startOfDay(for: $0.date)
        }.mapValues { Set($0.compactMap(\.videoURL)).count }

        let stepsPerCreditSet = max(1, settings.stepsPerCreditSet)
        let secondsPerStepCredit = settings.secondsPerStepCredit

        // The predefined "Late-Night Penalty" system habit (see
        // `HabitType`) — self-heals via `ensureSystemLateNightHabit` in
        // case this is the first place that's ever needed it.
        HabitType.ensureSystemLateNightHabit(modelContext: modelContext)
        let lateNightHabit = (try? modelContext.fetch(FetchDescriptor<HabitType>(predicate: #Predicate { $0.isSystem })))?.first

        // Approximated by each segment's *start* hour, same as
        // `UsageBreakdownView`'s time-of-day split — segments are
        // typically many seconds long and rarely straddle the window's
        // edge, so this is close enough without minute-level splitting.
        let lateNightByDay: [Date: Int]
        if let lateNightHabit, lateNightHabit.isEnabled, let start = lateNightHabit.startHour, let end = lateNightHabit.endHour {
            func isLateNightHour(_ hour: Int) -> Bool {
                guard start != end else { return false }
                return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
            }
            lateNightByDay = Dictionary(grouping: watchSegments.filter {
                $0.date >= cutoff && isLateNightHour(calendar.component(.hour, from: $0.date))
            }) {
                calendar.startOfDay(for: $0.date)
            }.mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        } else {
            lateNightByDay = [:]
        }
        let penaltySecondsPerMinute = lateNightHabit?.secondsPerLog ?? 0

        var dayStarts: [Date] = []
        var cursor = windowStart
        while cursor <= today {
            dayStarts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let todayEvents = ledgerEvents.filter { calendar.isDate($0.date, inSameDayAs: today) }
            .map { (note: $0.note, seconds: $0.seconds, source: $0.sourceKind) }

        queryDailySteps(dayStarts: dayStarts, cutoff: cutoff, calendar: calendar) { [weak self] stepsByDay in
            guard let self else { return }
            var total = 0
            var nets: [(day: Date, seconds: Int)] = []
            var stats: [Date: EnergyLedgerDayStats] = [:]
            for day in dayStarts {
                let watched = watchedByDay[day] ?? 0
                let events = eventsByDay[day] ?? 0
                let steps = stepsByDay[day] ?? 0
                let stepSeconds = Int((Double(steps) / Double(stepsPerCreditSet)) * Double(secondsPerStepCredit))
                let lateNightSeconds = lateNightByDay[day] ?? 0
                let penalty = -Int((Double(lateNightSeconds) / 60.0) * Double(penaltySecondsPerMinute))
                let net = stepSeconds + events - watched + penalty
                total += net
                nets.append((day: day, seconds: net))
                stats[day] = EnergyLedgerDayStats(
                    earnedSeconds: stepSeconds + events,
                    spentSeconds: watched - penalty,
                    netSeconds: net,
                    stepCount: steps,
                    videoCount: videoCountByDay[day] ?? 0,
                    lateNightPenaltySeconds: penalty
                )
                if day == today {
                    // Matches the same shape as `net` above, just for
                    // today alone — so "Earned − Spent" on the Home card
                    // always agrees with the rolling balance's today-
                    // contribution. `events` can include a negative
                    // Walk-mode deduction; that shows up as its own line
                    // item on the credit breakdown screen rather than
                    // being hidden here.
                    self.todayEarnedSeconds = stepSeconds + events
                    self.todaySpentSeconds = watched
                    self.todayStepCount = steps
                    self.todayLateNightPenaltySeconds = penalty
                }
            }
            self.todayCreditEvents = todayEvents
            self.dailyNets = nets
            self.dailyStats = stats
            self.balanceSeconds = total
        }
    }

    // For a day that's aged out of the current window (older than
    // `ledgerWindowDays`, or before a "Reset Balance" cutoff) there's
    // nothing to show — the Home dashboard's day navigation stops there
    // rather than displaying a misleading zeroed-out day.
    func stats(for day: Date) -> EnergyLedgerDayStats? {
        dailyStats[Calendar.current.startOfDay(for: day)]
    }

    // Non-destructive: sets the window's floor to right now rather than
    // deleting any `WatchSegment`/`LedgerEvent` row, so Daily History and
    // Run History (which read those same tables) are completely
    // unaffected — only this ledger's own rolling balance stops counting
    // anything from before this moment.
    func resetBalance(settings: AppSettings, modelContext: ModelContext) {
        settings.ledgerStartDate = Date()
        refresh(modelContext: modelContext, settings: settings, force: true)
    }

    // One `queryPedometerData` call per day in the window, chained rather
    // than fired in parallel — CMPedometer serializes overlapping queries
    // internally anyway, and this keeps the completion bookkeeping simple.
    // A day CMPedometer has no data for (commonly anything past its
    // ~7-day retention) just contributes 0, not an error.
    private func queryDailySteps(dayStarts: [Date], cutoff: Date, calendar: Calendar, completion: @escaping ([Date: Int]) -> Void) {
        guard CMPedometer.isStepCountingAvailable() else {
            completion([:])
            return
        }
        var result: [Date: Int] = [:]
        func step(_ index: Int) {
            guard index < dayStarts.count else {
                completion(result)
                return
            }
            let dayStart = dayStarts[index]
            let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart) ?? Date(), Date())
            // Clamped to `cutoff` for whichever day contains it (a same-
            // day "Reset Balance" must exclude steps taken earlier today
            // too, not just whole days before it).
            pedometer.queryPedometerData(from: max(dayStart, cutoff), to: dayEnd) { data, _ in
                Task { @MainActor in
                    result[dayStart] = data?.numberOfSteps.intValue ?? 0
                    step(index + 1)
                }
            }
        }
        step(0)
    }
}
