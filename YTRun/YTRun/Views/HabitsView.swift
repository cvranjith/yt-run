//
//  HabitsView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Purely a logging surface — defining habits (the predefined "Late-
// Night Penalty" and anything of your own) happens on the Habits
// screen under Settings (`HabitSettingsView`); this is just where you
// tap to log one, and see/undo today's log so an accidental tap isn't
// stuck there for the rest of the day.
struct HabitsView: View {
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HabitType.createdAt) private var allHabits: [HabitType]
    @Query(sort: \LedgerEvent.date, order: .reverse) private var allLedgerEvents: [LedgerEvent]

    @State private var recentlyLogged: String?

    private var manualHabits: [HabitType] { allHabits.filter { !$0.isSystem } }

    private var todayHabitEvents: [LedgerEvent] {
        allLedgerEvents.filter {
            $0.sourceKind == .habit && Calendar.current.isDateInToday($0.date)
        }
    }

    var body: some View {
        List {
            Section {
                if manualHabits.isEmpty {
                    ContentUnavailableView(
                        "No Habits Yet",
                        systemImage: "checklist",
                        description: Text("Define one under Settings → Habits, then log it here whenever it happens.")
                    )
                } else {
                    ForEach(manualHabits) { habit in
                        Button {
                            log(habit)
                        } label: {
                            HStack {
                                Text(habit.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if recentlyLogged == habit.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Text("\(habit.secondsPerLog >= 0 ? "+" : "")\(habit.secondsPerLog / 60) min")
                                        .foregroundStyle(habit.secondsPerLog >= 0 ? .green : .red)
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Log a Habit")
            }

            if !todayHabitEvents.isEmpty || energyLedgerManager.todayLateNightPenaltySeconds < 0 {
                Section {
                    if energyLedgerManager.todayLateNightPenaltySeconds < 0 {
                        HStack {
                            Text("Late-Night Penalty")
                            Spacer()
                            Text("\(energyLedgerManager.todayLateNightPenaltySeconds / 60) min")
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(todayHabitEvents) { event in
                        HStack {
                            Text(event.note)
                            Spacer()
                            Text("\(event.seconds >= 0 ? "+" : "")\(event.seconds / 60) min")
                                .foregroundStyle(event.seconds >= 0 ? .green : .red)
                        }
                    }
                    .onDelete(perform: deleteTodayEvents)
                } header: {
                    Text("Today")
                } footer: {
                    Text("Swipe to undo an accidental log. The automatic Late-Night Penalty (if any) shows here too, but isn't a log entry to delete — adjust it under Settings → Habits.")
                }
            }
        }
        .navigationTitle("Habits")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            HabitType.ensureSystemLateNightHabit(modelContext: modelContext)
        }
    }

    private func log(_ habit: HabitType) {
        modelContext.insert(LedgerEvent(date: .now, seconds: habit.secondsPerLog, note: habit.name, source: .habit))
        recentlyLogged = habit.name
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if recentlyLogged == habit.name { recentlyLogged = nil }
        }
    }

    private func deleteTodayEvents(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(todayHabitEvents[index]) }
    }
}

#Preview {
    NavigationStack {
        HabitsView()
    }
    .environmentObject(EnergyLedgerManager())
    .modelContainer(for: [HabitType.self, LedgerEvent.self], inMemory: true)
}
