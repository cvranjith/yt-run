//
//  EnergyLedgerManager.swift
//  YTRun
//

import Foundation
import Combine
import CoreMotion
import SwiftData

// A rolling, honesty-based balance of "earned" (steps + explicitly
// claimed exercise/run credit) vs "spent" (actual watch time) over a
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
@MainActor
final class EnergyLedgerManager: ObservableObject {
    @Published private(set) var balanceSeconds: Int = 0

    private let pedometer = CMPedometer()
    private var lastRefreshAt: Date?
    // CMPedometer queries aren't free (each one is a round trip to the
    // motion coprocessor) and `refresh` is driven by LockedView's 1-second
    // timer tick — without this, that'd mean `ledgerWindowDays` fresh
    // queries every single second.
    private static let minimumRefreshInterval: TimeInterval = 8

    func refresh(modelContext: ModelContext, settings: AppSettings, force: Bool = false) {
        guard settings.enableEnergyLedger else { return }
        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Self.minimumRefreshInterval {
            return
        }
        lastRefreshAt = Date()

        let calendar = Calendar.current
        let windowDays = max(1, settings.ledgerWindowDays)
        let today = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else { return }

        let watchSegments = (try? modelContext.fetch(FetchDescriptor<WatchSegment>())) ?? []
        let ledgerEvents = (try? modelContext.fetch(FetchDescriptor<LedgerEvent>())) ?? []

        let watchedByDay = Dictionary(grouping: watchSegments.filter { $0.date >= windowStart }) {
            calendar.startOfDay(for: $0.date)
        }.mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }

        let eventsByDay = Dictionary(grouping: ledgerEvents.filter { $0.date >= windowStart }) {
            calendar.startOfDay(for: $0.date)
        }.mapValues { $0.reduce(0) { $0 + $1.seconds } }

        let stepsPerCreditSet = max(1, settings.stepsPerCreditSet)
        let secondsPerStepCredit = settings.secondsPerStepCredit

        var dayStarts: [Date] = []
        var cursor = windowStart
        while cursor <= today {
            dayStarts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        queryDailySteps(dayStarts: dayStarts, calendar: calendar) { [weak self] stepsByDay in
            guard let self else { return }
            var total = 0
            for day in dayStarts {
                let watched = watchedByDay[day] ?? 0
                let events = eventsByDay[day] ?? 0
                let steps = stepsByDay[day] ?? 0
                let stepSeconds = Int((Double(steps) / Double(stepsPerCreditSet)) * Double(secondsPerStepCredit))
                total += stepSeconds + events - watched
            }
            self.balanceSeconds = total
        }
    }

    // One `queryPedometerData` call per day in the window, chained rather
    // than fired in parallel — CMPedometer serializes overlapping queries
    // internally anyway, and this keeps the completion bookkeeping simple.
    // A day CMPedometer has no data for (commonly anything past its
    // ~7-day retention) just contributes 0, not an error.
    private func queryDailySteps(dayStarts: [Date], calendar: Calendar, completion: @escaping ([Date: Int]) -> Void) {
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
            pedometer.queryPedometerData(from: dayStart, to: dayEnd) { data, _ in
                Task { @MainActor in
                    result[dayStart] = data?.numberOfSteps.intValue ?? 0
                    step(index + 1)
                }
            }
        }
        step(0)
    }
}
