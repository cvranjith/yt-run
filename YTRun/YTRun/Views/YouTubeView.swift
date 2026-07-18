//
//  YouTubeView.swift
//  YTRun
//

import SwiftUI
import Combine
import SwiftData

struct YouTubeView: View {
    private static let homeURL = URL(string: "https://m.youtube.com")!

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker
    @EnvironmentObject var webViewStore: YouTubeWebViewStore
    @EnvironmentObject var cloudSync: CloudSyncService

    @StateObject private var historyRecorder = WatchHistoryRecorder()
    @Environment(\.modelContext) private var modelContext
    // Reliable watch-vs-listen signal: `.active` means the app is
    // foregrounded (screen on, actually looking at it); anything else
    // (locked, backgrounded) means only audio is being consumed.
    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingURLEntry = false
    @State private var urlInput = ""

    private var isLocked: Bool {
        usageTracker.isDailyLimitReached(dailyLimitMinutes: settings.dailyLimitMinutes)
            || usageTracker.isInCooldown
    }

    var body: some View {
        Group {
            if isLocked {
                LockedView()
            } else {
                VStack(spacing: 0) {
                    statusBar
                    YouTubeWebView(store: webViewStore)
                }
                // A repeating timer, not tied to WKWebView at all — every
                // second, if the page told us it's playing, add one second
                // to today's usage and to the binge counter (which may
                // trigger a cooldown); otherwise just check whether a
                // cooldown that was already active has expired. `.common`
                // run loop mode keeps this firing even while the user is
                // scrolling/interacting.
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    if webViewStore.isPlaying {
                        let isBackground = scenePhase != .active
                        // Only worth checking the audio route while
                        // actually backgrounded — foreground playback is
                        // always "View" regardless of output.
                        let isCarAudio = isBackground && CarAudioDetector.isCarAudioActive(carDeviceName: settings.carBluetoothDeviceName)
                        let weight: Double = !isBackground ? 1.0
                            : (isCarAudio ? Double(settings.carRatePercent) : Double(settings.listenRatePercent)) / 100.0

                        usageTracker.recordTick(
                            weight: weight,
                            bingeLimitMinutes: settings.bingeLimitMinutes,
                            cooldownMinutes: settings.cooldownMinutes,
                            bingeResetAfterMinutes: settings.bingeResetAfterMinutes
                        )
                        historyRecorder.tick(
                            isBackground: isBackground,
                            isCarAudio: isCarAudio,
                            isShorts: webViewStore.currentURL?.path.contains("/shorts/") ?? false,
                            channelName: webViewStore.currentChannelName,
                            videoURL: webViewStore.currentURL?.absoluteString,
                            modelContext: modelContext
                        )

                        // Checked right here, in the same reliable
                        // per-second callback that's already proven to
                        // keep firing in the background (that's how usage
                        // gets tracked at all while locked) — rather than
                        // relying solely on `.onChange(of: isLocked)`
                        // below, whose SwiftUI-render-driven firing can
                        // lag while the app isn't actually on screen,
                        // letting audio keep playing well past the limit.
                        if isLocked {
                            webViewStore.forceStopAudio()
                        }
                    } else {
                        usageTracker.refreshBingeState(bingeResetAfterMinutes: settings.bingeResetAfterMinutes)
                        historyRecorder.flush(modelContext: modelContext)
                    }
                }
            }
        }
        .navigationTitle("YouTube")
        .navigationBarTitleDisplayMode(.inline)
        // Let the web content run under the status bar/notch area too,
        // since the page has its own chrome.
        .ignoresSafeArea(edges: .bottom)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    webViewStore.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!webViewStore.canGoBack)
                .accessibilityLabel("Back")

                Button {
                    webViewStore.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!webViewStore.canGoForward)
                .accessibilityLabel("Forward")

                Button {
                    webViewStore.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload — use this if a video gets stuck")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isShowingURLEntry = true
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .accessibilityLabel("Open a pasted link")
            }
        }
        .sheet(isPresented: $isShowingURLEntry) {
            openURLSheet
        }
        .onAppear {
            // Only load the default page the very first time this screen
            // is ever shown — on later visits `lastLoadedURL` is already
            // set, so this is a no-op and whatever was playing/showing
            // before is still there.
            if webViewStore.lastLoadedURL == nil {
                webViewStore.load(Self.homeURL)
            }
            // Harmless if already active — makes sure playback can
            // actually resume after a previous lock forcibly deactivated
            // the audio session (see `forceStopAudio`).
            webViewStore.reactivateAudioSession()
            // Implicit sync trigger #2: opening the YouTube screen
            // itself ("whenever I click watch"). `CloudSyncService.sync`
            // already no-ops if a sync is already in flight, so this is
            // safe to fire alongside the one in `ContentView.onAppear`.
            Task { await cloudSync.sync(modelContext: modelContext) }
        }
        .onDisappear {
            // Covers fully leaving this screen (e.g. tapping back to Home).
            webViewStore.forceStopAudio()
            historyRecorder.flush(modelContext: modelContext)
        }
        .onChange(of: isLocked) { _, locked in
            // Covers becoming locked *while still on this screen* (hitting
            // the daily/binge limit mid-video) — swapping to `LockedView`
            // doesn't tear down the persistent web view the way the old
            // per-visit web view used to, so it needs an explicit pause.
            // Kept as a second line of defense alongside the timer-tick
            // check above; this one also handles becoming locked via a
            // path that doesn't go through a tick (e.g. midnight rollover
            // with the app already open).
            if locked {
                webViewStore.forceStopAudio()
                historyRecorder.flush(modelContext: modelContext)
            } else {
                webViewStore.reactivateAudioSession()
            }
        }
    }

    // Single-line bar above the web content. Two separate labels (each
    // with its own title above value) wrapped to two lines and ate too
    // much vertical space — this packs both numbers into one compact row.
    private var statusBar: some View {
        let dailySeconds = usageTracker.remainingDailySeconds(dailyLimitMinutes: settings.dailyLimitMinutes)
        let dailyMinutes = (dailySeconds + 59) / 60
        let dailyCritical = UsageTracker.isCritical(remainingSeconds: dailySeconds, limitSeconds: settings.dailyLimitMinutes * 60)

        let bingeSeconds = usageTracker.bingeRemainingSeconds(bingeLimitMinutes: settings.bingeLimitMinutes)
        let bingeMinutes = (bingeSeconds + 59) / 60
        let bingeCritical = UsageTracker.isCritical(remainingSeconds: bingeSeconds, limitSeconds: settings.bingeLimitMinutes * 60)

        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            // `Text` values combined with `+` render as one continuous
            // line while still letting each segment keep its own color —
            // an `HStack` of separate `Text`s would add uneven gaps
            // around the punctuation instead.
            Text("Remaining: ").foregroundStyle(.secondary)
                + Text("Daily \(dailyMinutes)m").foregroundStyle(dailyCritical ? .red : .primary)
                + Text(", Binge \(bingeMinutes)m").foregroundStyle(bingeCritical ? .red : .primary)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // A `.sheet` is a modal card that slides up from the bottom — the
    // standard iOS way to ask for a small piece of input without leaving
    // the current screen.
    private var openURLSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Video URL or ID", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Paste a YouTube link (e.g. youtube.com/watch?v=… or youtu.be/…) or just the video ID.")
                }

                Button("Paste from Clipboard") {
                    if let clipboardText = UIPasteboard.general.string {
                        urlInput = clipboardText
                    }
                }
            }
            .navigationTitle("Open Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingURLEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        if let resolved = Self.resolveURL(from: urlInput) {
                            webViewStore.load(resolved)
                        }
                        isShowingURLEntry = false
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // Accepts either a bare video ID ("dQw4w9WgXcQ") or a full URL in any
    // of YouTube's link shapes (youtube.com/watch?v=…, youtu.be/…,
    // youtube.com/shorts/…) and turns it into something WKWebView can load.
    static func resolveURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // No "/" or "." means this doesn't look like a URL at all — treat
        // it as a bare video ID and build the watch URL ourselves.
        if !trimmed.contains("/") && !trimmed.contains(".") {
            return URL(string: "https://m.youtube.com/watch?v=\(trimmed)")
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        // Pasted without a scheme, e.g. "youtu.be/dQw4w9WgXcQ".
        return URL(string: "https://\(trimmed)")
    }
}

#Preview {
    NavigationStack {
        YouTubeView()
    }
    .environmentObject(AppSettings())
    .environmentObject(UsageTracker())
    .environmentObject(YouTubeWebViewStore())
    .environmentObject(CloudSyncService())
}
