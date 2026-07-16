//
//  ContentView.swift
//  YTRun
//
//  Created by Ranjith CV on 15/7/26.
//

import SwiftUI
import Combine

// In SwiftUI, a "View" is not a UIView on screen — it's a lightweight
// value type (a struct) that describes what the UI *should* look like
// for the current state. SwiftUI re-runs `body` whenever state changes
// and diffs the result to update the actual screen efficiently.
struct ContentView: View {
    // `@StateObject` creates and *owns* these instances for as long as
    // ContentView is alive — SwiftUI keeps them around across redraws
    // instead of recreating them each time `body` runs. Since ContentView
    // is the root screen, it's the natural owner; `.environmentObject`
    // below then makes both available to every pushed screen without
    // threading them through each `NavigationLink` destination by hand.
    @StateObject private var settings = AppSettings()
    @StateObject private var usageTracker = UsageTracker()
    // Owning the web view store here — rather than inside YouTubeView —
    // is what lets it survive navigating away from and back to the
    // YouTube screen. See `YouTubeWebViewStore`.
    @StateObject private var webViewStore = YouTubeWebViewStore()
    // Same reasoning as `webViewStore`: owning the run tracker here lets
    // an in-progress run survive navigating back to Home, so returning to
    // "Start a Run" resumes it instead of starting a second one.
    @StateObject private var runTracker = RunTracker()

    private let gridColumns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible())]

    // `body` is the only requirement of the `View` protocol.
    // `some View` means "a concrete view type, but I won't tell you which one" —
    // this lets SwiftUI check types at compile time without us spelling out
    // the (often deeply nested) real type of the view tree.
    var body: some View {
        // NavigationStack manages a stack of pushed screens (like a
        // navigation controller) and gives us the title bar + back button.
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    statsCard

                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        MenuTile(title: "Watch YouTube", systemImage: "play.rectangle.fill", color: .red) {
                            YouTubeView()
                        }
                        MenuTile(title: "Start a Run", systemImage: "figure.run", color: .orange) {
                            RunView()
                        }
                        MenuTile(title: "View History", systemImage: "calendar", color: .purple) {
                            DailyHistoryView()
                        }
                        MenuTile(title: "Run History", systemImage: "map.fill", color: .green) {
                            RunHistoryView()
                        }
                    }

                    MenuTile(title: "Settings", systemImage: "gearshape.fill", color: .gray, fullWidth: true) {
                        SettingsView()
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
        .environmentObject(settings)
        .environmentObject(usageTracker)
        .environmentObject(webViewStore)
        .environmentObject(runTracker)
        .onAppear {
            // Lets the Lock Screen / Control Center play button respect
            // the app's own lock state — without this, tapping play there
            // bypasses the Locked screen entirely, since that remote
            // command otherwise just resumes the video unconditionally.
            webViewStore.isPlaybackAllowed = { [usageTracker, settings] in
                !(usageTracker.isDailyLimitReached(dailyLimitMinutes: settings.dailyLimitMinutes)
                    || usageTracker.isInCooldown)
            }
            // Lets the YouTube screen respect Settings' "Restrict Shorts"
            // toggle — see `YouTubeWebViewStore`.
            webViewStore.isShortsRestricted = { [settings] in settings.restrictShorts }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text("YouTube Running Gate")
                .font(.title2)
                .bold()
        }
        .padding(.top, 8)
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            RemainingMinutesLabel(
                title: "Remaining today",
                remainingSeconds: usageTracker.remainingDailySeconds(dailyLimitMinutes: settings.dailyLimitMinutes),
                limitSeconds: settings.dailyLimitMinutes * 60
            )
            .frame(maxWidth: .infinity)

            Divider().frame(height: 44)

            RemainingMinutesLabel(
                title: "Binge",
                remainingSeconds: usageTracker.bingeRemainingSeconds(bingeLimitMinutes: settings.bingeLimitMinutes),
                limitSeconds: settings.bingeLimitMinutes * 60
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        // An active cooldown only lifts once its timer passes, and a
        // partial binge session only forgives itself after enough
        // inactivity — refresh every second to catch both live instead of
        // looking frozen until the next video plays.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            usageTracker.refreshBingeState(bingeResetAfterMinutes: settings.bingeResetAfterMinutes)
        }
    }
}

// #Preview renders this view live in Xcode's canvas without running
// the full app on a simulator/device — handy while iterating on layout.
#Preview {
    ContentView()
}
