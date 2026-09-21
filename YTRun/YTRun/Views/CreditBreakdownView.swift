//
//  CreditBreakdownView.swift
//  YTRun
//

import SwiftUI

// Today's Energy Ledger earn side, broken into line items — the steps
// credit (computed the same way `EnergyLedgerManager` does, from its
// already-fetched `todayStepCount`) plus each individual `LedgerEvent`
// recorded today, grouped by its `source` (Push-Ups, Sit-Ups, Lunges,
// Stairs, Run, Habits, Walk) rather than lumped into one bucket — so
// logging a habit several times, say, doesn't read as if it were
// exercise activity.
struct CreditBreakdownView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager

    private var stepCreditSeconds: Int {
        guard settings.stepsPerCreditSet > 0 else { return 0 }
        return Int((Double(energyLedgerManager.todayStepCount) / Double(settings.stepsPerCreditSet)) * Double(settings.secondsPerStepCredit))
    }

    // Fixed order rather than alphabetical/insertion order, so the list
    // reads the same way every day regardless of what happened to be
    // logged first.
    private static let sourceOrder: [LedgerEventSource] = [.pushUps, .sitUps, .lunges, .stairs, .run, .habit, .walk, .other]

    private var eventsBySource: [(source: LedgerEventSource, events: [(note: String, seconds: Int, source: LedgerEventSource)])] {
        let grouped = Dictionary(grouping: energyLedgerManager.todayCreditEvents, by: \.source)
        return Self.sourceOrder.compactMap { source in
            guard let events = grouped[source], !events.isEmpty else { return nil }
            return (source: source, events: events)
        }
    }

    var body: some View {
        List {
            Section {
                row(note: "\(energyLedgerManager.todayStepCount) steps", seconds: stepCreditSeconds)
            } header: {
                Text("Steps")
            }

            ForEach(eventsBySource, id: \.source) { group in
                Section {
                    ForEach(Array(group.events.enumerated()), id: \.offset) { _, event in
                        row(note: event.note, seconds: event.seconds)
                    }
                } header: {
                    Text(group.source.displayName)
                }
            }

            Section {
                row(note: "Total earned today", seconds: energyLedgerManager.todayEarnedSeconds, isTotal: true)
            }
        }
        .navigationTitle("Credits Earned")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(note: String, seconds: Int, isTotal: Bool = false) -> some View {
        HStack {
            Text(note)
                .fontWeight(isTotal ? .semibold : .regular)
            Spacer()
            Text("\(seconds >= 0 ? "+" : "")\(seconds / 60) min")
                .foregroundStyle(seconds < 0 ? .red : .secondary)
                .fontWeight(isTotal ? .semibold : .regular)
        }
    }
}

#Preview {
    NavigationStack {
        CreditBreakdownView()
    }
    .environmentObject(AppSettings())
    .environmentObject(EnergyLedgerManager())
}
