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
    @EnvironmentObject var aiGatewayClient: AIGatewayClient
    @EnvironmentObject var webViewStore: YouTubeWebViewStore

    @State private var showingResetConfirmation = false
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var showingClearDataConfirmation = false

    var body: some View {
        // Form gives us the standard iOS Settings-app look (grouped rows)
        // for free.
        Form {
            Section {
                Stepper(value: $settings.dailyLimitMinutes, in: 0...600, step: 5) {
                    limitRow(title: "Daily limit", minutes: settings.dailyLimitMinutes)
                }
            } header: {
                sectionHeader("Daily allowance", info: "Total YouTube minutes allowed per day. Resets at midnight.")
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
                sectionHeader("Binge protection", info: "Watching \(settings.bingeLimitMinutes) cumulative minutes (pauses don't reset it) triggers a \(settings.cooldownMinutes)-minute lockout, independent of the daily total. A run ends the cooldown early, but doesn't also add daily minutes — the two rewards don't stack. Going \(settings.bingeResetAfterMinutes) minutes without watching anything also resets the binge counter on its own, even if you never hit the limit.")
            }

            Section {
                Stepper(value: $settings.minutesPerRun, in: 5...120, step: 5) {
                    limitRow(title: "Minutes per run", minutes: settings.minutesPerRun)
                }
            } header: {
                sectionHeader("Run reward", info: "Extra viewing minutes granted each time a qualifying run is completed (real or simulated).")
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
                sectionHeader("Qualifying run", info: "A run counts if it meets EITHER the distance or the duration threshold — not both.")
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
                sectionHeader("Calorie estimate", info: "Used to roughly estimate calories burnt per run (distance × weight). Not medically precise — no heart rate data is used.")
            }

            Section {
                Stepper(value: $settings.listenRatePercent, in: 0...100, step: 5) {
                    percentRow(title: "Listen rate", percent: settings.listenRatePercent)
                }
                Stepper(value: $settings.carRatePercent, in: 0...100, step: 5) {
                    percentRow(title: "Car rate", percent: settings.carRatePercent)
                }
            } header: {
                sectionHeader("Background listening rate", info: "How much of your daily/binge allowance background listening actually costs, relative to watching with the screen on (always 100%). E.g. a 50% listen rate means 10 minutes of background listening only uses 5 minutes of allowance. The daily/binge limits themselves don't change — only how fast background listening eats into them.")
            }

            Section {
                TextField("e.g. BYD", text: $settings.carBluetoothDeviceName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                sectionHeader("Car Bluetooth device", info: "Daily History splits background listening into \"Listen\" and \"Car.\" CarPlay is detected automatically; for a plain Bluetooth car stereo (most cars), enter its device name here (check Settings → Bluetooth on your phone) — matched as a substring, case-insensitive.")
            }

            Section {
                Toggle("Restrict Shorts", isOn: $settings.restrictShorts)
            } header: {
                sectionHeader("Shorts", info: "When on, Shorts thumbnails and shelves are hidden everywhere in the YouTube screen (home feed, search, the Shorts tab) so they can't even be previewed, and opening a Shorts link directly redirects back to the home feed. Best-effort — YouTube's markup can change, and the Shorts feed can scroll between clips without a page reload, so there may be a brief flash before a direct link redirects.")
            }

            Section {
                Toggle("Show Simulate Run Button", isOn: $settings.enableSimulateRun)
            } header: {
                sectionHeader("Simulate Run", info: "When off (the default), the Locked screen only offers a real \"Start a Run\" — no one-tap way to grant the reward without actually running. Turn this on temporarily if you need to test the reward flow itself — using it once turns this back off automatically, so it doesn't just sit there armed.")
            }

            Section {
                Toggle("Show Walk Option", isOn: $settings.enableWalkOption)
                if settings.enableWalkOption {
                    Toggle("Allow Video While Walking", isOn: $settings.walkAllowsVideo)
                }
            } header: {
                sectionHeader("Walk", info: "Adds a \"Walk\" option to the Locked screen — a live gate, not a reward: unlocks playback immediately, live against your actual step count (a real step resumes it right away; about 8 seconds with none pauses it, with a \"Not moving\" notice, until you start again). Nothing is banked or saved, and it doesn't touch your daily/binge allowance at all — it's a separate channel that only exists for as long as you're actually walking. Off by default restricts it to audio (Listen Mode); turn \"Allow Video\" on to permit full video too.")
            }

            Section {
                Toggle("Show Push-Ups Option", isOn: $settings.enablePushUpOption)
                Toggle("Show Sit-Ups Option", isOn: $settings.enableSitUpOption)
                Toggle("Show Lunges Option", isOn: $settings.enableLungeOption)
                if settings.enablePushUpOption || settings.enableSitUpOption || settings.enableLungeOption {
                    Stepper(value: $settings.repsPerExerciseSet, in: 1...50) {
                        HStack {
                            Text("Reps per set")
                            Spacer()
                            Text("\(settings.repsPerExerciseSet)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $settings.secondsPerExerciseSet, in: 15...600, step: 15) {
                        HStack {
                            Text("Reward per set")
                            Spacer()
                            Text("\(settings.secondsPerExerciseSet)s")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                sectionHeader("Exercises", info: "Each adds an option to the Locked screen's Exercise picker — counted on-device via the camera (Vision body-pose tracking, nothing recorded or sent anywhere). Unlike Walk, these are banked rewards like a run: every \(settings.repsPerExerciseSet) counted reps of any of them earns \(settings.secondsPerExerciseSet) seconds you claim explicitly, added to today's allowance (or clearing an active cooldown, same either/or rule as a run). All three share this one reps/reward setting.")
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
                sectionHeader("Stairs", info: "Adds a \"Climb Stairs\" option to the Locked screen's Exercise picker — counted via the phone's barometer (the same signal Apple's own Fitness app uses for \"Flights Climbed\"), no camera involved at all. Every \(settings.floorsPerStairSet) floors earns \(settings.secondsPerStairSet) seconds, same claim-explicitly rule as the other exercises.")
            }

            Section {
                TextField("https://your-router.workers.dev", text: $settings.aiGatewayURI)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Token", text: $settings.aiGatewayToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTestingConnection {
                        ProgressView()
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTestingConnection)
            } header: {
                sectionHeader("YTRun Gateway", info: "Powers \"Summarize\" and Downloads on the YouTube screen. URL and Token are both required — see ai-router's own README for how to set these up.")
            }

            Section {
                TextField("Shortcut name", text: $settings.chatGPTShortcutName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                sectionHeader("ChatGPT Shortcut", info: "Powers \"Summarize via ChatGPT\" on the YouTube screen — a peer alternative to YTRun Gateway that uses your own ChatGPT app via a Shortcut, with no server involved. Must exactly match the Shortcut's name in the Shortcuts app. See chatgpt-shortcut-setup.md for how to build it.")
            }

            Section {
                Button("Clear YouTube Data", role: .destructive) {
                    showingClearDataConfirmation = true
                }
            } header: {
                sectionHeader("YouTube Data", info: "Signs you out of YouTube in the app (if signed in) and resets anything YouTube remembers client-side — including a stuck autoplay-unmuted preference, if that happens again.")
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
                            weight: 1.0,
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
                sectionHeader("Developer debug options", info: "Quickly push usage toward the limits without waiting, to test the Locked screen.")
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
        .confirmationDialog(
            "Clear YouTube data?",
            isPresented: $showingClearDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Data", role: .destructive) {
                webViewStore.clearWebsiteData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out of YouTube in the app and resets anything it remembers client-side.")
        }
        .alert("YTRun Gateway", isPresented: Binding(
            get: { connectionTestMessage != nil },
            set: { if !$0 { connectionTestMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionTestMessage ?? "")
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        let result = await aiGatewayClient.testConnection(settings: settings)
        isTestingConnection = false
        switch result {
        case .success:
            connectionTestMessage = "Connected successfully."
        case .failure(let error):
            connectionTestMessage = error.message
        }
    }

    // Every section header is a title plus a trailing info bubble
    // holding what used to be permanently-visible footer text — same
    // content, shown on demand instead of always taking up space.
    private func sectionHeader(_ title: String, info: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            InfoButton(text: info)
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

    private func percentRow(title: String, percent: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(percent)%")
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
    .environmentObject(AIGatewayClient())
    .environmentObject(YouTubeWebViewStore())
}
