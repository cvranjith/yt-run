//
//  YouTubeWebViewStore.swift
//  YTRun
//

@preconcurrency import WebKit
import AVFoundation
import MediaPlayer
import Combine

// Owns a single, long-lived `WKWebView` for the whole app session. Created
// once at the root (`ContentView`) and shared via `.environmentObject`, so
// navigating away from the YouTube screen and back reuses the *same* web
// view instead of tearing it down and reloading — the video, scroll
// position, and page state all stay exactly where you left them.
//
// This also means all the WKWebView setup (persistent cookies, injected
// JS, audio session, lock-screen controls) only ever happens once, instead
// of being rebuilt every time the screen appears.
@MainActor
final class YouTubeWebViewStore: NSObject, ObservableObject {
    let webView: WKWebView

    @Published private(set) var isPlaying = false
    private(set) var lastLoadedURL: URL?

    // Mirrors the WKWebView's own back/forward history — drives the
    // toolbar's Back/Forward buttons (disabled when there's nowhere to
    // go). Kept in sync via KVO through Combine's `publisher(for:)`
    // rather than polled, since WKWebView updates these as navigation
    // happens.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    // Live page info reported by the JS bridge below — updates as the
    // user navigates within YouTube (including Shorts swipes, which don't
    // trigger a normal page-load navigation). Used by
    // `WatchHistoryRecorder` to categorize what's being watched.
    @Published private(set) var currentURL: URL?
    // Best-effort scrape of the channel name; nil if not found on the
    // current page (either it hasn't loaded yet, or YouTube's markup
    // didn't match what we look for).
    @Published private(set) var currentChannelName: String?

    // Reflects the DIY "fake fullscreen" state from `forceElementFullscreenJS`
    // — drives hiding the app's own nav bar/status bar/status row in
    // `YouTubeView` so the expanded player isn't squeezed by them.
    @Published private(set) var isCustomFullscreen = false

    // Wired from `ContentView` to reflect the app's actual lock state.
    // Gates the Lock Screen / Control Center play button — without this,
    // that remote command bypasses the Locked screen entirely, since it
    // otherwise just resumes the video unconditionally.
    var isPlaybackAllowed: () -> Bool = { true }

    // Wired from `ContentView` to reflect Settings' "Restrict Shorts"
    // toggle.
    var isShortsRestricted: () -> Bool = { false }

    // Wired from `ContentView` to reflect the YouTube screen's own
    // "Listen Mode" toggle (deliberately not a Settings-only switch — it's
    // meant to be flipped in the moment, right where you're watching).
    var isListenModeEnabled: () -> Bool = { false }

    private static let homeURL = URL(string: "https://m.youtube.com")!

