//
//  SettingsView.swift
//  YTRun
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    // `@EnvironmentObject` reads a shared instance placed into the
    // environment by ContentView, rather than being passed in explicitly —
    // every screen that needs settings/usage reads the same instances.
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker
    @EnvironmentObject var aiGatewayClient: AIGatewayClient
    @EnvironmentObject var webViewStore: YouTubeWebViewStore
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager
    @Environment(\.modelContext) private var modelContext

    @State private var showingResetConfirmation = false
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var showingClearDataConfirmation = false
    @State private var showingResetBalanceConfirmation = false

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
            } header: {
                sectionHeader("Binge protection", info: "Watching \(settings.bingeLimitMinutes) cumulative minutes (pauses don't reset it) triggers a \(settings.cooldownMinutes)-minute lockout, independent of the daily total. A reward claimed while locked out ends the cooldown early, but doesn't also add daily minutes — the two don't stack.")
            }

            Section {
                NavigationLink("Exercises") {
                    ExerciseSettingsView()
                }
            } header: {
                sectionHeader("Exercises", info: "Walk, Run, Push-Ups, Sit-Ups, Lunges, Stairs, and Steps — each with its own on/off switch and reward rate, all on one screen. A reward claimed while locked out extends today's allowance right now; claimed any other time, it only banks Energy Ledger currency for later.")
            }

            Section {
                Toggle("Restrict Shorts", isOn: $settings.restrictShorts)
            } header: {
                sectionHeader("Shorts", info: "When on, Shorts thumbnails and shelves are hidden everywhere in the YouTube screen (home feed, search, the Shorts tab) so they can't even be previewed, and opening a Shorts link directly redirects back to the home feed. Best-effort — YouTube's markup can change, and the Shorts feed can scroll between clips without a page reload, so there may be a brief flash before a direct link redirects.")
            }

            Section {
                Stepper(value: $settings.ledgerWindowDays, in: 1...30) {
                    HStack {
                        Text("Rolling window")
                        Spacer()
                        Text("\(settings.ledgerWindowDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.secondsPerCreditUse, in: 60...3600, step: 60) {
                    HStack {
                        Text("\"Use Credit\" grants")
                        Spacer()
                        Text("\(settings.secondsPerCreditUse / 60) min")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Reset Balance", role: .destructive) {
                    showingResetBalanceConfirmation = true
                }
            } header: {
                sectionHeader("Energy Ledger", info: "A separate, honesty-based balance — not another hard limit. Tracks steps/exercise/run credit against actual watch time, over the rolling window below. Shown on the Home and Locked screens along with a \"Use Credit\" button that grants extra time without exercising first, pushing the balance into deficit with no ceiling — paying it back later is entirely up to you.")
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
                NavigationLink("AI Providers") {
                    AIProvidersView()
                }
            } header: {
                sectionHeader("YTRun Gateway", info: "Always powers Downloads on the YouTube screen. Powers Summarize too, unless a different default is chosen on the \"AI Providers\" screen below — where Grok, OpenAI, Gemini, Claude, and the ChatGPT Shortcut can each be configured with their own key.")
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
                            cooldownMinutes: settings.cooldownMinutes
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
            "Reset Energy Ledger balance?",
            isPresented: $showingResetBalanceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Balance", role: .destructive) {
                energyLedgerManager.resetBalance(settings: settings, modelContext: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts the balance fresh from right now — nothing earlier counts toward it anymore. Your actual watch history and Daily History reports are unaffected.")
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

    // Small reusable row so the sections stay visually consistent.
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
    .environmentObject(AIGatewayClient())
    .environmentObject(YouTubeWebViewStore())
    .environmentObject(EnergyLedgerManager())
    .modelContainer(for: [LedgerEvent.self], inMemory: true)
}
