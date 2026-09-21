//
//  ExerciseSettingsView.swift
//  YTRun
//

import SwiftUI

// Every exercise/currency-source config, consolidated onto one screen —
// Walk, Run, the three camera-tracked exercises, Stairs, and Steps —
// instead of scattered across the main Settings screen. Matches
// `AIProvidersView`'s one-section-per-thing shape.
struct ExerciseSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show Walk Option", isOn: $settings.enableWalkOption)
                if settings.enableWalkOption {
                    Toggle("Allow Video While Walking", isOn: $settings.walkAllowsVideo)
                }
            } header: {
                sectionHeader("Walk", info: "A live gate, not a reward: unlocks playback immediately, live against your actual step count (a real step resumes it right away; about 8 seconds with none pauses it, with a \"Not moving\" notice, until you start again). Nothing is banked or saved, and it doesn't touch your daily/binge allowance at all. Off by default restricts it to audio (Listen Mode); turn \"Allow Video\" on to permit full video too.")
            }

            Section {
                Stepper(value: $settings.secondsCreditPerRunMinute, in: 15...180, step: 15) {
                    HStack {
                        Text("Reward rate")
                        Spacer()
                        Text("\(settings.secondsCreditPerRunMinute)s per min run")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.weightKg, in: 30...200, step: 1) {
                    HStack {
                        Text("Your weight")
                        Spacer()
                        Text("\(Int(settings.weightKg)) kg")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                sectionHeader("Run", info: "Every minute run earns this many seconds of viewing currency — no minimum distance or duration, just straight proportional credit. Weight is used only for a rough calorie estimate on saved runs (no HealthKit, no heart rate — just distance × weight, so treat it as approximate).")
            }

            Section {
                Toggle("Show Push-Ups Option", isOn: $settings.enablePushUpOption)
                if settings.enablePushUpOption {
                    repsAndRewardRows(reps: $settings.repsPerPushUpSet, seconds: $settings.secondsPerPushUpSet)
                }
            } header: {
                sectionHeader("Push-Ups", info: "Counted on-device via the camera (Vision body-pose tracking, nothing recorded or sent anywhere). Every set of reps earns the seconds shown, claimed explicitly.")
            }

            Section {
                Toggle("Show Sit-Ups Option", isOn: $settings.enableSitUpOption)
                if settings.enableSitUpOption {
                    repsAndRewardRows(reps: $settings.repsPerSitUpSet, seconds: $settings.secondsPerSitUpSet)
                }
            } header: {
                sectionHeader("Sit-Ups", info: "Same camera-tracked counting as Push-Ups, its own independent reps/reward rate.")
            }

            Section {
                Toggle("Show Lunges Option", isOn: $settings.enableLungeOption)
                if settings.enableLungeOption {
                    repsAndRewardRows(reps: $settings.repsPerLungeSet, seconds: $settings.secondsPerLungeSet)
                }
            } header: {
                sectionHeader("Lunges", info: "Same camera-tracked counting as Push-Ups, its own independent reps/reward rate.")
            }

            Section {
                Toggle("Show Climb Stairs Option", isOn: $settings.enableStairsOption)
                if settings.enableStairsOption {
                    Stepper(value: $settings.floorsPerStairSet, in: 1...20) {
                        HStack {
                            Text("Floors per set")
                            Spacer()
                            Text("\(settings.floorsPerStairSet)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $settings.secondsPerStairSet, in: 15...600, step: 15) {
                        HStack {
                            Text("Reward per set")
                            Spacer()
                            Text("\(settings.secondsPerStairSet)s")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                sectionHeader("Stairs", info: "Counted via the phone's barometer (the same signal Apple's own Fitness app uses for \"Flights Climbed\"), no camera involved at all.")
            }

            Section {
                Stepper(value: $settings.stepsPerCreditSet, in: 1000...30000, step: 500) {
                    HStack {
                        Text("Steps")
                        Spacer()
                        Text("\(settings.stepsPerCreditSet)")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.secondsPerStepCredit, in: 300...7200, step: 300) {
                    HStack {
                        Text("Worth")
                        Spacer()
                        Text("\(settings.secondsPerStepCredit / 60) min")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                sectionHeader("Steps", info: "Read passively from your phone's own step history (minus whatever a live Walk session already used, to avoid double-counting) and converted to Energy Ledger credit at this rate — continuous, not floored to whole sets the way reps are.")
            }
        }
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func repsAndRewardRows(reps: Binding<Int>, seconds: Binding<Int>) -> some View {
        Stepper(value: reps, in: 1...20) {
            HStack {
                Text("Reps per set")
                Spacer()
                Text("\(reps.wrappedValue)")
                    .foregroundStyle(.secondary)
            }
        }
        Stepper(value: seconds, in: 15...600, step: 15) {
            HStack {
                Text("Reward per set")
                Spacer()
                Text("\(seconds.wrappedValue)s")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Same info-bubble pattern `SettingsView` uses throughout.
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
        ExerciseSettingsView()
    }
    .environmentObject(AppSettings())
}
