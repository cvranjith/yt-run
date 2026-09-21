//
//  HabitType.swift
//  YTRun
//

import Foundation
import SwiftData

// A habit — logging one just inserts a `LedgerEvent` with this habit's
// `secondsPerLog` (see `HabitsView`), the exact same shape a push-up/
// stairs/run claim already uses. `secondsPerLog` is signed: positive
// for something you want to reward yourself for, negative for
// something you want to feel a cost from — one tap, no set/threshold
// concept the way the camera-tracked exercises have.
//
// Exactly one row has `isSystem == true` — the predefined "Late-Night
// Penalty," seeded by `ensureSystemLateNightHabit(modelContext:)`. For
// that row, `secondsPerLog` means something different: "penalty seconds
// per minute watched" during `startHour`..<`endHour`, applied
// automatically by `EnergyLedgerManager` from `WatchSegment` timestamps
// rather than logged by tapping — `startHour`/`endHour`/`isEnabled`
// only mean anything for this one row. Everything else in `HabitsView`
// is a plain manual, tap-to-log habit.
@Model
final class HabitType {
    var name: String
    var secondsPerLog: Int
    var isSystem: Bool = false
    var isEnabled: Bool = true
    var startHour: Int?
    var endHour: Int?
    var createdAt: Date

    init(
        name: String,
        secondsPerLog: Int,
        isSystem: Bool = false,
        isEnabled: Bool = true,
        startHour: Int? = nil,
        endHour: Int? = nil,
        createdAt: Date = .now
    ) {
        self.name = name
        self.secondsPerLog = secondsPerLog
        self.isSystem = isSystem
        self.isEnabled = isEnabled
        self.startHour = startHour
        self.endHour = endHour
        self.createdAt = createdAt
    }

    // Self-healing seed — call from anywhere that's about to read or
    // display the system habit (`EnergyLedgerManager.refresh()`,
    // `HabitsView.onAppear`), so it exists no matter which one runs
    // first. Cheap to call repeatedly: a no-op once the row exists.
    static func ensureSystemLateNightHabit(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<HabitType>(predicate: #Predicate { $0.isSystem })
        guard (try? modelContext.fetch(descriptor))?.isEmpty ?? true else { return }
        modelContext.insert(HabitType(
            name: "Late-Night Penalty",
            secondsPerLog: 60,
            isSystem: true,
            isEnabled: false,
            startHour: 22,
            endHour: 5
        ))
    }
}
