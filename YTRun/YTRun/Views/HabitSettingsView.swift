//
//  HabitSettingsView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Where habits are *defined* — the one predefined "Automatic" habit
// (Late-Night Penalty) plus every user-defined one — kept separate
// from the Home dashboard's `HabitsView`, which is purely for logging
// today's occurrences. Matches `ExerciseSettingsView`'s shape: this is
// the "Exercises" screen's equivalent for the Habits feature.
struct HabitSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<HabitType> { $0.isSystem })
    private var systemHabits: [HabitType]
    @Query(filter: #Predicate<HabitType> { !$0.isSystem }, sort: \HabitType.createdAt)
    private var manualHabits: [HabitType]

    @State private var isShowingNewHabit = false
    @State private var newHabitName = ""
    @State private var newHabitMinutes = ""
    @State private var newHabitIsReward = true

    private var lateNightHabit: HabitType? { systemHabits.first }

    var body: some View {
        Form {
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
                    sectionHeader("Automatic", info: "Computed by the app from your watch history — not something you log by hand. An extra deduction from the Energy Ledger for watching during these hours, on top of that time already counting as normal spend.")
                }
            }

            Section {
                if manualHabits.isEmpty {
                    Text("No habits defined yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manualHabits) { habit in
                        HStack {
                            Text(habit.name)
                            Spacer()
                            Text("\(habit.secondsPerLog >= 0 ? "+" : "")\(habit.secondsPerLog / 60) min")
                                .foregroundStyle(habit.secondsPerLog >= 0 ? .green : .red)
                        }
                    }
                    .onDelete(perform: deleteHabits)
                }
                Button("Add Habit…") {
                    isShowingNewHabit = true
                }
            } header: {
                sectionHeader("User-Defined Habits", info: "Anything you want to reward or discourage yourself for, in your own minutes — logged from the Habits tab on the dashboard, defined here. Positive is a reward, negative a penalty.")
            }
        }
        .navigationTitle("Habits")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            HabitType.ensureSystemLateNightHabit(modelContext: modelContext)
        }
        .sheet(isPresented: $isShowingNewHabit) {
            newHabitSheet
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

    private func deleteHabits(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(manualHabits[index]) }
    }

    private func hourLabel(_ hour: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour) \(period)"
    }

    private func sectionHeader(_ title: String, info: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            InfoButton(text: info)
        }
    }
}

#Preview {
    NavigationStack {
        HabitSettingsView()
    }
    .modelContainer(for: [HabitType.self], inMemory: true)
}