    override init() {
        let configuration = WKWebViewConfiguration()

        // `.default()` is a *persistent* data store — cookies and local
        // storage survive app relaunches, so once you're logged into
        // YouTube (or even just as a guest with watch history), that
        // session sticks around.
        configuration.websiteDataStore = .default()

        // Let <video> play inline instead of forcing iOS's native
        // fullscreen player.
        configuration.allowsInlineMediaPlayback = true

        // Don't require a user tap before JS can start playback —
        // needed so our lock-screen play button can resume the video
        // programmatically.
        //
        // Tried `.all` here to stop YouTube's autoplay-on-load (the
        // actual ask was for videos to open paused, not autoplaying).
        // It didn't work — YouTube's autoplay still happened regardless
        // — and it broke YouTube's own muted-autoplay fallback in the
        // process (autoplay became audible instead of silent), a
        // straight regression with none of the intended benefit. Back
        // to `[]`: autoplaying muted (YouTube's own default behavior)
        // is the accepted trade-off for now.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Make YouTube's fullscreen button use the DOM Fullscreen API
        // (fullscreening the player *container* div) instead of iOS's
        // native `<video>` fullscreen. YouTube renders captions/CC as its
        // own HTML overlay on top of the video, not as native <video> text
        // tracks — so when iOS takes just the raw <video> element
        // fullscreen, that caption overlay is left behind and CC vanishes.
        // Element fullscreen keeps the whole player DOM (overlay included)
        // on screen, so captions stay visible in fullscreen. iOS 15.4+.
        if #available(iOS 15.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        // Runs before any of YouTube's own scripts (`.atDocumentStart`).
        // Mobile YouTube pauses its own video when it thinks the tab is
        // hidden (via the Page Visibility API) — which is exactly what
        // happens when we go to the background for lock-screen playback.
        // This makes the page believe it's always visible.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.antiPauseJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Defines window.__ytrunPlayerControls — shared play/pause/seek/
        // speed helpers used by both Listen Mode and the DIY fullscreen
        // overlay. Must be added before either of those.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.playerControlsJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Must run before YouTube's own player script initializes and
        // checks `video.webkitSupportsFullscreen` — see
        // `forceElementFullscreenJS` for why this keeps captions visible
        // in fullscreen.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.forceElementFullscreenJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Defines window.__ytrunSetHideShorts(bool), which Swift calls
        // after every navigation (and when the screen re-appears) to
        // reflect Settings' "Restrict Shorts" toggle. Runs at document
        // start purely to make the function available early; it doesn't
        // hide anything by itself until called.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.shortsHideJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Defines window.__ytrunSetListenMode(bool) — see `listenModeJS`
        // for what it actually does (force lowest video quality, cover
        // the player with an audio-styled overlay).
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.listenModeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // Defines window.__ytrunGetDownloadInfo() — see `downloadInfoJS`.
        // Runs at document start (not just when Download is tapped) so
        // its fetch/XHR monkey-patch is in place before YouTube's own
        // scripts start requesting media, which is what lets it observe
        // the real, already-resolved stream URLs the player uses.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.downloadInfoJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )


        // Runs after the page loads (`.atDocumentEnd`). Watches for the
        // <video> element YouTube creates and reports play/pause back to
        // Swift, and exposes window.__ytrunPlay/__ytrunPause/__ytrunToggle
        // so Swift can drive playback from lock-screen controls.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )

        // Runs after the page loads. Reports URL + channel name changes
        // for daily-history categorization (watch/listen is determined on
        // the Swift side via scenePhase; this covers Shorts-vs-video and
        // channel).
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pageInfoJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView

        super.init()

        webView.navigationDelegate = self
        // Registers self to receive
        // `window.webkit.messageHandlers.playback.postMessage(...)` calls
        // from the injected JS above. Added once here and never removed,
        // since this store — and the web view — live for the app's
        // lifetime.
        configuration.userContentController.add(self, name: "playback")
        // Reports the current URL + scraped channel name whenever either
        // changes — see the `pageInfoJS` script for how it detects
        // Shorts-style navigation that doesn't trigger a normal page load.
        configuration.userContentController.add(self, name: "pageInfo")
        // Reports DIY-fullscreen enter/exit — see `forceElementFullscreenJS`.
        configuration.userContentController.add(self, name: "customFullscreen")

        configureAudioSession()
        configureRemoteCommandCenter()

        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canGoForward)
    }

    // Loads a URL only if it's actually different from what's already
    // showing — repeated calls with the same URL (e.g. from a view
    // re-appearing) are a no-op, which is exactly what lets returning to
    // the YouTube screen resume instead of reloading.
    func load(_ url: URL) {
        guard lastLoadedURL != url else { return }
        lastLoadedURL = url
        webView.load(URLRequest(url: url))
    }

    // Same as `load(_:)` but skips its same-URL dedup check — for an
    // explicit user action (the control bar's "YouTube Home" button)
    // that must always actually navigate. `lastLoadedURL` only tracks
    // URLs *we've* explicitly loaded from Swift, so it goes stale the
    // moment the user taps into a video via YouTube's own in-page
    // (SPA/pushState) navigation — `load(_:)` would then wrongly think
    // "already there" and silently no-op if that stale value happened
    // to already equal `url` (e.g. `lastLoadedURL` still says the home
    // feed from the very first load, even though the page has long
    // since moved on to a video).
    func forceLoad(_ url: URL) {
        lastLoadedURL = url
        webView.load(URLRequest(url: url))
    }

    // Wipes cookies/localStorage/etc. for youtube.com only (not the
    // whole persistent data store) and reloads fresh. Signs out of
    // YouTube in the app if you were signed in, and resets anything
    // YouTube itself remembers client-side (including, notably, a
    // stuck "autoplay unmuted" preference a video's volume/mute state
    // can persist once set — this is the fix for that, since there's
    // no more targeted API to clear just one such preference).
    func clearWebsiteData(completion: @escaping () -> Void = {}) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            let youtubeRecords = records.filter { $0.displayName.contains("youtube") }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: youtubeRecords) {
                DispatchQueue.main.async {
                    guard let self else { completion(); return }
                    self.lastLoadedURL = nil
                    self.forceLoad(Self.homeURL)
                    completion()
                }
            }
        }
    }

    func pause() {
        webView.evaluateJavaScript("window.__ytrunPause && window.__ytrunPause();")
    }

    // Standard browser controls — for when a video/page gets stuck (the
    // WKWebView equivalent of a spinning tab that just needs a refresh).
    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    // Stronger than `pause()` alone. `evaluateJavaScript` calls made while
    // the app is backgrounded (the exact moment this matters — the limit
    // being hit while the phone is locked) aren't guaranteed to run
    // promptly: the WKWebView content process can be suspended for
    // rendering/JS purposes even while its already-established audio
    // keeps playing, so the JS `pause()` can silently no-op and audio
    // just keeps going until the user notices. Deactivating the audio
    // session stops output at the OS level regardless of WKWebView's own
    // state, so it's used as the real enforcement mechanism; the JS call
    // is kept alongside it so the page's own UI (its play/pause button)
    // reflects the paused state too when it does get a chance to run.
    func forceStopAudio() {
        pause()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    // Re-activates the audio session after a `forceStopAudio()` call, so
    // playback can actually resume once allowed again (e.g. after a run
    // clears a cooldown). Safe to call even if already active.
    func reactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to reactivate audio session: \(error)")
        }
    }

    private static func isShortsURL(_ url: URL?) -> Bool {
        url?.path.contains("/shorts/") ?? false
    }

    // Sends the web view back to YouTube's home feed — used when a Shorts
    // page slips through while restricted.
    private func redirectAwayFromShorts() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    // Pushes the current "Restrict Shorts" state into the page so Shorts
    // shelves/thumbnails (and their autoplay-muted previews) are hidden
    // outright on the home feed, search results, etc. — not just blocked
    // once tapped. Called after every page load and whenever the YouTube
    // screen re-appears, since a full page load resets the page's own DOM
    // (and thus any previously injected <style>).
    func applyShortsHiding() {
        webView.evaluateJavaScript("window.__ytrunSetHideShorts(\(isShortsRestricted()));")
    }

    // Pushes the current "Listen Mode" state into the page. Called after
    // every page load, whenever the YouTube screen re-appears, and
    // immediately when the toolbar toggle is flipped (rather than waiting
    // for the next navigation), so switching modes takes effect right away.
    func applyListenMode() {
        webView.evaluateJavaScript("window.__ytrunSetListenMode(\(isListenModeEnabled()));")
    }

    // Forces an exit from the DIY "fake fullscreen" state (see
    // `forceElementFullscreenJS`) and resets the published flag —
    // safety-net cleanup for leaving the YouTube screen entirely while
    // it was active, called from `YouTubeView.onDisappear`.
    func exitCustomFullscreenIfNeeded() {
        guard isCustomFullscreen else { return }
        webView.evaluateJavaScript("window.__ytrunExitFakeFullscreen && window.__ytrunExitFakeFullscreen();")
        isCustomFullscreen = false
    }

    // Pulls the current page's title and best-available media stream
    // URLs for the Download feature — see `downloadInfoJS` for exactly
    // how those are found. Returns nil only if the JS bridge itself
    // couldn't run at all (e.g. called mid-navigation); a result with a
    // nil `videoURL`/`audioURL` just means that particular stream wasn't
    // available for this video (see `DownloadManager`).
    func fetchDownloadInfo() async -> DownloadInfo? {
        guard let dict = try? await webView.evaluateJavaScript("window.__ytrunGetDownloadInfo();") as? [String: Any],
              let title = dict["title"] as? String else {
            return nil
        }
        return DownloadInfo(
            title: title,
            userAgent: dict["userAgent"] as? String,
            videoURL: (dict["videoURL"] as? String).flatMap(URL.init(string:)),
            audioURL: (dict["audioURL"] as? String).flatMap(URL.init(string:))
        )
    }

    // Temporary diagnostic for the Listen Mode / fullscreen issues —
    // surfaces what's actually happening inside the page (which we can't
    // otherwise see, having no live browser access from the sandbox this
    // is developed in) via the "Debug Info" menu item in `YouTubeView`.
    // Remove once both are confirmed working on-device.
    func fetchDebugInfo() async -> String {
        let script = """
        (function () {
            var overlay = document.getElementById('__ytrunListenOverlay');
            var video = document.querySelector('video');
            var info = {
                inIframe: window.top !== window.self,
                overlayExists: !!overlay,
                overlayDisplay: overlay ? getComputedStyle(overlay).display : null,
                overlayClass: overlay ? overlay.className : null,
                listenModeEnabledInJS: (typeof window.__ytrunListenModeDebugState !== 'undefined') ? window.__ytrunListenModeDebugState : null,
                listenOverlayError: window.__ytrunListenOverlayError || null,
                moviePlayerExists: !!document.getElementById('movie_player'),
                videoExists: !!video,
                videoTagName: video ? video.tagName : null,
                fullscreenAPI: {
                    requestFullscreen: typeof Element.prototype.requestFullscreen === 'function',
                    webkitRequestFullscreen: typeof Element.prototype.webkitRequestFullscreen === 'function',
                    webkitRequestFullScreen: typeof Element.prototype.webkitRequestFullScreen === 'function',
                    documentFullscreenEnabled: !!document.fullscreenEnabled,
                    documentWebkitFullscreenEnabled: !!document.webkitFullscreenEnabled
                },
                lastFullscreenAttempt: window.__ytrunLastFullscreenAttempt || null
            };
            return JSON.stringify(info);
        })();
        """
        guard let result = try? await webView.evaluateJavaScript(script) as? String else {
            return "Debug script failed to run or returned no result."
        }
        return result
    }

    // MARK: Audio session

    // Declaring the "audio" Background Mode (in project settings) is not
    // enough by itself — the app also needs an active AVAudioSession in
    // the `.playback` category so iOS knows this is an audio app allowed
    // to keep running once backgrounded.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("AVAudioSession setup failed: \(error)")
        }
    }

    // MARK: Lock screen / Control Center

    // `MPRemoteCommandCenter` is how Lock Screen / Control Center
    // play-pause buttons talk back to the app.
    private func configureRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaybackAllowed() else { return .commandFailed }
            self.reactivateAudioSession()
            self.webView.evaluateJavaScript("window.__ytrunPlay && window.__ytrunPlay();")
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            // Pausing is always allowed — only resuming is gated.
            self?.webView.evaluateJavaScript("window.__ytrunPause && window.__ytrunPause();")
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isPlaying, !self.isPlaybackAllowed() {
                // Currently paused and not allowed to resume — refuse the
                // toggle rather than letting it flip to playing.
                return .commandFailed
            }
            self.webView.evaluateJavaScript("window.__ytrunToggle && window.__ytrunToggle();")
            return .success
        }
    }

    // Feeds the Lock Screen / Control Center "Now Playing" widget so it
    // shows something sensible and its play/pause icon reflects real
    // state.
    private func updateNowPlayingInfo(isPlaying: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = "YouTube"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Injected JavaScript

    private static let antiPauseJS = """
    (function () {
        Object.defineProperty(document, 'hidden', { get: function () { return false; } });
        Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
        var block = function (event) { event.stopImmediatePropagation(); };
        document.addEventListener('visibilitychange', block, true);
        document.addEventListener('webkitvisibilitychange', block, true);
    })();
    """

    // Best-effort CSS selectors for Shorts on both the mobile (`ytm-`) and
    // desktop (`ytd-`) YouTube web front ends — covers the home feed
    // shelf, individual thumbnails wherever they appear (search, related,
    // etc.), and the "Shorts" tab in the bottom nav / top tab strip.
    // `display: none` hides the element before any preview video inside
    // it can even start loading. YouTube's markup changes over time, so
    // this may need updating if a selector stops matching.
    private static let shortsHideJS = """
    (function () {
        var css = [
            'ytm-reel-shelf-renderer',
            'ytm-rich-shelf-renderer[is-shorts]',
            'ytm-shorts-lockup-view-model',
            'ytm-shorts-lockup-view-model-v2',
            'ytd-reel-shelf-renderer',
            'ytd-rich-shelf-renderer[is-shorts]',
            '[is-shorts]',
            'a[href^="/shorts/"]',
            'ytm-pivot-bar-item-renderer:has(a[href^="/shorts"])',
            'tp-yt-paper-tab:has(a[href^="/shorts"])'
        ].join(', ') + ' { display: none !important; }';

        var styleId = '__ytrunHideShortsStyle';

        window.__ytrunSetHideShorts = function (enabled) {
            var existing = document.getElementById(styleId);
            if (enabled) {
                if (!existing) {
                    var style = document.createElement('style');
                    style.id = styleId;
                    style.textContent = css;
                    (document.head || document.documentElement).appendChild(style);
                }
            } else if (existing) {
                existing.remove();
            }
        };
    })();
    """

    // Shared play/pause/seek/speed remote-control helpers, used by both
    // Listen Mode's overlay and the DIY fullscreen overlay (see
    // `listenModeJS`/`forceElementFullscreenJS`) — extracted here once
    // both needed the exact same thing, rather than duplicating it.
    // Routed through YouTube's own `#movie_player` API where possible
    // (the same object the quality-forcing code already uses) rather
    // than poking the raw <video> element directly — seeking in
    // particular needs to go through the player's own logic to fetch
    // whatever new buffered range the seek lands in, which YouTube's JS
    // handles and a bare `video.currentTime = x` assignment does not
    // always. Each falls back to the raw <video> element if the player
    // API method isn't there.
    //
    // Also defines the shared `.ytrun-btn`/`.ytrun-controls`/etc. CSS
    // classes both overlays' control rows use, so the two don't
    // duplicate that styling either.
    private static let playerControlsJS = """
    (function () {
        var styleId = '__ytrunControlsStyle';
        var playbackRates = [1, 1.25, 1.5, 1.75, 2];

        var style = document.createElement('style');
        style.id = styleId;
        style.textContent =
            '.ytrun-transport{display:flex;flex-direction:column;align-items:center;gap:10px;' +
            'pointer-events:auto;width:100%;font-family:-apple-system,sans-serif;}' +
            '.ytrun-seekbar{width:90%;max-width:360px;accent-color:#fff;}' +
            '.ytrun-time{color:#fff;font-size:13px;opacity:0.85;font-variant-numeric:tabular-nums;}' +
            '.ytrun-controls{display:flex;align-items:center;gap:14px;}' +
            '.ytrun-btn{background:rgba(255,255,255,0.16);color:#fff;border:none;' +
            'border-radius:10px;padding:10px 14px;font-size:15px;min-width:44px;min-height:44px;}' +
            '.ytrun-btn-primary{font-size:22px;padding:10px 20px;}';
        (document.head || document.documentElement).appendChild(style);

        function getPlayer() {
            return document.getElementById('movie_player');
        }

        function findVideo() {
            return document.querySelector('video');
        }

        function getCurrentTime() {
            try {
                var player = getPlayer();
                if (player && typeof player.getCurrentTime === 'function') {
                    return player.getCurrentTime() || 0;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            return v ? (v.currentTime || 0) : 0;
        }

        function getDuration() {
            try {
                var player = getPlayer();
                if (player && typeof player.getDuration === 'function') {
                    return player.getDuration() || 0;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            return v && !isNaN(v.duration) ? v.duration : 0;
        }

        function seekTo(seconds) {
            try {
                var player = getPlayer();
                if (player && typeof player.seekTo === 'function') {
                    player.seekTo(Math.max(0, seconds), true);
                    return;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            if (v) { v.currentTime = Math.max(0, seconds); }
        }

        function seekBy(deltaSeconds) {
            seekTo(getCurrentTime() + deltaSeconds);
        }

        function formatTime(seconds) {
            seconds = Math.max(0, Math.floor(seconds || 0));
            var h = Math.floor(seconds / 3600);
            var m = Math.floor((seconds % 3600) / 60);
            var s = seconds % 60;
            var mm = (h > 0 && m < 10) ? ('0' + m) : String(m);
            var ss = s < 10 ? ('0' + s) : String(s);
            return h > 0 ? (h + ':' + mm + ':' + ss) : (mm + ':' + ss);
        }

        // Seeks to (approximately) the current position purely to force
        // a fresh frame decode/paint — used after a rapid resize (like
        // exiting DIY fullscreen) where the video can otherwise be left
        // showing a stale/black frame until something nudges it. The
        // half-second rewind is deliberate, not a bug: re-seeking to the
        // *exact* current time is a no-op on some players (nothing to
        // actually redraw), whereas landing a fraction of a second
        // earlier reliably forces a real seek-and-redraw while staying
        // imperceptible.
        function nudgeRepaint() {
            var current = getCurrentTime();
            if (current > 0.5) { seekTo(current - 0.5); }
            try { window.dispatchEvent(new Event('resize')); } catch (e) { /* best-effort; ignore */ }
        }

        function togglePlayPause() {
            try {
                var player = getPlayer();
                if (player && typeof player.getPlayerState === 'function'
                    && typeof player.playVideo === 'function' && typeof player.pauseVideo === 'function') {
                    if (player.getPlayerState() === 1) { player.pauseVideo(); } else { player.playVideo(); }
                    return;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            if (v) { v.paused ? v.play() : v.pause(); }
        }

        function currentPlaybackRate() {
            try {
                var player = getPlayer();
                if (player && typeof player.getPlaybackRate === 'function') {
                    return player.getPlaybackRate() || 1;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            return v ? (v.playbackRate || 1) : 1;
        }

        function cyclePlaybackRate() {
            var current = currentPlaybackRate();
            var next = playbackRates[(playbackRates.indexOf(current) + 1) % playbackRates.length];
            try {
                var player = getPlayer();
                if (player && typeof player.setPlaybackRate === 'function') {
                    player.setPlaybackRate(next);
                    return;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            if (v) { v.playbackRate = next; }
        }

        function isPlaying() {
            try {
                var player = getPlayer();
                if (player && typeof player.getPlayerState === 'function') {
                    return player.getPlayerState() === 1;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            return v ? !v.paused : false;
        }

        function makeButton(className, text, onClick) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'ytrun-btn ' + className;
            button.textContent = text;
            button.addEventListener('click', onClick);
            return button;
        }

        // Builds a seek bar plus a "-10s / play-pause / +10s / speed"
        // row (and, if `options.onExit` is given, a 5th exit button in
        // that same row) — returning the whole thing as one element,
        // plus a `sync()` to call whenever playback state might have
        // changed elsewhere.
        function buildTransportControls(options) {
            options = options || {};
            var wrapper = document.createElement('div');
            wrapper.className = 'ytrun-transport';

            var seekBar = document.createElement('input');
            seekBar.type = 'range';
            seekBar.min = '0';
            seekBar.max = '1000';
            seekBar.value = '0';
            seekBar.className = 'ytrun-seekbar';
            var isDragging = false;
            seekBar.addEventListener('input', function () { isDragging = true; sync(); });
            seekBar.addEventListener('change', function () {
                var duration = getDuration();
                if (duration > 0) {
                    seekTo((Number(seekBar.value) / 1000) * duration);
                }
                isDragging = false;
                sync();
            });
            wrapper.appendChild(seekBar);

            var timeLabel = document.createElement('div');
            timeLabel.className = 'ytrun-time';
            timeLabel.textContent = '0:00 / 0:00';
            wrapper.appendChild(timeLabel);

            var row = document.createElement('div');
            row.className = 'ytrun-controls';

            var back = makeButton('', '-10s', function () { seekBy(-10); sync(); });
            var playPause = makeButton('ytrun-btn-primary', '\\u23F8', function () {
                togglePlayPause();
                setTimeout(sync, 150);
            });
            var forward = makeButton('', '+10s', function () { seekBy(10); sync(); });
            var rate = makeButton('', '1x', function () { cyclePlaybackRate(); sync(); });

            row.appendChild(back);
            row.appendChild(playPause);
            row.appendChild(forward);
            row.appendChild(rate);
            if (typeof options.onExit === 'function') {
                row.appendChild(makeButton('', '\\u2715', options.onExit));
            }
            wrapper.appendChild(row);

            function sync() {
                playPause.textContent = isPlaying() ? '\\u23F8' : '\\u25B6';
                var r = currentPlaybackRate();
                rate.textContent = (r === 1 ? '1x' : r + 'x');
                var duration = getDuration();
                // While actively dragging, show the *dragged-to* time
                // (derived from the seek bar's own live value) rather
                // than the video's still-unmoved current time — the
                // actual seek only happens on 'change', once released.
                var displayedCurrent = isDragging
                    ? (duration > 0 ? (Number(seekBar.value) / 1000) * duration : 0)
                    : getCurrentTime();
                if (!isDragging && duration > 0) {
                    seekBar.value = String(Math.round((displayedCurrent / duration) * 1000));
                }
                timeLabel.textContent = formatTime(displayedCurrent) + ' / ' + (duration > 0 ? formatTime(duration) : '--:--');
            }

            return { row: wrapper, sync: sync };
        }

        window.__ytrunPlayerControls = {
            seekBy: seekBy,
            togglePlayPause: togglePlayPause,
            cyclePlaybackRate: cyclePlaybackRate,
            currentPlaybackRate: currentPlaybackRate,
            isPlaying: isPlaying,
            makeButton: makeButton,
            buildTransportControls: buildTransportControls,
            nudgeRepaint: nudgeRepaint
        };
    })();
    """

    // Best-effort "Listen Mode": forces the player down to its lowest
    // video quality (audio is unaffected — only the video track's bitrate
    // drops) via the same `#movie_player` element API YouTube's own
    // quality-settings UI calls, and blacks out the video behind a fixed,
    // full-viewport cover carrying its own play/pause, ±10s seek, and
    // speed-cycling controls — driven through the same `#movie_player`
    // API rather than blind taps on YouTube's own (now hidden) controls.
    // The cover itself is `pointer-events: none` so any tap NOT on one of
    // those buttons still passes through to whatever's underneath; only
    // the control row explicitly re-enables pointer events for itself.
    //
    // Only shown on an actual `/watch` page (see `isWatchPage`) — the
    // home feed, search, etc. keep their normal thumbnails/cards, since
    // there's no real video playing there to hide in the first place.
    //
    // Deliberately covers the whole viewport (`position: fixed` on
    // `<html>`, not just the player element) rather than trying to find
    // and cover just the player container — YouTube's player DOM
    // structure varies and a container-scoped overlay is one wrong
    // selector away from silently covering nothing. A page-wide fixed
    // cover can't fail to hide the video regardless of where/how it's
    // laid out underneath.
    //
    // `setPlaybackQuality`/`setPlaybackQualityRange` are undocumented for
    // the mobile web player specifically (they're the same API the
    // iframe Player API exposes for embeds) — this hasn't been verified
    // against a live m.youtube.com session, so treat it as experimental
    // until confirmed on-device. If the API isn't there, this silently
    // no-ops and you still get the black-out (no video shown) but not the
    // bandwidth savings from a forced lower resolution.
    //
    // Re-asserts the quality every few seconds rather than only once,
    // since YouTube's own "next video" autoplay swaps content without a
    // full page load — which would otherwise silently let quality creep
    // back up. The cover itself doesn't need re-asserting: it's attached
    // to <html>, which YouTube's own SPA navigation never tears down.
    private static let listenModeJS = """
    (function () {
        var overlayId = '__ytrunListenOverlay';
        var styleId = '__ytrunListenStyle';
        var enabled = false;
        var controls = null;

        function getPlayer() {
            return document.getElementById('movie_player');
        }

        function forceLowestQuality() {
            try {
                var player = getPlayer();
                if (!player) { return; }
                if (typeof player.setPlaybackQualityRange === 'function') {
                    player.setPlaybackQualityRange('tiny', 'tiny');
                }
                if (typeof player.setPlaybackQuality === 'function') {
                    player.setPlaybackQuality('tiny');
                }
            } catch (e) { /* best-effort; ignore */ }
        }

        function ensureOverlay() {
            try {
                if (document.getElementById(styleId)) { return; }
                var style = document.createElement('style');
                style.id = styleId;
                style.textContent =
                    '#' + overlayId + '{position:fixed;top:0;left:0;right:0;bottom:0;' +
                    'z-index:2147483647;background:#000;color:#fff;display:none;' +
                    'flex-direction:column;align-items:center;justify-content:center;' +
                    'font-family:-apple-system,sans-serif;pointer-events:none;' +
                    'text-align:center;padding:16px;box-sizing:border-box;}' +
                    '#' + overlayId + '.ytrun-on{display:flex;}' +
                    '#' + overlayId + ' .ytrun-icon{font-size:40px;margin-bottom:8px;}' +
                    '#' + overlayId + ' .ytrun-label{font-size:14px;opacity:0.8;margin-bottom:24px;}';
                (document.head || document.documentElement).appendChild(style);

                // Built with createElement/textContent rather than
                // `.innerHTML` — YouTube enforces a Trusted Types CSP that
                // throws on any plain-string `.innerHTML` assignment,
                // which was silently aborting this function before the
                // overlay ever got attached (`.textContent` isn't a
                // Trusted-Types-guarded sink, so it's unaffected).
                var overlay = document.createElement('div');
                overlay.id = overlayId;

                var icon = document.createElement('div');
                icon.className = 'ytrun-icon';
                icon.textContent = '\\uD83C\\uDFA7';
                overlay.appendChild(icon);

                var label = document.createElement('div');
                label.className = 'ytrun-label';
                label.textContent = 'Listen Mode \\u2014 video hidden to save data';
                overlay.appendChild(label);

                controls = window.__ytrunPlayerControls.buildTransportControls();
                overlay.appendChild(controls.row);

                (document.body || document.documentElement).appendChild(overlay);
                window.__ytrunListenOverlayError = null;
            } catch (e) {
                window.__ytrunListenOverlayError = String(e);
            }
        }

        // Only black out an actual video/watch page — leaving the home
        // feed, search, etc. showing their normal thumbnails/cards. Only
        // watch pages ever have a real video playing to hide in the
        // first place.
        function isWatchPage() {
            return location.pathname.indexOf('/watch') === 0;
        }

        function updateOverlayVisibility() {
            var overlay = document.getElementById(overlayId);
            if (overlay) { overlay.classList.toggle('ytrun-on', enabled && isWatchPage()); }
        }

        window.__ytrunSetListenMode = function (isEnabled) {
            enabled = !!isEnabled;
            window.__ytrunListenModeDebugState = enabled;
            ensureOverlay();
            updateOverlayVisibility();
            if (enabled) {
                forceLowestQuality();
                if (controls) { controls.sync(); }
            }
        };

        // React promptly to Shorts-swipe-style in-page navigation (which
        // doesn't reload the document) between the feed and a video, in
        // addition to the periodic re-check below.
        var originalPushState = history.pushState;
        history.pushState = function () {
            originalPushState.apply(this, arguments);
            updateOverlayVisibility();
        };
        window.addEventListener('popstate', updateOverlayVisibility);

        setInterval(function () {
            if (enabled) {
                forceLowestQuality();
                updateOverlayVisibility();
            }
        }, 3000);

        // Snappier, separate interval just for keeping the play/pause
        // icon and speed label in sync with reality (e.g. the video
        // pausing itself at the end, or YouTube's own autoplay starting
        // the next one) — cheap enough to run more often than the
        // quality/visibility checks above.
        setInterval(function () {
            if (enabled && isWatchPage() && controls) { controls.sync(); }
        }, 500);
    })();
    """

    // Redirects YouTube's fullscreen button away from iOS's native
    // per-<video> fullscreen, which hands the video off to a separate
    // system-level presentation that leaves the caption overlay behind
    // (YouTube renders captions as sibling HTML next to the <video> tag,
    // not a native text track — nothing outside the page's own rendering
    // can appear on that native surface).
    //
    // On-device debug data showed this WKWebView exposes *no* working
    // Fullscreen API at all — `requestFullscreen`,
    // `webkitRequestFullscreen`, and `webkitRequestFullScreen` were all
    // absent from `Element.prototype`, and `document.fullscreenEnabled`/
    // `document.webkitFullscreenEnabled` were both `false` — despite
    // `configuration.preferences.isElementFullscreenEnabled = true` being
    // set (see `init` below). So real container fullscreen isn't
    // achievable here either. Instead of falling back to native
    // (captionless) fullscreen, this does fullscreen ourselves: expand
    // the player container to fill the viewport via CSS, which keeps
    // the caption overlay (still just a normal sibling element inside
    // that container) on screen the whole time, since nothing ever
    // leaves the page's own DOM/rendering. Real fullscreen APIs are
    // still tried first, in case some other device/OS combination
    // actually has one — genuine system fullscreen (rotation, real
    // system chrome) is strictly better when available.
    //
    // Since we can't reliably read YouTube's own internal fullscreen
    // state, repeated `webkitEnterFullscreen()` calls are treated as a
    // toggle (enter if inactive, exit if active) — this lets YouTube's
    // own fullscreen icon act as a second way to exit, alongside the
    // explicit "✕" button and transport controls this adds. Records
    // every attempt into `window.__ytrunLastFullscreenAttempt`, readable
    // via the Debug Info menu item.
    //
    // The exit button and seek bar/play/pause/±10s/speed controls are
    // built as their own overlay attached directly to <body> —
    // deliberately NOT nested inside the (now full-viewport) player
    // container. YouTube's own control bar apparently doesn't relayout
    // correctly once its container is force-resized this way (it
    // visibly broke on-device: no working play/pause/seek), and worse,
    // an earlier version that appended the exit button *inside* the
    // container ended up directly underneath YouTube's own top-right
    // "more options" button, which silently ate every tap instead. An
    // independent, later-in-DOM, higher-z-index overlay can't be
    // covered by anything YouTube's own player internals do to their
    // own container. The exit button lives in the same row as the other
    // transport controls (via `buildTransportControls({ onExit })`)
    // rather than floating separately.
    //
    // Controls auto-hide after a few seconds and toggle on tap,
    // mirroring YouTube's own on-screen-controls behavior — otherwise
    // they'd permanently sit over the video. The tap listener is on the
    // player container itself (not our pointer-events:none overlay,
    // which can't receive taps on its empty space by design — that's
    // what lets taps reach the video underneath at all).
    private static let forceElementFullscreenJS = """
    (function () {
        var fakeFullscreenClass = '__ytrunFakeFullscreen';
        var overlayId = '__ytrunFullscreenControls';
        var catcherId = '__ytrunFullscreenTapCatcher';
        var styleId = '__ytrunFullscreenStyle';
        var fakeFullscreenActive = false;
        var controlsVisible = false;
        var hideTimer = null;
        var controls = null;

        function ensureStyle() {
            if (document.getElementById(styleId)) { return; }
            var style = document.createElement('style');
            style.id = styleId;
            // `!important` on the fullscreen class: YouTube sets explicit
            // inline width/height on this container for its normal
            // responsive sizing, which would otherwise win over a plain
            // class.
            style.textContent =
                '.' + fakeFullscreenClass + '{position:fixed !important;top:0 !important;left:0 !important;' +
                'right:0 !important;bottom:0 !important;width:100vw !important;height:100vh !important;' +
                'z-index:2147483000 !important;background:#000 !important;}' +
                // Sits strictly between the fullscreen container
                // (2147483000) and the visible controls (2147483647) —
                // above the video so it actually receives every tap/
                // swipe itself, below the controls so a real button
                // press still wins the hit-test at that exact spot.
                '#' + catcherId + '{position:fixed;inset:0;z-index:2147483400;display:none;' +
                'background:transparent;}' +
                '#' + catcherId + '.ytrun-on{display:block;}' +
                '#' + overlayId + '{position:fixed;inset:0;z-index:2147483647;pointer-events:none;' +
                'display:none;flex-direction:column;justify-content:flex-end;align-items:center;' +
                'padding-bottom:28px;box-sizing:border-box;background:linear-gradient(transparent 60%, rgba(0,0,0,0.5));}' +
                '#' + overlayId + '.ytrun-on{display:flex;}';
            (document.head || document.documentElement).appendChild(style);
        }

        function findContainer() {
            return document.getElementById('movie_player')
                || document.querySelector('.html5-video-player');
        }

        function ensureOverlay() {
            if (document.getElementById(overlayId)) { return; }
            var overlay = document.createElement('div');
            overlay.id = overlayId;
            controls = window.__ytrunPlayerControls.buildTransportControls({ onExit: exitFakeFullscreen });
            overlay.appendChild(controls.row);
            (document.body || document.documentElement).appendChild(overlay);
        }

        function showControls() {
            var overlay = document.getElementById(overlayId);
            if (overlay) { overlay.classList.add('ytrun-on'); }
            if (controls) { controls.sync(); }
            controlsVisible = true;
            clearTimeout(hideTimer);
            hideTimer = setTimeout(function () {
                if (fakeFullscreenActive) { hideControls(); }
            }, 3000);
        }

        function hideControls() {
            var overlay = document.getElementById(overlayId);
            if (overlay) { overlay.classList.remove('ytrun-on'); }
            controlsVisible = false;
            clearTimeout(hideTimer);
        }

        // A dedicated, always-on-top (but below the visible controls)
        // transparent layer that owns tap/swipe handling itself, rather
        // than trying to listen on YouTube's own player container.
        // Attaching to the container was unreliable in practice — its
        // own internal touch/video handling apparently intercepts things
        // before a listener there ever sees them (even in the capture
        // phase, which suggested something upstream of it, e.g. a
        // capture-phase listener on `document` itself, was stopping
        // propagation earlier still). A layer we own outright sidesteps
        // needing to know or fight anything about how YouTube's own
        // event handling works: nothing else is attached to it, so
        // nothing else can interfere with it.
        //
        // Tap toggles the controls exactly like YouTube's own player
        // (tap to reveal, tap again or wait 3s to hide). A vertical
        // swipe-down exits fullscreen outright, mirroring the standard
        // "drag down to dismiss" gesture on iOS's native fullscreen
        // video player. A touch that landed on one of the actual visible
        // control buttons never reaches this layer at all — it sits
        // above this catcher in z-index, so it wins the hit-test there.
        function ensureTapCatcher() {
            if (document.getElementById(catcherId)) { return; }
            var catcher = document.createElement('div');
            catcher.id = catcherId;

            catcher.addEventListener('click', function () {
                if (controlsVisible) { hideControls(); } else { showControls(); }
            });

            var touchStartX = null;
            var touchStartY = null;
            catcher.addEventListener('touchstart', function (event) {
                if (!event.touches || event.touches.length !== 1) { return; }
                touchStartX = event.touches[0].clientX;
                touchStartY = event.touches[0].clientY;
            });
            catcher.addEventListener('touchend', function (event) {
                if (touchStartY === null) { return; }
                var touch = event.changedTouches && event.changedTouches[0];
                var deltaY = touch ? touch.clientY - touchStartY : 0;
                var deltaX = touch ? Math.abs(touch.clientX - touchStartX) : 0;
                touchStartX = null;
                touchStartY = null;
                // Mostly-vertical, clearly-downward drag — a small
                // threshold would misfire on ordinary taps/scrubs.
                if (deltaY > 80 && deltaX < 60) {
                    exitFakeFullscreen();
                }
            });

            (document.body || document.documentElement).appendChild(catcher);
        }

        function notifySwift(active) {
            try {
                window.webkit.messageHandlers.customFullscreen.postMessage({ active: active });
            } catch (e) { /* best-effort; ignore */ }
        }

        function enterFakeFullscreen() {
            ensureStyle();
            var container = findContainer();
            if (!container) { return false; }
            ensureOverlay();
            ensureTapCatcher();
            document.getElementById(catcherId).classList.add('ytrun-on');
            container.classList.add(fakeFullscreenClass);
            fakeFullscreenActive = true;
            showControls();
            notifySwift(true);
            return true;
        }

        function exitFakeFullscreen() {
            var container = document.querySelector('.' + fakeFullscreenClass);
            if (container) { container.classList.remove(fakeFullscreenClass); }
            var catcher = document.getElementById(catcherId);
            if (catcher) { catcher.classList.remove('ytrun-on'); }
            hideControls();
            fakeFullscreenActive = false;
            notifySwift(false);
            // The rapid resize (our CSS class change plus the app's own
            // nav bar/status bar reappearing) can otherwise leave the
            // video showing a stale/black frame in the now-small player
            // until something else nudges it — see `nudgeRepaint`.
            // Delayed to let that native layout change settle first.
            setTimeout(function () {
                window.__ytrunPlayerControls.nudgeRepaint();
            }, 400);
        }

        // Exposed so Swift can force an exit (e.g. leaving the YouTube
        // screen entirely while this was active) and keep its own
        // `isCustomFullscreen` flag consistent with reality.
        window.__ytrunExitFakeFullscreen = exitFakeFullscreen;

        // Auto-exits if the page ever navigates away from the actual
        // watch page while fake fullscreen is active — e.g. tapping
        // YouTube's own in-page back button. That's an SPA-style
        // (pushState) transition, not a real page load, so
        // `didFinish`'s reset on the Swift side never fires for it; left
        // unhandled, the app's nav bar/status bar/status row stayed
        // hidden indefinitely with no way back short of forcing an
        // actual page reload some other way.
        function exitIfLeftWatchPage() {
            if (fakeFullscreenActive && location.pathname.indexOf('/watch') !== 0) {
                exitFakeFullscreen();
            }
        }
        var originalPushState = history.pushState;
        history.pushState = function () {
            originalPushState.apply(this, arguments);
            exitIfLeftWatchPage();
        };
        window.addEventListener('popstate', exitIfLeftWatchPage);

        // Keeps the play/pause icon, speed label, and seek bar right
        // while controls are visible — same rationale as Listen Mode's
        // identical interval. Also a periodic safety net for the above,
        // in case some navigation path skips both pushState and popstate.
        setInterval(function () {
            if (fakeFullscreenActive && controlsVisible && controls) { controls.sync(); }
            exitIfLeftWatchPage();
        }, 500);

        function requestFullscreenOn(element) {
            if (!element) { return { ok: false, reason: 'no element' }; }
            if (typeof element.requestFullscreen === 'function') {
                element.requestFullscreen();
                return { ok: true, api: 'requestFullscreen' };
            }
            if (typeof element.webkitRequestFullscreen === 'function') {
                element.webkitRequestFullscreen();
                return { ok: true, api: 'webkitRequestFullscreen' };
            }
            if (typeof element.webkitRequestFullScreen === 'function') {
                element.webkitRequestFullScreen();
                return { ok: true, api: 'webkitRequestFullScreen' };
            }
            return { ok: false, reason: 'no fullscreen method on element' };
        }

        try {
            HTMLVideoElement.prototype.webkitEnterFullscreen = function () {
                if (fakeFullscreenActive) {
                    exitFakeFullscreen();
                    window.__ytrunLastFullscreenAttempt = { via: 'webkitEnterFullscreen', action: 'exit fake fullscreen' };
                    return;
                }
                var container = document.getElementById('movie_player')
                    || this.closest('.html5-video-player')
                    || this.parentElement;
                var outcome = requestFullscreenOn(container);
                if (outcome.ok) {
                    window.__ytrunLastFullscreenAttempt = {
                        via: 'webkitEnterFullscreen',
                        containerFound: !!container,
                        result: outcome
                    };
                    return;
                }
                var enteredFake = enterFakeFullscreen();
                window.__ytrunLastFullscreenAttempt = {
                    via: 'webkitEnterFullscreen',
                    containerFound: !!container,
                    result: outcome,
                    fallback: enteredFake ? 'fake fullscreen' : 'fake fullscreen failed (no container)'
                };
            };
            HTMLVideoElement.prototype.webkitEnterFullScreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
        } catch (e) { /* best-effort; ignore */ }

        // Also wrap whichever real fullscreen entry points actually
        // exist, purely for diagnostics — even if YouTube calls one of
        // these directly instead of going through `webkitEnterFullscreen()`.
        ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
            try {
                var original = Element.prototype[name];
                if (typeof original !== 'function') { return; }
                Element.prototype[name] = function () {
                    window.__ytrunLastFullscreenAttempt = { via: name, tag: this.tagName, id: this.id || null };
                    return original.apply(this, arguments);
                };
            } catch (e) { /* best-effort; ignore */ }
        });
    })();
    """

    // Powers the Download feature (see `DownloadManager`). Finds the best
    // available media stream URL(s) by parsing `ytInitialPlayerResponse`
    // (YouTube's own embedded player metadata) for `streamingData.formats`
    // (progressive, combined audio+video — used for full video downloads,
    // since muxing separate streams ourselves is out of scope) and
    // `streamingData.adaptiveFormats` (separate audio-only streams,
    // higher quality — used for audio downloads). Only usable when a
    // format has a plain `url` field rather than only a
    // `signatureCipher` — deciphering that (what yt-dlp does) is a
    // large, constantly-shifting undertaking that's deliberately not
    // implemented here, so ciphered-only videos just won't have a
    // download available; `DownloadManager` reports that plainly rather
    // than producing a broken file.
    //
    // An earlier version also sniffed `googlevideo.com/videoplayback`
    // URLs the real player itself had already requested, as an
    // audio-only fallback for ciphered videos. Removed: adaptive
    // streaming fetches media in many small chunks (each its own
    // `videoplayback` request, often just an initialization segment or
    // a partial byte range), so "the most recent URL seen" was often
    // only a fragment of the track rather than the complete resource —
    // downloading it produced a file that looked successful but was
    // truncated or empty. Only URLs known by construction to represent
    // the *complete* track (the unciphered `formats`/`adaptiveFormats`
    // entries above) are used now.
    //
    // Title comes from `document.title` (stripping the trailing
    // "- YouTube" suffix) rather than any internal DOM selector — a
    // plain browser API that won't break when YouTube reskins its
    // markup, unlike the channel-name scraping in `pageInfoJS` below.
    private static let downloadInfoJS = """
    (function () {
        function parsePlayerResponse() {
            if (window.ytInitialPlayerResponse) { return window.ytInitialPlayerResponse; }
            var scripts = document.getElementsByTagName('script');
            for (var i = 0; i < scripts.length; i++) {
                var text = scripts[i].textContent;
                if (!text || text.indexOf('ytInitialPlayerResponse') === -1) { continue; }
                var match = /ytInitialPlayerResponse\\s*=\\s*(\\{.*?\\});/.exec(text);
                if (match) {
                    try { return JSON.parse(match[1]); } catch (e) { /* fall through */ }
                }
            }
            return null;
        }

        function bestUncipheredURL(list, wantAudio) {
            if (!Array.isArray(list)) { return null; }
            var best = null;
            for (var i = 0; i < list.length; i++) {
                var format = list[i];
                if (!format || !format.url) { continue; }
                var mimeType = format.mimeType || '';
                var isAudio = mimeType.indexOf('audio/') === 0;
                var isVideo = mimeType.indexOf('video/') === 0;
                if (wantAudio ? !isAudio : !isVideo) { continue; }
                if (!best || (format.bitrate || 0) > (best.bitrate || 0)) {
                    best = format;
                }
            }
            return best ? best.url : null;
        }

        window.__ytrunGetDownloadInfo = function () {
            var title = document.title.replace(/\\s*-\\s*YouTube\\s*$/, '').trim();
            if (!title) { title = 'Video'; }

            var playerResponse = parsePlayerResponse();
            var streamingData = playerResponse && playerResponse.streamingData;

            var videoURL = bestUncipheredURL(streamingData && streamingData.formats, false);
            var audioURL = bestUncipheredURL(streamingData && streamingData.adaptiveFormats, true);

            return {
                title: title,
                userAgent: navigator.userAgent,
                videoURL: videoURL || null,
                audioURL: audioURL || null
            };
        };
    })();
    """

    private static let bridgeJS = """
    (function () {
        function attach(video) {
            if (video.__ytrunAttached) { return; }
            video.__ytrunAttached = true;
            video.addEventListener('play', function () {
                window.webkit.messageHandlers.playback.postMessage('play');
            });
            video.addEventListener('pause', function () {
                window.webkit.messageHandlers.playback.postMessage('pause');
            });
        }

        var observer = new MutationObserver(function () {
            var video = document.querySelector('video');
            if (video) { attach(video); }
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });

        var existing = document.querySelector('video');
        if (existing) { attach(existing); }

        window.__ytrunPlay = function () {
            var v = document.querySelector('video');
            if (v) { v.play(); }
        };
        window.__ytrunPause = function () {
            var v = document.querySelector('video');
            if (v) { v.pause(); }
        };
        window.__ytrunToggle = function () {
            var v = document.querySelector('video');
            if (v) { v.paused ? v.play() : v.pause(); }
        };
    })();
    """

    // Channel name extraction, in priority order:
    // 1. YouTube's schema.org SEO microdata — `<link itemprop="name"
    //    content="...">` nested in `[itemprop="author"]`. This is
    //    confirmed present in YouTube's actual server-rendered HTML (not
    //    a guess), and reliable since it's SEO-facing markup YouTube has
    //    little reason to change. Note it's a `<link>` tag: the name is
    //    in its `content` *attribute*, not as visible text — a `<link>`
    //    has no textContent at all.
    // 2. A handful of guessed visible-DOM selectors as a fallback (e.g.
    //    for Shorts, which may not carry the same microdata). These are
    //    genuinely best-effort and may need updating if YouTube changes
    //    its layout.
    // A miss just reports `channel: null`, it doesn't break anything else.
    private static let pageInfoJS = """
    (function () {
        var channelSelectors = [
            'ytm-slim-owner-renderer .yt-core-attributed-string',
            'ytm-video-owner-renderer .yt-core-attributed-string',
            '.slim-owner-icon-and-title .yt-core-attributed-string',
            'ytd-channel-name#channel-name a'
        ];

        function extractChannel() {
            var authorName = document.querySelector('[itemprop="author"] [itemprop="name"]');
            if (authorName) {
                var content = authorName.getAttribute('content');
                if (content && content.trim().length > 0) {
                    return content.trim();
                }
            }

            for (var i = 0; i < channelSelectors.length; i++) {
                var el = document.querySelector(channelSelectors[i]);
                if (el && el.textContent && el.textContent.trim().length > 0) {
                    return el.textContent.trim();
                }
            }
            return null;
        }

        // Best-effort grab of the HTML around where the channel name
        // should be, captured only on a scrape miss — sent back to Swift
        // so a real-world failure case can be inspected remotely (see
        // `ChannelScrapeDebugLog`) instead of only being guessed at.
        function captureDebugHTML() {
            var container = document.querySelector('ytd-watch-metadata')
                || document.querySelector('ytm-slim-video-metadata-renderer')
                || document.querySelector('#meta-contents')
                || document.querySelector('ytd-reel-player-header-renderer')
                || document.body;
            return container ? container.outerHTML.substring(0, 4000) : null;
        }

        var lastURL = null;
        var lastChannel = null;

        function check() {
            var url = window.location.href;
            var channel = extractChannel();
            if (url !== lastURL || channel !== lastChannel) {
                lastURL = url;
                lastChannel = channel;
                var debugHTML = channel ? null : captureDebugHTML();
                window.webkit.messageHandlers.pageInfo.postMessage({ url: url, channel: channel, debugHTML: debugHTML });
            }
        }

        // Shorts swipes update the URL via the History API rather than a
        // normal page load, so patch pushState to notice those too.
        var originalPushState = history.pushState;
        history.pushState = function () {
            originalPushState.apply(this, arguments);
            check();
        };
        window.addEventListener('popstate', check);

        // The channel element often renders a moment after the URL
        // changes, so also poll periodically to catch it.
        setInterval(check, 1500);
        check();
    })();
    """
}

