//
//  LedgerEvent.swift
//  YTRun
//

import Foundation
import SwiftData

// Which reward/habit produced a `LedgerEvent` — lets breakdown screens
// (`CreditBreakdownView`, `HabitsView`) group and filter entries
// reliably instead of guessing from `note`'s free text. Stored as a
// plain `String` on the model (see `LedgerEvent.source`) rather than
// this enum directly, so an unrecognized/future value never fails to
// load old data — `.other` is the fallback.
enum LedgerEventSource: String {
    case pushUps, sitUps, lunges, stairs, run, walk, habit, other

    var displayName: String {
        switch self {
        case .pushUps: return "Push-Ups"
        case .sitUps: return "Sit-Ups"
        case .lunges: return "Lunges"
        case .stairs: return "Stairs"
        case .run: return "Run"
        case .walk: return "Walk"
        case .habit: return "Habits"
        case .other: return "Other"
        }
    }
}

// One earn or adjustment event feeding `EnergyLedgerManager`'s rolling
// balance — a real reward claim (push-ups/sit-ups/lunges/stairs/a run)
// records a positive entry here alongside the existing `UsageTracker
// .completeExerciseReward` call that actually unlocks playback, when
// claimed while *not* locked out (see `UsageTracker.isLockedOut`); a
// finished Walk-mode session records a *negative* entry equal to the
// steps it already spent live, so those steps don't also get counted
// as passive daily step credit; logging a habit (see `HabitsView`)
// records one too. Deliberately never written from the Locked screen's
// "Use Credit" button — that omission is what lets spending it show up
// as a deficit once the resulting watch time lands in `WatchSegment`.
@Model
final class LedgerEvent {
    var date: Date
    var seconds: Int
    var note: String
    var source: String = LedgerEventSource.other.rawValue

    init(date: Date, seconds: Int, note: String, source: LedgerEventSource = .other) {
        self.date = date
        self.seconds = seconds
        self.note = note
        self.source = source.rawValue
    }

    var sourceKind: LedgerEventSource {
        LedgerEventSource(rawValue: source) ?? .other
    }
}
