//
//  CreditBreakdownView.swift
//  YTRun
//

import SwiftUI

// Today's Energy Ledger earn side, broken into line items — the steps
// credit (computed the same way `EnergyLedgerManager` does, from its
// already-fetched `todayStepCount`) plus each individual `LedgerEvent`
// recorded today (push-ups/sit-ups/lunges/stairs/runs, and any Walk-
// mode deduction) — rather than just the one summed number the Home
// card shows.
struct CreditBreakdownView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager

    private var stepCreditSeconds: Int {
        guard settings.stepsPerCreditSet > 0 else { return 0 }
        return Int((Double(energyLedgerManager.todayStepCount) / Double(settings.stepsPerCreditSet)) * Double(settings.secondsPerStepCredit))
    }

    var body: some View {
        List {
            Section {
                row(note: "\(energyLedgerManager.todayStepCount) steps", seconds: stepCreditSeconds)
            } header: {
                Text("Steps")
            }

            if !energyLedgerManager.todayCreditEvents.isEmpty {
                Section {
                    ForEach(Array(energyLedgerManager.todayCreditEvents.enumerated()), id: \.offset) { _, event in
                        row(note: event.note, seconds: event.seconds)
                    }
                } header: {
                    Text("Exercise & Runs")
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
