//
//  UsageTracker.swift
//  YTRun
//

import Foundation
import Combine

// What a completed run (real or simulated) actually did — see
// `UsageTracker.completeRun`. The two effects are mutually exclusive: a
// run either tops up the daily allowance, or cuts a binge cooldown short,
// never both from the same run.
enum RunRewardOutcome: Equatable {
    case grantedDailyMinutes
    case clearedCooldown
}

// Tracks how much YouTube has actually been watched today, plus a
// "binge limit + cooldown" throttle: once you've watched
// `bingeLimitMinutes` cumulatively (pauses don't reset it), you're locked
// out for a fixed `cooldownMinutes` timer. Both limits live in
// `AppSettings`; this class only tracks the *usage* numbers and does the
// arithmetic against limits handed to it, so the two models stay decoupled
// and each stays easy to reason about on its own.
final class UsageTracker: ObservableObject {
    private enum Keys {
        static let todayUsedSeconds = "usage.todayUsedSeconds"
        static let bonusSecondsToday = "usage.bonusSecondsToday"
        static let lastResetDayStart = "usage.lastResetDayStart"
        static let bingeSecondsUsed = "usage.bingeSecondsUsed"
        static let cooldownEndsAt = "usage.cooldownEndsAt"
        static let lastPlaybackAt = "usage.lastPlaybackAt"
    }

    // Total seconds actually played today (only while a video is playing,
    // never while paused).
    @Published private(set) var todayUsedSeconds: Int

    // Extra seconds earned today via "Simulate Run" or a real qualifying
    // run (see `RunTracker`). This effectively extends today's daily
    // allowance without touching the binge/cooldown throttle below.
    @Published private(set) var bonusSecondsToday: Int

    // Cumulative seconds watched since the last cooldown (or new day) —
    // only advances while actually playing; pausing just stops it from
    // growing, it doesn't decay.
    @Published private(set) var bingeSecondsUsed: Int

    // When the current cooldown lockout ends, if one is active. `nil`
    // means "not in cooldown." Persisted so the lockout survives the app
    // being closed and reopened.
    @Published private(set) var cooldownEndsAt: Date?

    // The last time `recordTick` actually ran (i.e. last second of real
    // playback). Drives the inactivity-based binge reset below — a long
    // enough gap since this timestamp means a *partial* binge session
    // (one that never hit the limit) forgives itself.
    private var lastPlaybackAt: Date?

    private var lastResetDayStart: Date

    // Sub-second carry for weighted ticks (see `recordTick`) — e.g. at a
    // 50% rate, two real-second ticks are needed before a whole counted
    // second gets added to the totals. Intentionally not persisted:
    // losing under a second of fractional progress on app relaunch isn't
    // worth the complexity for a self-discipline tool.
    private var pendingWeightedSeconds: Double = 0

    init() {
        let defaults = UserDefaults.standard
        self.todayUsedSeconds = defaults.integer(forKey: Keys.todayUsedSeconds)
        self.bonusSecondsToday = defaults.integer(forKey: Keys.bonusSecondsToday)
        self.bingeSecondsUsed = defaults.integer(forKey: Keys.bingeSecondsUsed)
        self.cooldownEndsAt = defaults.object(forKey: Keys.cooldownEndsAt) as? Date
        self.lastPlaybackAt = defaults.object(forKey: Keys.lastPlaybackAt) as? Date

        if let storedStart = defaults.object(forKey: Keys.lastResetDayStart) as? Date {
            self.lastResetDayStart = storedStart
        } else {
            self.lastResetDayStart = Calendar.current.startOfDay(for: Date())
        }

        resetIfNewDay()
        refreshCooldownIfExpired()
    }

    // MARK: - Reading usage

    func remainingDailySeconds(dailyLimitMinutes: Int) -> Int {
        max(0, dailyLimitMinutes * 60 + bonusSecondsToday - todayUsedSeconds)
    }

    func isDailyLimitReached(dailyLimitMinutes: Int) -> Bool {
        remainingDailySeconds(dailyLimitMinutes: dailyLimitMinutes) <= 0
    }

    var isInCooldown: Bool {
        cooldownEndsAt != nil
    }

