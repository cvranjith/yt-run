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
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var aiGatewayClient: AIGatewayClient

    @StateObject private var historyRecorder = WatchHistoryRecorder()
    @Environment(\.modelContext) private var modelContext
    // Drives the custom leading-toolbar "home" button — replaces the
    // default back button (hidden via `.navigationBarBackButtonHidden`)
    // so it can't be confused with the web page's own Back button, which
    // now sits right next to it.
    @Environment(\.dismiss) private var dismiss
    // Reliable watch-vs-listen signal: `.active` means the app is
    // foregrounded (screen on, actually looking at it); anything else
    // (locked, backgrounded) means only audio is being consumed.
    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingURLEntry = false
    @State private var urlInput = ""
    @State private var downloadResultMessage: String?
    @State private var lastDownloadSucceeded = false
    @State private var isShowingDownloadsFromAlert = false
    @State private var isShowingRenameDownload = false
    @State private var renameDownloadText = ""
    @State private var debugInfoMessage: String?
    @State private var isShowingCaptionsViewer = false
    // Regenerated each time the sheet is opened (see the button below)
    // and applied via `.id(...)` — without a changing identity here,
    // SwiftUI can treat repeated presentations of the same sheet content
    // as continuing the *same* view instance rather than a fresh one,
    // silently keeping its old @State (including a stale error from a
    // previous attempt) and never re-running its `.task`.
    @State private var captionsViewerID = UUID()
    @State private var isShowingSummaryViewer = false
    @State private var summaryViewerID = UUID()
    // Peer alternate summarizer via the ChatGPT app — see ChatGPTSummaryDebugView.
    @State private var isShowingChatGPTSummary = false
    @State private var chatGPTSummaryViewerID = UUID()
    // Whether the current video has any captions at all — gates "View
    // Captions"/"Summarize" so tapping either doesn't send a request
    // (to YouTube, or all the way to the AI Gateway) that's guaranteed
    // to just come back empty. Optimistic (`true`) by default so a new
    // video's buttons aren't disabled while the check is still running —
    // most videos do have captions, so this only flips to `false` a
    // moment later for the ones that don't. Keyed by video ID so
    // revisiting a video already checked this session doesn't repeat
    // the lookup.
    @State private var captionsAvailable = true
    // Single-slot, not a growing per-video-ID dictionary — same reasoning
    // as the transcript/summary caches elsewhere (DownloadManager,
    // AIGatewayClient, ChatGPTShortcutBridge): only ever holds the
    // *current* video's result, replaced (not added to) on every video
    // change, so nothing accumulates for the life of the app session.
    @State private var captionsAvailabilityCacheVideoID: String?
    @State private var captionsAvailabilityCacheValue: Bool?

    private var isLocked: Bool {
        usageTracker.isDailyLimitReached(dailyLimitMinutes: settings.dailyLimitMinutes)
            || usageTracker.isInCooldown
    }

    // Drives what the leading control-bar button does: while watching
    // a specific video, it takes you to YouTube's home feed (matching
    // what tapping "Home" in YouTube's own app does); anywhere else
    // (the feed itself, search results, a channel page, ...) it falls
    // back to leaving this screen entirely, with a different icon so
    // the two aren't confused.
    //
    // Checking for the *absence* of a video ID (the same
    // `DownloadManager.videoID(from:)` already used to gate
    // captions/summarize) rather than matching the feed's exact URL
    // shape — that URL isn't reliably just a bare "/" (redirects, query
    // params), so path-matching against it was fragile; "not currently
    // watching a video" is both simpler and matches what this button
    // should actually do everywhere that isn't a watch page.
    private var isOnYouTubeHomeFeed: Bool {
        DownloadManager.videoID(from: webViewStore.currentURL) == nil
    }

    var body: some View {
        Group {
            if isLocked {
                LockedView()
            } else {
                VStack(spacing: 0) {
                    YouTubeWebView(store: webViewStore)
                    // Bottom toolbar, like a normal iPhone app footer,
                    // rather than sitting up top where it used to.
                    // Hidden in DIY fullscreen (see `YouTubeWebViewStore
                    // .isCustomFullscreen`) so it doesn't eat into the
                    // expanded player's space.
                    if !webViewStore.isCustomFullscreen {
                        if downloadManager.isDownloading {
                            downloadProgressBar
                        }
                        statusBar
                        controlBar
                    }
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
        // No native title/toolbar content at all — see `controlBar`.
        // SwiftUI's native `ToolbarItem`/`ToolbarItemGroup` rendering hit
        // a hard, reproducible ceiling on this device: six-ish icon-only
        // items (regardless of how they were split between leading/
        // trailing, or grouped vs. individual `ToolbarItem`s) reliably
        // render broken — some buttons silently vanish, replaced by a
        // second, non-functional "•••"-looking control, confirmed twice
        // over with on-device screenshots after two different attempts
        // at restructuring the *native* toolbar. A plain custom view
        // below the nav bar sidesteps the native toolbar entirely, using
        // the exact same "just a row of buttons in the body" technique
        // `statusBar` already uses without any such issue.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Let the web content run under the status bar/notch area too,
        // since the page has its own chrome — the toolbar is now at the
        // bottom (see body), so it's the *top* edge that's free to be
        // ignored here, not the bottom (which the toolbar should sit
        // above, clear of the home indicator, like a normal footer). In
        // DIY fullscreen, ignore every edge instead, and hide the
        // system status bar too — the expanded player (see
        // `forceElementFullscreenJS`) should fill the whole screen with
        // nothing else competing for space.
        .ignoresSafeArea(edges: webViewStore.isCustomFullscreen ? .all : .top)
        .statusBarHidden(webViewStore.isCustomFullscreen)
        .sheet(isPresented: $isShowingURLEntry) {
            openURLSheet
        }
        .sheet(isPresented: $isShowingCaptionsViewer) {
            CaptionsViewerView()
                .id(captionsViewerID)
        }
        .sheet(isPresented: $isShowingSummaryViewer) {
            SummaryView()
                .id(summaryViewerID)
        }
        .sheet(isPresented: $isShowingChatGPTSummary) {
            ChatGPTSummaryDebugView()
                .id(chatGPTSummaryViewerID)
        }
        .alert("Download", isPresented: Binding(
            get: { downloadResultMessage != nil },
            set: { if !$0 { downloadResultMessage = nil } }
        )) {
            if lastDownloadSucceeded {
                Button("View File") { isShowingDownloadsFromAlert = true }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadResultMessage ?? "")
        }
        .navigationDestination(isPresented: $isShowingDownloadsFromAlert) {
            DownloadsView()
        }
        .alert("Debug Info", isPresented: Binding(
            get: { debugInfoMessage != nil },
            set: { if !$0 { debugInfoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(debugInfoMessage ?? "")
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
            // Re-applies "Restrict Shorts" hiding in case it was toggled
            // in Settings while this screen wasn't visible — a full page
            // load isn't guaranteed to happen just from returning here.
            webViewStore.applyShortsHiding()
            webViewStore.applyListenMode()
            // Implicit sync trigger #2: opening the YouTube screen
            // itself ("whenever I click watch"). `CloudSyncService.sync`
            // already no-ops if a sync is already in flight, so this is
            // safe to fire alongside the one in `ContentView.onAppear`.
            Task { await cloudSync.sync(modelContext: modelContext) }
            updateCaptionsAvailability(for: webViewStore.currentURL)
        }
        .onChange(of: webViewStore.currentURL) { _, newURL in
            updateCaptionsAvailability(for: newURL)
        }
        .onDisappear {
            // Covers fully leaving this screen (e.g. tapping back to Home).
            webViewStore.forceStopAudio()
            historyRecorder.flush(modelContext: modelContext)
            // Safety net: if DIY fullscreen was still active, exit it now
            // rather than leaving the nav bar hidden the next time this
            // screen appears (a plain `didFinish` reset only covers an
            // actual page navigation, not leaving the screen itself).
            webViewStore.exitCustomFullscreenIfNeeded()
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

    // Replaces the native navigation bar's title/toolbar entirely — see
    // the comment on `.toolbar(.hidden, for: .navigationBar)` above for
    // why. Home (app navigation, distinct from the web page's own Back
    // right next to it) / Back / Reload on the left; a "•••" menu for
    // the less-used web controls, then Listen Mode / Download as
    // one-tap buttons, on the right.
    private var controlBar: some View {
        HStack(spacing: 18) {
            Button {
                if isOnYouTubeHomeFeed {
                    dismiss()
                } else {
                    webViewStore.forceLoad(Self.homeURL)
                }
            } label: {
                Image(systemName: isOnYouTubeHomeFeed ? "house.fill" : "house")
            }
            .accessibilityLabel(isOnYouTubeHomeFeed ? "Back to App Home" : "YouTube Home")

            Button {
                webViewStore.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!webViewStore.canGoBack)
            .accessibilityLabel("Back")

            Button {
                webViewStore.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Reload — use this if a video gets stuck")

            Spacer()

            Menu {
                Button {
                    webViewStore.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!webViewStore.canGoForward)

                Button {
                    isShowingURLEntry = true
                } label: {
                    Label("Open a Link", systemImage: "link.badge.plus")
                }

                // Temporary, while Listen Mode / fullscreen are being
                // debugged without live browser access — see
                // `YouTubeWebViewStore.fetchDebugInfo()`.
                Button {
                    Task { debugInfoMessage = await webViewStore.fetchDebugInfo() }
                } label: {
                    Label("Debug Info", systemImage: "ladybug")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")

            Button {
                settings.listenModeEnabled.toggle()
                webViewStore.applyListenMode()
            } label: {
                Image(systemName: settings.listenModeEnabled ? "headphones.circle.fill" : "headphones.circle")
            }
            .accessibilityLabel(settings.listenModeEnabled ? "Turn off Listen Mode" : "Turn on Listen Mode")

            Menu {
                Button {
                    Task { await performDownload(kind: .video) }
                } label: {
                    Label("Download Video", systemImage: "video")
                }

                Button {
                    Task { await performDownload(kind: .audio) }
                } label: {
                    Label("Download Audio Only", systemImage: "waveform")
                }

                Button {
                    captionsViewerID = UUID()
                    isShowingCaptionsViewer = true
                } label: {
                    Label("View Captions", systemImage: "captions.bubble")
                }
                .disabled(!captionsAvailable)

                Button {
                    summaryViewerID = UUID()
                    isShowingSummaryViewer = true
                } label: {
                    Label("Summarize", systemImage: "text.bubble")
                }
                .disabled(!captionsAvailable)

                // A peer path via the user's own ChatGPT app + a
                // Shortcut instead of ai-gateway; see
                // ChatGPTSummaryDebugView / chatgpt-shortcut-setup.md.
                Button {
                    chatGPTSummaryViewerID = UUID()
                    isShowingChatGPTSummary = true
                } label: {
                    Label("Summarize via ChatGPT", systemImage: "sparkles")
                }
                .disabled(!captionsAvailable)
            } label: {
                if downloadManager.isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .disabled(downloadManager.isDownloading)
            .accessibilityLabel("Download")
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
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

    // Only shown while a download is actually in flight. A linear
    // `ProgressView(value:)` rather than trying to cram a percentage
    // into the small toolbar icon — `downloadManager.downloadProgress`
    // stays 0 (falls back to an indeterminate bar) if the server
    // response never included a Content-Length to compute a fraction
    // from, which is out of our control.
    //
    // The title row doubles as the rename affordance (tap to edit) and
    // carries the Cancel button — both act on `downloadManager` directly
    // rather than through a result callback, since there's no "result"
    // yet for an in-flight download.
    private var downloadProgressBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    renameDownloadText = downloadManager.currentDownloadTitle ?? ""
                    isShowingRenameDownload = true
                } label: {
                    HStack(spacing: 4) {
                        Text(downloadManager.currentDownloadTitle ?? "Downloading…")
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    downloadManager.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel Download")
            }

            if downloadManager.downloadProgress > 0 {
                ProgressView(value: downloadManager.downloadProgress)
                Text("\(Int(downloadManager.downloadProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .background(.bar)
        .alert("Rename Download", isPresented: $isShowingRenameDownload) {
            TextField("Name", text: $renameDownloadText)
            Button("Save") {
                downloadManager.renameCurrentDownload(to: renameDownloadText)
            }
            Button("Cancel", role: .cancel) {}
        }
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

    // Downloads whatever's currently loaded — the caller (an explicit
    // "Download Video" or "Download Audio Only" menu tap) picks which,
    // independent of whether Listen Mode happens to be on. Resolves the
    // actual download URL server-side via ai-gateway's youtube_download
    // service (see `AIGatewayClient.resolveDownloadURL`) rather than
    // scraping the page — works for effectively any video, not just the
    // subset the old WebView-scraping approach could reach.
    private func performDownload(kind: AIGatewayDownloadKind) async {
        guard let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            lastDownloadSucceeded = false
            showDownloadResult("Couldn't tell which video this is — try again once the page has fully loaded.")
            return
        }
        let info = await webViewStore.fetchDownloadInfo()
        let result = await downloadManager.download(
            videoID: videoID,
            kind: kind,
            title: info?.title ?? "Video",
            aiGatewayClient: aiGatewayClient,
            settings: settings
        )
        switch result {
        case .success(let url):
            lastDownloadSucceeded = true
            showDownloadResult("Saved as \(url.lastPathComponent).")
        case .failure(let error):
            lastDownloadSucceeded = false
            showDownloadResult(error.message)
        }
    }

    // Auto-dismisses after a few seconds rather than sitting there until
    // tapped away — a "View File"/"OK" choice is nice to have, but
    // shouldn't be mandatory just to keep watching. Guards against a
    // stale timer clobbering a newer message (e.g. a second, faster
    // download finishing before this one's 5 seconds are up) by only
    // clearing if the message it was scheduled for is still showing.
    private func showDownloadResult(_ message: String) {
        downloadResultMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if downloadResultMessage == message {
                downloadResultMessage = nil
            }
        }
    }

    // Checks (and caches, per video ID) whether the current video has
    // any captions at all, so "View Captions"/"Summarize" can be
    // disabled up front instead of failing after a round trip. Not a
    // watch page at all (no video ID) counts as unavailable too, since
    // neither action means anything there.
    private func updateCaptionsAvailability(for url: URL?) {
        guard let videoID = DownloadManager.videoID(from: url) else {
            captionsAvailable = false
            return
        }
        if videoID == captionsAvailabilityCacheVideoID, let cached = captionsAvailabilityCacheValue {
            captionsAvailable = cached
            return
        }
        captionsAvailable = true
        Task {
            let available = await downloadManager.hasCaptions(videoID: videoID)
            captionsAvailabilityCacheVideoID = videoID
            captionsAvailabilityCacheValue = available
            // Only apply if still on the same video — a quick nav away
            // and back shouldn't let a slower, now-stale check clobber
            // whatever the more recent one already decided.
            if DownloadManager.videoID(from: webViewStore.currentURL) == videoID {
                captionsAvailable = available
            }
        }
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
    .environmentObject(DownloadManager())
    .environmentObject(AIGatewayClient())
    .environmentObject(ChatGPTShortcutBridge())
}