extension YouTubeWebViewStore: WKNavigationDelegate {
    // Blocks actual page-load navigations into Shorts before they ever
    // render — the clean, no-flash path. Doesn't catch in-page
    // (pushState) navigation into Shorts, like swiping the Shorts feed;
    // that's handled reactively in `didReceive` above instead, since
    // pushState never triggers this delegate method at all.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if isShortsRestricted(), Self.isShortsURL(navigationAction.request.url) {
            decisionHandler(.cancel)
            redirectAwayFromShorts()
            return
        }
        decisionHandler(.allow)
    }

    // A full page load re-parses the DOM from scratch, so any previously
    // injected hide-Shorts <style> is gone with it — reapply based on the
    // current setting once the new page has loaded.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyShortsHiding()
        applyListenMode()
        // A fresh page load always resets `forceElementFullscreenJS`'s
        // own `fakeFullscreenActive` back to false (new JS module
        // instance) — mirror that here so a real navigation while in
        // fake fullscreen can't leave the nav bar permanently hidden.
        isCustomFullscreen = false
    }
}

extension YouTubeWebViewStore: WKScriptMessageHandler {
    // Called for both `playback` and `pageInfo` messages — one delegate
    // method handles every registered handler name, so we branch on
    // `message.name` first.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "playback":
            guard let event = message.body as? String else { return }
            switch event {
            case "play":
                isPlaying = true
                updateNowPlayingInfo(isPlaying: true)
            case "pause":
                isPlaying = false
                updateNowPlayingInfo(isPlaying: false)
            default:
                break
            }

        case "pageInfo":
            guard let dict = message.body as? [String: Any] else { return }
            let url = (dict["url"] as? String).flatMap(URL.init(string:))
            currentURL = url
            currentChannelName = dict["channel"] as? String

            if currentChannelName == nil,
               let urlString = dict["url"] as? String,
               let debugHTML = dict["debugHTML"] as? String {
                ChannelScrapeDebugLog.record(url: urlString, html: debugHTML)
            }

            // Catches Shorts entered via in-page (pushState) navigation —
            // e.g. swiping into the Shorts feed — which `decidePolicyFor`
            // below can't see since no real page load happens for those.
            // There's an inherent brief flash here since the page has
            // already rendered by the time this message arrives; the
            // `decidePolicyFor` check handles the zero-flash case for
            // actual page-load navigations into Shorts.
            if Self.isShortsURL(url), isShortsRestricted() {
                redirectAwayFromShorts()
            }

        case "customFullscreen":
            guard let dict = message.body as? [String: Any] else { return }
            isCustomFullscreen = dict["active"] as? Bool ?? false

        default:
            break
        }
    }
}