    // How much more can be watched before the binge limit triggers a
    // cooldown. Returns 0 while already in cooldown.
    func bingeRemainingSeconds(bingeLimitMinutes: Int) -> Int {
        guard !isInCooldown else { return 0 }
        return max(0, bingeLimitMinutes * 60 - bingeSecondsUsed)
    }

    // How long until the current cooldown lifts, for display on the
    // Locked screen (e.g. "back at 11:00").
    func cooldownRemainingSeconds() -> Int {
        guard let cooldownEndsAt else { return 0 }
        return max(0, Int(cooldownEndsAt.timeIntervalSinceNow))
    }

    // Whether a "remaining" readout should be shown as a warning — used by
    // both the Home screen and the YouTube screen's toolbar so the
    // threshold only lives in one place.
    static func isCritical(remainingSeconds: Int, limitSeconds: Int) -> Bool {
        guard limitSeconds > 0 else { return remainingSeconds <= 0 }
        return remainingSeconds <= 0 || Double(remainingSeconds) <= Double(limitSeconds) * 0.2
    }

    // MARK: - Recording usage

    // Called once per second while a video is actually playing. `weight`
    // is how much of that real second counts toward the daily/binge
    // totals — 1.0 for foreground viewing, lower for background
    // listen/car (see `AppSettings.listenRatePercent`/`carRatePercent`).
    // Sub-1-second weighted amounts accumulate in `pendingWeightedSeconds`
    // until they cross a whole second, rather than being dropped.
    func recordTick(weight: Double, bingeLimitMinutes: Int, cooldownMinutes: Int, bingeResetAfterMinutes: Int) {
        resetIfNewDay()
        refreshBingeState(bingeResetAfterMinutes: bingeResetAfterMinutes)
        guard !isInCooldown else { return }

        // Real activity happened this tick regardless of weight, so the
        // inactivity clock for binge-reset should reflect it even if it
        // didn't cross a whole counted second yet.
        let now = Date()
        lastPlaybackAt = now
        UserDefaults.standard.set(now, forKey: Keys.lastPlaybackAt)

        pendingWeightedSeconds += weight
        let wholeSeconds = Int(pendingWeightedSeconds)
        guard wholeSeconds > 0 else { return }
        pendingWeightedSeconds -= Double(wholeSeconds)

        todayUsedSeconds += wholeSeconds
        UserDefaults.standard.set(todayUsedSeconds, forKey: Keys.todayUsedSeconds)

        bingeSecondsUsed += wholeSeconds
        UserDefaults.standard.set(bingeSecondsUsed, forKey: Keys.bingeSecondsUsed)

        if bingeSecondsUsed >= bingeLimitMinutes * 60 {
            let endsAt = now.addingTimeInterval(TimeInterval(cooldownMinutes * 60))
            cooldownEndsAt = endsAt
            UserDefaults.standard.set(endsAt, forKey: Keys.cooldownEndsAt)
        }
    }

    // Re-checks time-based state that can change even without a new tick:
    // clears an expired cooldown, AND resets the binge counter after a
    // long-enough break even if the limit was never actually hit (see
    // `AppSettings.bingeResetAfterMinutes`). Views that just *display*
    // remaining time (rather than actively playing) call this
    // periodically so both the countdown/unlock and the binge number stay
    // live instead of looking frozen.
    func refreshBingeState(bingeResetAfterMinutes: Int) {
        resetIfNewDay()
        refreshCooldownIfExpired()
        guard !isInCooldown else { return }

        if let lastPlaybackAt, Date().timeIntervalSince(lastPlaybackAt) >= TimeInterval(bingeResetAfterMinutes * 60) {
            bingeSecondsUsed = 0
            UserDefaults.standard.set(0, forKey: Keys.bingeSecondsUsed)
        }
    }

    private func refreshCooldownIfExpired() {
        guard let cooldownEndsAt, Date() >= cooldownEndsAt else { return }

        self.cooldownEndsAt = nil
        bingeSecondsUsed = 0
        UserDefaults.standard.removeObject(forKey: Keys.cooldownEndsAt)
        UserDefaults.standard.set(0, forKey: Keys.bingeSecondsUsed)
    }

