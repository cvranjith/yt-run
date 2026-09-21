//
//  ContentView.swift
//  YTRun
//
//  Created by Ranjith CV on 15/7/26.
//

import SwiftUI
import Combine
import SwiftData

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
    // Owned here (rather than by DailyHistoryView, which just shows a
    // manual button for it) so it can also be triggered implicitly from
    // app-foreground events like this screen and the YouTube screen
    // appearing, sharing the same in-flight/last-synced state either way.
    @StateObject private var cloudSync = CloudSyncService()
    // Owned here (like `webViewStore`) so `isDownloading` — and thus an
    // in-flight download itself — survives navigating away from and back
    // to the YouTube screen, rather than resetting with a fresh instance
    // each time that screen appears.
    @StateObject private var downloadManager = DownloadManager()
    // Caches its OAuth bearer token in memory for as long as the app
    // runs, so summarizing several videos in a row only signs in once —
    // owned here (not inside SummaryView) for the same reason as
    // `downloadManager`.
    @StateObject private var aiGatewayClient = AIGatewayClient()
    // Peer alternate summarizer via the ChatGPT app (see
    // ChatGPTShortcutBridge) — owned here so it can receive the
    // app-wide `.onOpenURL` callback below regardless of which screen
    // is on top when the Shortcuts app hands control back.
    @StateObject private var chatGPTBridge = ChatGPTShortcutBridge()
    // Owned here (like `downloadManager`/`webViewStore`) so a Walk
    // session survives navigating away from and back to the YouTube
    // screen, rather than resetting every time that screen appears.
    @StateObject private var walkModeManager = WalkModeManager()
    // Owned here for the same reason as `usageTracker` — a single shared
    // instance whose `balanceSeconds` LockedView and Settings both read.
    @StateObject private var energyLedgerManager = EnergyLedgerManager()

    @Environment(\.modelContext) private var modelContext

    // Three columns rather than two, paired with `MenuTile`'s `compact`
    // style below — enough tiles fit in view at once for this to read as
    // one dashboard instead of a few oversized cards needing a long
    // scroll. Reused for the dashboard box's stat tiles too.
    private let gridColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible())]

    // Which day the dashboard box is showing — defaults to today, moved
    // by the prev/next arrows in `dateNavigationHeader`. Only relevant
    // while the Energy Ledger is on; the hard daily/binge tiles always
    // reflect right now regardless of this.
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())

    private var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    // `body` is the only requirement of the `View` protocol.
    // `some View` means "a concrete view type, but I won't tell you which one" —
    // this lets SwiftUI check types at compile time without us spelling out
    // the (often deeply nested) real type of the view tree.
    var body: some View {
        // NavigationStack manages a stack of pushed screens (like a
        // navigation controller) and gives us the title bar + back button.
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    dashboardBox

                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        MenuTile(title: "Watch YouTube", systemImage: "play.rectangle.fill", color: .red, compact: true) {
                            YouTubeView()
                        }
                        MenuTile(title: "Start a Run", systemImage: "figure.run", color: .orange, compact: true) {
                            RunView()
                        }
                        MenuTile(title: "View History", systemImage: "calendar", color: .purple, compact: true) {
                            DailyHistoryView()
                        }
                        MenuTile(title: "Run History", systemImage: "map.fill", color: .green, compact: true) {
                            RunHistoryView()
                        }
                        MenuTile(title: "Downloads", systemImage: "arrow.down.circle.fill", color: .blue, compact: true) {
                            DownloadsView()
                        }
                        MenuTile(title: "Update App", systemImage: "arrow.triangle.2.circlepath", color: .indigo, compact: true) {
                            DeployView()
                        }
                        MenuTile(title: "Exercises", systemImage: "figure.strengthtraining.traditional", color: .pink, compact: true) {
                            ExercisePickerView()
                        }
                        MenuTile(title: "Habits", systemImage: "checklist", color: .teal, compact: true) {
                            HabitsView()
                        }
                    }

                    MenuTile(title: "Settings", systemImage: "gearshape.fill", color: .gray, fullWidth: true) {
                        SettingsView()
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("YTRun")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(settings)
        .environmentObject(usageTracker)
        .environmentObject(webViewStore)
        .environmentObject(runTracker)
        .environmentObject(cloudSync)
        .environmentObject(downloadManager)
        .environmentObject(aiGatewayClient)
        .environmentObject(chatGPTBridge)
        .environmentObject(walkModeManager)
        .environmentObject(energyLedgerManager)
        .onOpenURL { url in
            chatGPTBridge.handle(url: url)
        }
        .onAppear {
            // Lets the Lock Screen / Control Center play button respect
            // the app's own lock state — without this, tapping play there
            // bypasses the Locked screen entirely, since that remote
            // command otherwise just resumes the video unconditionally.
            webViewStore.isPlaybackAllowed = { [usageTracker, settings, walkModeManager] in
                // Walk mode overrides the normal allowance check entirely
                // while active — allowed exactly when its own periodic
                // "are you still moving" check last said yes, regardless
                // of daily/binge state. See WalkModeManager's own
                // comments for why nothing here interacts with
                // UsageTracker at all.
                if walkModeManager.isActive {
                    return walkModeManager.isCurrentlyMoving
                }
                return !usageTracker.isLockedOut(dailyLimitMinutes: settings.dailyLimitMinutes)
            }
            // Lets the YouTube screen respect Settings' "Restrict Shorts"
            // toggle — see `YouTubeWebViewStore`.
            webViewStore.isShortsRestricted = { [settings] in settings.restrictShorts }
            // Lets the YouTube screen respect its own "Listen Mode"
            // toggle — see `YouTubeWebViewStore`. Forced on during an
            // active Walk session unless the user has explicitly opted
            // into full video while walking (Settings' "walkAllowsVideo")
            // — the whole point of Walk mode defaults to audio-only.
            webViewStore.isListenModeEnabled = { [settings, walkModeManager] in
                if walkModeManager.isActive && !settings.walkAllowsVideo {
                    return true
                }
                return settings.listenModeEnabled
            }

            // Implicit sync trigger #1: the app being opened at all. Runs
            // silently in the background — `cloudSync` already tracks
            // its own in-flight/last-synced/error state for any UI (the
            // Daily History screen) that wants to show it.
            Task { await cloudSync.sync(modelContext: modelContext) }
        }
    }

    // One combined card — every number here is implicitly "today" (or
    // whichever day is selected below), so none of the individual tiles
    // repeat that in their own label.
    private var dashboardBox: some View {
        VStack(spacing: 12) {
            Text(isSelectedDateToday ? "Today" : selectedDate.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .fontWeight(.semibold)

            // Doubles as the day picker — tap a square to select it,
            // instead of stepping through prev/next arrows.
            DayStrip(selectedDate: $selectedDate)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                if isSelectedDateToday {
                    statTile(title: "Daily left", value: minutesText(usageTracker.remainingDailySeconds(dailyLimitMinutes: settings.dailyLimitMinutes)), tint: dailyLeftTint)
                    statTile(title: "Binge left", value: minutesText(usageTracker.bingeRemainingSeconds(bingeLimitMinutes: settings.bingeLimitMinutes)))
                }
                if let stats = energyLedgerManager.stats(for: selectedDate) {
                    navigableStatTile(title: "Earned", value: minutesText(stats.earnedSeconds)) { CreditBreakdownView() }
                    navigableStatTile(title: "Spent", value: minutesText(stats.spentSeconds)) { UsageBreakdownView() }
                    statTile(
                        title: isSelectedDateToday ? (stats.netSeconds < 0 ? "You owe" : "Balance") : "Net",
                        value: minutesText(abs(isSelectedDateToday ? energyLedgerManager.balanceSeconds : stats.netSeconds)),
                        tint: (isSelectedDateToday ? energyLedgerManager.balanceSeconds : stats.netSeconds) < 0 ? .red : .green
                    )
                    // Always navigable, unlike Earned/Spent above — this
                    // one works for any day, not just today (see
                    // `DaySummaryView`), since it just filters real watch
                    // history rather than reading `EnergyLedgerManager`'s
                    // today-only published fields.
                    NavigationLink {
                        DaySummaryView(date: selectedDate)
                    } label: {
                        statTile(title: "Videos", value: "\(stats.videoCount)")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        // An active cooldown only lifts once its timer passes — refresh
        // every second to catch that live instead of looking frozen until
        // the next video plays.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            usageTracker.refreshBingeState()
            // `refresh` self-throttles to every ~8s internally, so piggy-
            // backing on this existing 1-second tick (rather than adding
            // a second timer) costs nothing extra in practice.
            energyLedgerManager.refresh(modelContext: modelContext, settings: settings)
        }
    }

    // Green while still within today's *intended* limit; once past it,
    // orange if the Energy Ledger balance can still cover it (you're
    // spending into today's/rolling profit, but not in debt yet) or red
    // once it can't (over the intended limit AND in debt). Based on raw
    // watched-today seconds rather than `remainingDailySeconds` (which
    // already reflects any borrowed/earned extension) — going past the
    // real target you set is the thing being flagged here, even while a
    // borrowed extension still shows a positive number.
    private var dailyLeftTint: Color {
        guard usageTracker.todayUsedSeconds >= settings.dailyLimitMinutes * 60 else { return .green }
        return energyLedgerManager.balanceSeconds >= 0 ? .orange : .red
    }

    private func minutesText(_ seconds: Int) -> String {
        "\(seconds / 60)m"
    }

    private func statTile(title: String, value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // Only "today" drills into a breakdown — those two detail screens
    // read `EnergyLedgerManager`'s today-only published fields, so a
    // past day's tile just shows its own numbers without navigating
    // anywhere.
    @ViewBuilder
    private func navigableStatTile<Destination: View>(title: String, value: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        if isSelectedDateToday {
            NavigationLink(destination: destination) {
                statTile(title: title, value: value)
            }
            .buttonStyle(.plain)
        } else {
            statTile(title: title, value: value)
        }
    }
}

// #Preview renders this view live in Xcode's canvas without running
// the full app on a simulator/device — handy while iterating on layout.
#Preview {
    ContentView()
        .modelContainer(for: [RunRecord.self, WatchSegment.self, LedgerEvent.self, ChannelCategory.self, HabitType.self], inMemory: true)
}
