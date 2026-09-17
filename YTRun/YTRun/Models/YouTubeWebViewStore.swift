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
        // fullscreen player, and don't require a user tap before JS can
        // start playback — needed so our lock-screen play button can
        // resume the video programmatically.
        configuration.allowsInlineMediaPlayback = true
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
        var controlRefs = null;
        var playbackRates = [1, 1.25, 1.5, 1.75, 2];

        // Routed through YouTube's own `#movie_player` API (the same
        // object `forceLowestQuality` already uses) rather than poking
        // the raw <video> element directly — seeking in particular needs
        // to go through the player's own logic to fetch whatever new
        // buffered range the seek lands in, which YouTube's JS handles
        // and a bare `video.currentTime = x` assignment does not always.
        // Each falls back to the raw <video> element if the player API
        // method isn't there.
        function getPlayer() {
            return document.getElementById('movie_player');
        }

        function findVideo() {
            return document.querySelector('video');
        }

        function seekBy(deltaSeconds) {
            try {
                var player = getPlayer();
                if (player && typeof player.getCurrentTime === 'function' && typeof player.seekTo === 'function') {
                    player.seekTo(Math.max(0, player.getCurrentTime() + deltaSeconds), true);
                    return;
                }
            } catch (e) { /* fall through to raw video */ }
            var v = findVideo();
            if (v) { v.currentTime = Math.max(0, v.currentTime + deltaSeconds); }
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

        function syncControls() {
            if (!controlRefs) { return; }
            controlRefs.playPause.textContent = isPlaying() ? '\\u23F8' : '\\u25B6';
            var rate = currentPlaybackRate();
            controlRefs.rate.textContent = (rate === 1 ? '1x' : rate + 'x');
        }

        function makeButton(className, text, onClick) {
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'ytrun-btn ' + className;
            button.textContent = text;
            button.addEventListener('click', onClick);
            return button;
        }

        function buildControls(overlay) {
            var controls = document.createElement('div');
            controls.className = 'ytrun-controls';

            var back = makeButton('', '-10s', function () { seekBy(-10); syncControls(); });
            var playPause = makeButton('ytrun-btn-primary', '\\u23F8', function () {
                togglePlayPause();
                setTimeout(syncControls, 150);
            });
            var forward = makeButton('', '+10s', function () { seekBy(10); syncControls(); });
            var rate = makeButton('', '1x', function () { cyclePlaybackRate(); syncControls(); });

            controls.appendChild(back);
            controls.appendChild(playPause);
            controls.appendChild(forward);
            controls.appendChild(rate);
            overlay.appendChild(controls);

            controlRefs = { playPause: playPause, rate: rate };
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
                    '#' + overlayId + ' .ytrun-label{font-size:14px;opacity:0.8;margin-bottom:24px;}' +
                    // Re-enables taps just for the control row — the
                    // overlay itself stays `pointer-events: none` so it
                    // never blocks anything when you're not touching a
                    // button, but this child explicitly opts back in.
                    '#' + overlayId + ' .ytrun-controls{display:flex;align-items:center;gap:14px;pointer-events:auto;}' +
                    '#' + overlayId + ' .ytrun-btn{background:rgba(255,255,255,0.16);color:#fff;border:none;' +
                    'border-radius:10px;padding:10px 14px;font-size:15px;min-width:44px;min-height:44px;}' +
                    '#' + overlayId + ' .ytrun-btn-primary{font-size:22px;padding:10px 20px;}';
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

                buildControls(overlay);

                (document.body || document.documentElement).appendChild(overlay);
                window.__ytrunListenOverlayError = null;
            } catch (e) {
                window.__ytrunListenOverlayError = String(e);
            }
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
                syncControls();
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
            if (enabled && isWatchPage()) { syncControls(); }
        }, 500);
    })();
    """

    // Attempts to redirect YouTube's fullscreen button from iOS's native
    // per-<video> fullscreen to the DOM Fullscreen API on the player
    // *container* instead, which would keep the caption overlay on
    // screen (YouTube renders captions as sibling HTML, not a native
    // <video> text track — iOS's native video fullscreen takes just the
    // <video> element to a separate system presentation and leaves that
    // overlay behind).
    //
    // On-device debug data showed this device's WKWebView exposes *no*
    // working fullscreen method at all — `requestFullscreen`,
    // `webkitRequestFullscreen`, and `webkitRequestFullScreen` were all
    // absent from `Element.prototype`, and `document.fullscreenEnabled`/
    // `document.webkitFullscreenEnabled` were both `false` — despite
    // `configuration.preferences.isElementFullscreenEnabled = true` being
    // set (see `init` below). So container fullscreen is not actually
    // achievable here; captions will not survive fullscreen on this
    // device. Falls back to calling the *original*, unmodified
    // `webkitEnterFullscreen()` in that case, so fullscreen itself still
    // works (without captions) rather than silently doing nothing — an
    // earlier version of this redirect had no such fallback and broke
    // fullscreen entirely by replacing the only working implementation
    // with a call to a method that doesn't exist on this device.
    //
    // Left in place (rather than removed) since a device/OS combination
    // where the Fullscreen API *is* available would still benefit from
    // the redirect, keeping captions visible there.
    //
    // Records every attempt into `window.__ytrunLastFullscreenAttempt`,
    // readable via the Debug Info menu item.
    private static let forceElementFullscreenJS = """
    (function () {
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
            var originalEnterFullscreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
            HTMLVideoElement.prototype.webkitEnterFullscreen = function () {
                var container = document.getElementById('movie_player')
                    || this.closest('.html5-video-player')
                    || this.parentElement;
                var outcome = requestFullscreenOn(container);
                window.__ytrunLastFullscreenAttempt = {
                    via: 'webkitEnterFullscreen',
                    containerFound: !!container,
                    result: outcome
                };
                if (!outcome.ok && typeof originalEnterFullscreen === 'function') {
                    window.__ytrunLastFullscreenAttempt.fallback = 'native webkitEnterFullscreen';
                    return originalEnterFullscreen.apply(this, arguments);
                }
            };
            HTMLVideoElement.prototype.webkitEnterFullScreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
        } catch (e) { /* best-effort; ignore */ }

        // Also wrap whichever fullscreen entry points actually exist,
        // purely for diagnostics — even if YouTube calls one of these
        // directly instead of going through `webkitEnterFullscreen()`.
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
    // available media stream URL(s) for the current video two ways:
    //
    // 1. Parses `ytInitialPlayerResponse` (YouTube's own embedded player
    //    metadata) for `streamingData.formats` (progressive, combined
    //    audio+video — used for full video downloads, since muxing
    //    separate streams ourselves is out of scope) and
    //    `streamingData.adaptiveFormats` (separate audio-only streams,
    //    higher quality — used for audio downloads). Only usable when a
    //    format has a plain `url` field rather than only a
    //    `signatureCipher` — deciphering that (what yt-dlp does) is a
    //    large, constantly-shifting undertaking that's deliberately not
    //    implemented here, so ciphered-only videos just won't have a
    //    download available.
    // 2. As an audio-only fallback, a `fetch`/`XMLHttpRequest` monkey-patch
    //    (installed at document-start, before YouTube's own scripts run)
    //    records the most recent `googlevideo.com/videoplayback` URL the
    //    *real* player itself already successfully requested, read off
    //    the request URL's own `mime` parameter. Since the player
    //    resolved and used that URL to actually play the audio, this
    //    works even when signature deciphering would otherwise be
    //    required — no cipher-solving needed, we're just reusing a URL
    //    the page already proved works. Only ever used for audio: video
    //    is captured as a separate elementary stream this way too, but
    //    with no muxer there's nothing useful to do with it alone.
    //
    // Title comes from `document.title` (stripping the trailing
    // "- YouTube" suffix) rather than any internal DOM selector — a
    // plain browser API that won't break when YouTube reskins its
    // markup, unlike the channel-name scraping in `pageInfoJS` below.
    private static let downloadInfoJS = """
    (function () {
        var sniffedAudioURL = null;

        function noteRequestedURL(urlString) {
            try {
                if (typeof urlString !== 'string' || urlString.indexOf('googlevideo.com/videoplayback') === -1) {
                    return;
                }
                var match = /[?&]mime=([^&]+)/.exec(urlString);
                if (!match) { return; }
                var mime = decodeURIComponent(match[1]);
                if (mime.indexOf('audio/') === 0) {
                    sniffedAudioURL = urlString;
                }
            } catch (e) { /* best-effort; ignore */ }
        }

        var originalFetch = window.fetch;
        if (originalFetch) {
            window.fetch = function (input) {
                try {
                    noteRequestedURL(typeof input === 'string' ? input : (input && input.url));
                } catch (e) { /* best-effort; ignore */ }
                return originalFetch.apply(this, arguments);
            };
        }

        var originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
            noteRequestedURL(url);
            return originalOpen.apply(this, arguments);
        };

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
            var audioURL = bestUncipheredURL(streamingData && streamingData.adaptiveFormats, true)
                || sniffedAudioURL;

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

        default:
            break
        }
    }
}