    // Called by both the "Simulate Run" button and a real qualifying run
    // (see `RunTracker`). The two effects are mutually exclusive:
    // - If a binge cooldown is currently active, the run's only effect is
    //   ending it early — it does NOT also add daily bonus minutes.
    // - Otherwise (locked on the daily total, or just running proactively
    //   with nothing active), the run extends today's daily allowance.
    @discardableResult
    func completeRun(minutes: Int) -> RunRewardOutcome {
        completeExerciseReward(seconds: minutes * 60)
    }

    // Same mutually-exclusive cooldown-vs-daily-allowance rule as
    // `completeRun`, generalized to whatever exercise is granting the
    // reward (push-ups, and whatever else gets added later) — expressed
    // in seconds rather than whole minutes, since a rep-count-based
    // reward (e.g. 120s per 5 push-ups) doesn't always land on a clean
    // minute boundary the way a run's reward setting does.
    @discardableResult
    func completeExerciseReward(seconds: Int) -> RunRewardOutcome {
        resetIfNewDay()
        refreshCooldownIfExpired()

        if isInCooldown {
            endCooldown()
            return .clearedCooldown
        } else {
            grantBonusSeconds(seconds)
            return .grantedDailyMinutes
        }
    }

    // Ends an active cooldown early without touching the daily bonus.
    private func endCooldown() {
        cooldownEndsAt = nil
        bingeSecondsUsed = 0
        UserDefaults.standard.removeObject(forKey: Keys.cooldownEndsAt)
        UserDefaults.standard.set(0, forKey: Keys.bingeSecondsUsed)
    }

    // Extends today's daily allowance without touching the binge/cooldown
    // throttle. Private — always go through `completeRun`/
    // `completeExerciseReward` so the mutual-exclusivity rule above
    // can't be bypassed by accident.
    private func grantBonusSeconds(_ seconds: Int) {
        bonusSecondsToday += seconds
        UserDefaults.standard.set(bonusSecondsToday, forKey: Keys.bonusSecondsToday)
    }

    // Undoes the `.grantedDailyMinutes` outcome of `completeRun` — used
    // when a run is discarded rather than saved, so a run you said "never
    // happened" doesn't quietly leave you with free minutes. There's
    // nothing to undo for a `.clearedCooldown` outcome — the cooldown just
    // stays ended (restoring it would need to reconstruct a lockout time
    // we no longer have).
    func revokeBonusMinutes(_ minutes: Int) {
        resetIfNewDay()

        bonusSecondsToday = max(0, bonusSecondsToday - minutes * 60)
        UserDefaults.standard.set(bonusSecondsToday, forKey: Keys.bonusSecondsToday)
    }

    // Wired to Settings' "Reset today's usage" — clears used time, bonus,
    // and any active cooldown, back to a clean slate.
    func resetToday() {
        todayUsedSeconds = 0
        bonusSecondsToday = 0
        bingeSecondsUsed = 0
        cooldownEndsAt = nil
        lastPlaybackAt = nil
        pendingWeightedSeconds = 0
        UserDefaults.standard.set(0, forKey: Keys.todayUsedSeconds)
        UserDefaults.standard.set(0, forKey: Keys.bonusSecondsToday)
        UserDefaults.standard.set(0, forKey: Keys.bingeSecondsUsed)
        UserDefaults.standard.removeObject(forKey: Keys.cooldownEndsAt)
        UserDefaults.standard.removeObject(forKey: Keys.lastPlaybackAt)
    }

    // MARK: - Day rollover

    private func resetIfNewDay() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard todayStart != lastResetDayStart else { return }

        lastResetDayStart = todayStart
        todayUsedSeconds = 0
        bonusSecondsToday = 0
        bingeSecondsUsed = 0
        cooldownEndsAt = nil
        lastPlaybackAt = nil
        pendingWeightedSeconds = 0
        UserDefaults.standard.set(0, forKey: Keys.todayUsedSeconds)
        UserDefaults.standard.set(0, forKey: Keys.bonusSecondsToday)
        UserDefaults.standard.set(0, forKey: Keys.bingeSecondsUsed)
        UserDefaults.standard.removeObject(forKey: Keys.cooldownEndsAt)
        UserDefaults.standard.removeObject(forKey: Keys.lastPlaybackAt)
        UserDefaults.standard.set(todayStart, forKey: Keys.lastResetDayStart)
    }
}
