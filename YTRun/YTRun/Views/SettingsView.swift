//
//  SettingsView.swift
//  YTRun
//

import SwiftUI

struct SettingsView: View {
    // `@EnvironmentObject` reads a shared instance placed into the
    // environment by ContentView, rather than being passed in explicitly —
    // every screen that needs settings/usage reads the same instances.
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker

    @State private var showingResetConfirmation = false

    var body: some View {
        // Form gives us the standard iOS Settings-app look (grouped rows)
        // for free.
        Form {
            Section {
                Stepper(value: $settings.dailyLimitMinutes, in: 0...600, step: 5) {
                    limitRow(title: "Daily limit", minutes: settings.dailyLimitMinutes)
                }
            } header: {
                Text("Daily allowance")
            } footer: {
                Text("Total YouTube minutes allowed per day. Resets at midnight.")
            }

            Section {
                Stepper(value: $settings.bingeLimitMinutes, in: 5...180, step: 5) {
                    limitRow(title: "Binge limit", minutes: settings.bingeLimitMinutes)
                }
                Stepper(value: $settings.cooldownMinutes, in: 5...240, step: 5) {
                    limitRow(title: "Cooldown", minutes: settings.cooldownMinutes)
                }
                Stepper(value: $settings.bingeResetAfterMinutes, in: 5...120, step: 5) {
                    limitRow(title: "Reset after break", minutes: settings.bingeResetAfterMinutes)
                }
            } header: {
                Text("Binge protection")
            } footer: {
                Text("Watching \(settings.bingeLimitMinutes) cumulative minutes (pauses don't reset it) triggers a \(settings.cooldownMinutes)-minute lockout, independent of the daily total. A run ends the cooldown early, but doesn't also add daily minutes — the two rewards don't stack. Going \(settings.bingeResetAfterMinutes) minutes without watching anything also resets the binge counter on its own, even if you never hit the limit.")
            }

            Section {
                Stepper(value: $settings.minutesPerRun, in: 5...120, step: 5) {
                    limitRow(title: "Minutes per run", minutes: settings.minutesPerRun)
                }
            } header: {
                Text("Run reward")
            } footer: {
                Text("Extra viewing minutes granted each time a qualifying run is completed (real or simulated).")
            }

            Section {
                Stepper(value: $settings.qualifyingDistanceKm, in: 0.5...42, step: 0.5) {
                    HStack {
                        Text("Minimum distance")
                        Spacer()
                        Text(String(format: "%.1f km", settings.qualifyingDistanceKm))
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.qualifyingDurationMinutes, in: 5...180, step: 5) {
                    limitRow(title: "Minimum duration", minutes: settings.qualifyingDurationMinutes)
                }
            } header: {
                Text("Qualifying run")
            } footer: {
                Text("A run counts if it meets EITHER the distance or the duration threshold — not both.")
            }

            Section {
                Stepper(value: $settings.weightKg, in: 30...150, step: 1) {
                    HStack {
                        Text("Weight")
                        Spacer()
                        Text(String(format: "%.0f kg", settings.weightKg))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Calorie estimate")
            } footer: {
                Text("Used to roughly estimate calories burnt per run (distance × weight). Not medically precise — no heart rate data is used.")
            }

            Section {
                TextField("e.g. BYD", text: $settings.carBluetoothDeviceName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                Text("Car Bluetooth device")
            } footer: {
                Text("Daily History splits background listening into \"Listen\" and \"Car.\" CarPlay is detected automatically; for a plain Bluetooth car stereo (most cars), enter its device name here (check Settings → Bluetooth on your phone) — matched as a substring, case-insensitive.")
            }

            Section {
                Toggle("Restrict Shorts", isOn: $settings.restrictShorts)
            } footer: {
                Text("When on, the YouTube screen redirects away from Shorts back to the home feed. Best-effort — YouTube's Shorts feed can scroll between clips without a page reload, so there may be a brief flash before it redirects.")
            }

            Section {
                Button("Reset today's usage", role: .destructive) {
                    showingResetConfirmation = true
                }
            }

            Section {
                Button("Add 5 min to today's usage") {
                    for _ in 0..<300 {
                        usageTracker.recordTick(
                            bingeLimitMinutes: settings.bingeLimitMinutes,
                            cooldownMinutes: settings.cooldownMinutes,
                            bingeResetAfterMinutes: settings.bingeResetAfterMinutes
                        )
                    }
                }
                Text("Used today: \(usageTracker.todayUsedSeconds / 60) min · Binge: \(usageTracker.bingeSecondsUsed / 60) min\(usageTracker.isInCooldown ? " · In cooldown" : "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Developer debug options")
            } footer: {
                Text("Quickly push usage toward the limits without waiting, to test the Locked screen.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Reset today's usage?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                usageTracker.resetToday()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // Small reusable row so the three sections stay visually consistent.
    private func limitRow(title: String, minutes: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(minutes) min")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environmentObject(AppSettings())
    .environmentObject(UsageTracker())
}
