//
//  WalkModeManager.swift
//  YTRun
//

import Foundation
import Combine
import CoreMotion

// A live, self-revoking alternative to the Locked screen's normal
// daily/binge wall: while active, playback is allowed for as long as
// you're actually moving, checked periodically — no distance/duration
// threshold to hit, nothing banked or saved, no interaction with
// UsageTracker's allowance math at all. Starting/stopping this is
// entirely separate from RunTracker's own start/stop; the two don't
// share any state.
//
// Uses `CMPedometer` rather than `CMMotionActivityManager` — simpler
// for "are you currently taking steps", and it has a pleasant side
// effect for the "not driving" requirement: sitting in a moving
// vehicle doesn't generate footstep-like accelerometer signatures, so
// it naturally reads as "not moving" without needing a separate
// vehicle classifier at all.
//
// Built on `startUpdates` (a live stream) rather than repeatedly
// calling `queryPedometerData` for a short trailing window — confirmed
// by hand that the latter doesn't work well here: CMPedometer has real
// internal reporting lag (it batches/confirms steps before counting
// them), so a short query window can miss steps that already happened
// but aren't "confirmed" yet, causing both a slow start *and* false
// "stopped" reads during genuinely continuous walking. Reacting to the
// live stream avoids that: "are you moving" flips true the instant a
// new step is reported (as fast as the OS reports it, not gated by a
// query window), and "stopped" is a separate, independently-tunable
// question — has too long passed since the last reported step.
@MainActor
final class WalkModeManager: ObservableObject {
    @Published private(set) var isActive = false
    // Starts `true` the moment a session begins (optimistic) so there's
    // no false "not moving" pause before the first real step has had a
    // chance to be reported.
    @Published private(set) var isCurrentlyMoving = true

    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private var watchdogTimer: Timer?
    private var lastKnownStepCount = 0
    private var lastStepDate = Date()
    // CMPedometer's step algorithm can be fooled by a phone lying on a
    // hard surface with audio playing — the speaker's own vibration
    // occasionally reads as a phantom footstep, resetting `lastStepDate`
    // and keeping the stillness timeout from ever firing. A single
    // confident "stationary" classification from CMMotionActivityManager
    // (which weighs the fuller motion signature, not just step-like
    // spikes) overrides that regardless of how recent a "step" was.
    // Deliberately not required for detecting the *start* of movement —
    // only used as a veto — since its classifications land a beat slower
    // than a fresh pedometer step and gating resume on it would
    // reintroduce the slow-start problem this manager was rewritten to
    // avoid.
    private var isConfidentlyStationary = false

    // How long with no new reported step before considering yourself
    // stopped. Independent of how fast "moving" is detected (that's
    // just "did a step arrive"), so this can be tuned purely for false-
    // stop avoidance without also slowing down how fast a resume is
    // noticed the way a single shared window/interval did before.
    private static let stillnessTimeoutSeconds: TimeInterval = 8
    // Cheap (just a Date comparison, no query) — checked often for a
    // responsive stop without any real cost.
    private static let watchdogIntervalSeconds: TimeInterval = 2

    func start() {
        guard !isActive else { return }
        isActive = true
        isCurrentlyMoving = true
        lastKnownStepCount = 0
        lastStepDate = Date()
        isConfidentlyStationary = false

        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if steps > self.lastKnownStepCount {
                    self.lastKnownStepCount = steps
                    self.lastStepDate = Date()
                    self.isCurrentlyMoving = true
                }
            }
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity, self.isActive else { return }
                // Low-confidence reads are common right as the
                // classifier is still gathering data — not trusted
                // enough on their own to override a fresh step.
                self.isConfidentlyStationary = activity.stationary && activity.confidence != .low
            }
        }

        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.watchdogIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStillness() }
        }
    }

    // Returns how many steps this session reported, so a caller can bank
    // that count elsewhere (see `EnergyLedgerManager`/`LedgerEvent`) before
    // it's overwritten by the next `start()`.
    @discardableResult
    func stop() -> Int {
        let steps = lastKnownStepCount
        isActive = false
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        return steps
    }

    private func checkStillness() {
        guard isActive else { return }
        let recentStep = Date().timeIntervalSince(lastStepDate) < Self.stillnessTimeoutSeconds
        isCurrentlyMoving = recentStep && !isConfidentlyStationary
    }
}
