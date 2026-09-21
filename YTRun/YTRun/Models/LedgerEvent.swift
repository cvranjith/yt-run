//
//  LedgerEvent.swift
//  YTRun
//

import Foundation
import SwiftData

// One earn or adjustment event feeding `EnergyLedgerManager`'s rolling
// balance — a real reward claim (push-ups/sit-ups/lunges/stairs/a
// qualifying run) records a positive entry here alongside the existing
// `UsageTracker.completeExerciseReward` call that actually unlocks
// playback; a finished Walk-mode session records a *negative* entry
// equal to the steps it already spent live, so those steps don't also
// get counted as passive daily step credit. Deliberately never written
// from the Locked screen's "Use Credit" button — that omission is what
// lets spending it show up as a deficit once the resulting watch time
// lands in `WatchSegment`.
@Model
final class LedgerEvent {
    var date: Date
    var seconds: Int
    var note: String

    init(date: Date, seconds: Int, note: String) {
        self.date = date
        self.seconds = seconds
        self.note = note
    }
}
