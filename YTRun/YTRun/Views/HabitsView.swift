//
//  HabitsView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Manual, user-defined habits (each with its own signed minutes-per-log
// rate — a reward habit, "Read 10 pages" +10 min, or a penalty one,
// "Ate a sweet" −10 min; tapping "Log" inserts one `LedgerEvent`
// immediately, no set/threshold to fill first), plus the one predefined
// "system" habit — Late-Night Penalty — shown in its own section above
// with its own toggle/hours/rate instead of a Log button, since it's
// applied automatically from watch history rather than tapped (see
// `HabitType`/`EnergyLedgerManager`).
struct HabitsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<HabitType> { !$0.isSystem }, sort: \HabitType.createdAt)
    private var manualHabits: [HabitType]
    @Query(filter: #Predicate<HabitType> { $0.isSystem })
    private var systemHabits: [HabitType]

    @State private var isShowingNewHabit = false
    @State private var newHabitName = ""
    @State private var newHabitMinutes = ""
    @State private var newHabitIsReward = true
    @State private var recentlyLogged: String?

    private var lateNightHabit: HabitType? { systemHabits.first }

    var body: some View {
        List {
            if let lateNightHabit {
                Section {
                    Toggle("Enabled", isOn: Binding(
                        get: { lateNightHabit.isEnabled },
                        set: { lateNightHabit.isEnabled = $0 }
                    ))
                    Stepper(value: Binding(
                        get: { lateNightHabit.startHour ?? 22 },
                        set: { lateNightHabit.startHour = $0 }
                    ), in: 0...23) {
                        HStack {
                            Text("Starts at")
                            Spacer()
                            Text(hourLabel(lateNightHabit.startHour ?? 22)).foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: Binding(
                        get: { lateNightHabit.endHour ?? 5 },
                        set: { lateNightHabit.endHour = $0 }
                    ), in: 0...23) {
                        HStack {
                            Text("Ends at")
                            Spacer()
                            Text(hourLabel(lateNightHabit.endHour ?? 5)).foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: Binding(
                        get: { lateNightHabit.secondsPerLog },
                        set: { lateNightHabit.secondsPerLog = $0 }
                    ), in: 0...180, step: 15) {
                        HStack {
                            Text("Penalty rate")
                            Spacer()
                            Text("\(lateNightHabit.secondsPerLog)s per min watched").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Automatic")
                } footer: {
                    Text("An extra deduction from the Energy Ledger for watching during these hours — on top of that time already counting as normal spend, not instead of it.")
                }
            }

            Section {
                if manualHabits.isEmpty {
                    ContentUnavailableView(
                        "No Habits Yet",
                        systemImage: "checklist",
                        description: Text("Add a habit below — anything you want to reward or discourage yourself for, in your own minutes.")
                    )
                } else {
                    ForEach(manualHabits) { habit in
                        Button {
                            log(habit)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(habit.name)
                                        .foregroundStyle(.primary)
                                    Text("\(habit.secondsPerLog >= 0 ? "+" : "")\(habit.secondsPerLog / 60) min per log")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if recentlyLogged == habit.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(habit.secondsPerLog >= 0 ? .green : .red)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteHabits)
                }
            } header: {
                Text("Habits")
            }
        }
        .navigationTitle("Habits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewHabit = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingNewHabit) {
            newHabitSheet
        }
        .onAppear {
            HabitType.ensureSystemLateNightHabit(modelContext: modelContext)
        }
    }

    private var newHabitSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. \"Ate a sweet\")", text: $newHabitName)
                    TextField("Minutes", text: $newHabitMinutes)
                        .keyboardType(.numberPad)
                    Picker("Type", selection: $newHabitIsReward) {
                        Text("Reward (+)").tag(true)
                        Text("Penalty (−)").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingNewHabit = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveNewHabit() }
                        .disabled(newHabitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(newHabitMinutes) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveNewHabit() {
        guard let minutes = Int(newHabitMinutes) else { return }
        let name = newHabitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let seconds = (newHabitIsReward ? minutes : -minutes) * 60
        modelContext.insert(HabitType(name: name, secondsPerLog: seconds))
        newHabitName = ""
        newHabitMinutes = ""
        newHabitIsReward = true
        isShowingNewHabit = false
    }

    private func log(_ habit: HabitType) {
        modelContext.insert(LedgerEvent(date: .now, seconds: habit.secondsPerLog, note: habit.name))
        recentlyLogged = habit.name
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if recentlyLogged == habit.name { recentlyLogged = nil }
        }
    }

    private func deleteHabits(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(manualHabits[index]) }
    }

    private func hourLabel(_ hour: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour) \(period)"
    }
}

#Preview {
    NavigationStack {
        HabitsView()
    }
    .modelContainer(for: [HabitType.self, LedgerEvent.self], inMemory: true)
}
