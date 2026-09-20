//
//  StairClimbCounter.swift
//  YTRun
//

import Foundation
import Combine
import CoreMotion

// Counts flights of stairs climbed via CMPedometer's barometer-based
// floor count — the same signal Apple's own Fitness app uses for
// "Flights Climbed." No camera, no Vision, no particular phone
// position needed at all: just carry the phone as normal and climb.
//
// Uses the same `startUpdates` live-stream approach WalkModeManager
// settled on rather than periodic short-window queries — confirmed by
// hand for step counting that a short query window misses data due to
// CMPedometer's own internal reporting lag; no reason to expect floor
// counting (built on the same underlying pipeline) to behave any
// better with that approach.
@MainActor
final class StairClimbCounter: ObservableObject {
    @Published private(set) var floorsAscended = 0
    // False only if this device genuinely has no barometer (very old
    // hardware) — surfaced so the view can explain why nothing's
    // counting rather than just silently sitting at zero forever.
    @Published private(set) var isAvailable = true

    private let pedometer = CMPedometer()
    private var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        floorsAscended = 0

        guard CMPedometer.isFloorCountingAvailable() else {
            isAvailable = false
            return
        }
        isAvailable = true
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            let floors = data.floorsAscended?.intValue ?? 0
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.floorsAscended = floors
            }
        }
    }

    func stop() {
        isActive = false
        pedometer.stopUpdates()
    }

    func reset() {
        guard isActive else {
            floorsAscended = 0
            return
        }
        // Restarts the live-update window from now, so the running
        // count really goes back to zero instead of just being
        // relabeled — `startUpdates` reports a cumulative count from
        // whatever start date it was given.
        stop()
        start()
    }
}
