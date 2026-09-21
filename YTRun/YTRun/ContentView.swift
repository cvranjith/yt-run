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
    // scroll.
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
    // whichever day is selected below).
    private var dashboardBox: some View {
        VStack(spacing: 14) {
            Text(isSelectedDateToday ? "Today" : selectedDate.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .fontWeight(.semibold)

            // Doubles as the day picker — tap a square to select it,
            // instead of stepping through prev/next arrows.
            DayStrip(selectedDate: $selectedDate)

            if let stats = energyLedgerManager.stats(for: selectedDate) {
                QuotaBarChart(
                    quotaSeconds: settings.dailyLimitMinutes * 60,
                    spentSeconds: stats.spentSeconds,
                    earnedSeconds: stats.earnedSeconds
                )

                netCaption(for: stats)

                if isSelectedDateToday {
                    bingeBar
                }

                footerRow(stats: stats)
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

    // "Profit"/"Owe" language matches the chart's own segment labels —
    // this is literally that day's net, just spelled out. For today
    // specifically, also shows the *rolling* multi-day balance
    // underneath in smaller text, since that's a genuinely different
    // number once more than one day is in play (a profit today doesn't
    // erase debt carried in from yesterday).
    private func netCaption(for stats: EnergyLedgerDayStats) -> some View {
        VStack(spacing: 2) {
            Group {
                if stats.netSeconds >= 0 {
                    Text("Profit +\(stats.netSeconds / 60)m")
                        .foregroundStyle(.green)
                } else {
                    Text("Owe \(abs(stats.netSeconds) / 60)m")
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            .fontWeight(.semibold)

            if isSelectedDateToday {
                Text("Rolling balance (last \(settings.ledgerWindowDays)d): \(energyLedgerManager.balanceSeconds >= 0 ? "+" : "")\(energyLedgerManager.balanceSeconds / 60)m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bingeBar: some View {
        let limitSeconds = settings.bingeLimitMinutes * 60
        let remaining = usageTracker.bingeRemainingSeconds(bingeLimitMinutes: settings.bingeLimitMinutes)
        let used = max(0, limitSeconds - remaining)
        let fraction = limitSeconds > 0 ? min(1, Double(used) / Double(limitSeconds)) : 0
        let isCritical = UsageTracker.isCritical(remainingSeconds: remaining, limitSeconds: limitSeconds)
        let barColor: Color = usageTracker.isInCooldown ? .red : (isCritical ? .orange : .blue)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Binge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(usageTracker.isInCooldown ? "Cooldown" : "\(remaining / 60)m left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
    }

    // Videos always drills in (works for any day — see `DaySummaryView`);
    // Earned/Spent only do for today, since those two detail screens
    // read `EnergyLedgerManager`'s today-only published fields.
    private func footerRow(stats: EnergyLedgerDayStats) -> some View {
        HStack {
            if isSelectedDateToday {
                NavigationLink("View earnings") { CreditBreakdownView() }
                Text("·").foregroundStyle(.secondary)
                NavigationLink("View spending") { UsageBreakdownView() }
                Spacer()
            }
            NavigationLink {
                DaySummaryView(date: selectedDate)
            } label: {
                Label("\(stats.videoCount) videos", systemImage: "play.rectangle")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: isSelectedDateToday ? .leading : .trailing)
    }
}

// #Preview renders this view live in Xcode's canvas without running
// the full app on a simulator/device — handy while iterating on layout.
#Preview {
    ContentView()
        .modelContainer(for: [RunRecord.self, WatchSegment.self, LedgerEvent.self, ChannelCategory.self, HabitType.self], inMemory: true)
}
