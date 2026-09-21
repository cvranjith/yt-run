//
//  HabitsView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// User-defined habits, each with its own signed minutes-per-log rate
// (see `HabitType`) — a reward habit ("Read 10 pages", +10 min) or a
// penalty one ("Ate a sweet", −10 min). Tapping "Log" inserts one
// `LedgerEvent` immediately; there's no set/threshold to fill first,
// unlike the camera-tracked exercises.
struct HabitsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HabitType.createdAt) private var habits: [HabitType]

    @State private var isShowingNewHabit = false
    @State private var newHabitName = ""
    @State private var newHabitMinutes = ""
    @State private var newHabitIsReward = true
    @State private var recentlyLogged: String?

    var body: some View {
        List {
            if habits.isEmpty {
                ContentUnavailableView(
                    "No Habits Yet",
                    systemImage: "checklist",
                    description: Text("Add a habit below — anything you want to reward or discourage yourself for, in your own minutes.")
                )
            } else {
                ForEach(habits) { habit in
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
        for index in offsets { modelContext.delete(habits[index]) }
    }
}

#Preview {
    NavigationStack {
        HabitsView()
    }
    .modelContainer(for: [HabitType.self, LedgerEvent.self], inMemory: true)
}
