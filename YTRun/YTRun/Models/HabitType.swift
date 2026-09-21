//
//  HabitType.swift
//  YTRun
//

import Foundation
import SwiftData

// A user-defined habit — logging one just inserts a `LedgerEvent` with
// this habit's `secondsPerLog` (see `HabitsView`), the exact same shape
// a push-up/stairs/run claim already uses. `secondsPerLog` is signed:
// positive for something you want to reward yourself for, negative for
// something you want to feel a cost from — one tap, no set/threshold
// concept the way the camera-tracked exercises have.
@Model
final class HabitType {
    var name: String
    var secondsPerLog: Int
    var createdAt: Date

    init(name: String, secondsPerLog: Int, createdAt: Date = .now) {
        self.name = name
        self.secondsPerLog = secondsPerLog
        self.createdAt = createdAt
    }
}
