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
