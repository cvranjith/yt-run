//
//  ExercisePickerView.swift
//  YTRun
//

import SwiftUI

// One list for all exercise-based reward options, rather than a
// separate Locked-screen button (and Home tile) per exercise that
// would just keep growing as more get added. Reachable two ways with
// different filtering:
// - From Home (`onlyShowEnabled: false`): always shows everything,
//   same as how Push-Ups' own Home tile worked before this existed —
//   Home access was never gated by the Settings toggles, only the
//   Locked screen's bypass-friction was.
// - From the Locked screen (`onlyShowEnabled: true`): only shows
//   whichever exercises are actually turned on in Settings, matching
//   Walk/Simulate Run's own friction-by-design reasoning.
struct ExercisePickerView: View {
    @EnvironmentObject var settings: AppSettings
    let onlyShowEnabled: Bool

    init(onlyShowEnabled: Bool = false) {
        self.onlyShowEnabled = onlyShowEnabled
    }

    var body: some View {
        List {
            ForEach(ExerciseKind.allCases) { kind in
                if !onlyShowEnabled || isEnabled(kind) {
                    NavigationLink {
                        ExerciseTrainingView(kind: kind)
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                }
            }
            if !onlyShowEnabled || settings.enableStairsOption {
                NavigationLink {
                    StairClimbView()
                } label: {
                    Label("Climb Stairs", systemImage: "figure.stairs")
                }
            }
        }
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isEnabled(_ kind: ExerciseKind) -> Bool {
        switch kind {
        case .pushUps: return settings.enablePushUpOption
        case .sitUps: return settings.enableSitUpOption
        case .lunges: return settings.enableLungeOption
        }
    }
}

#Preview {
    NavigationStack {
        ExercisePickerView()
    }
    .environmentObject(AppSettings())
}
