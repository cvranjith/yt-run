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
// for "did you take steps in the last N seconds", and it has a
// pleasant side effect for the "not driving" requirement: sitting in a
// moving vehicle doesn't generate footstep-like accelerometer
// signatures, so it naturally reads as "not moving" without needing a
// separate vehicle classifier at all.
@MainActor
final class WalkModeManager: ObservableObject {
    @Published private(set) var isActive = false
    // Whether the most recent periodic check found you moving. Starts
    // `true` the moment a session begins (optimistic) so there's no
    // false "not moving" pause before the first real check has had a
    // chance to run.
    @Published private(set) var isCurrentlyMoving = true

    private let pedometer = CMPedometer()
    private var timer: Timer?

    // How far back each check looks, and how often it runs — same
    // number by design (each check covers exactly the gap since the
    // last one), not tunable from Settings since this is meant to be a
    // sensible fixed default rather than another dial to expose.
    private static let checkIntervalSeconds: TimeInterval = 30
    // Deliberately low — this only needs to rule out "sitting still"
    // (or being driven), not measure a real pace. A brief pause at a
    // crosswalk mid-window shouldn't read as "stopped walking."
    private static let minimumStepsToCountAsMoving = 8

    func start() {
        guard !isActive else { return }
        isActive = true
        isCurrentlyMoving = true
        scheduleNextCheck()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCheck() }
        }
    }

    private func runCheck() {
        guard isActive, CMPedometer.isStepCountingAvailable() else { return }
        let windowStart = Date().addingTimeInterval(-Self.checkIntervalSeconds)
        pedometer.queryPedometerData(from: windowStart, to: Date()) { [weak self] data, _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                let steps = data?.numberOfSteps.intValue ?? 0
                self.isCurrentlyMoving = steps >= Self.minimumStepsToCountAsMoving
            }
        }
    }
}
