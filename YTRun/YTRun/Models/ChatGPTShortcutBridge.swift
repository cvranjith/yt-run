//
//  ChatGPTShortcutBridge.swift
//  YTRun
//

import Foundation
import Combine
import UIKit

// A second, independent path to a summary that does NOT go through
// ai-gateway/AIGatewayClient at all — instead of a server call, it
// hands a fully-formed prompt+transcript to the user's own ChatGPT
// iPhone app via a Shortcut (see chatgpt-shortcut-setup.md for the
// exact Shortcut to build), using the clipboard as the payload channel
// and iOS's x-callback-url support in the Shortcuts app to return
// control here automatically. Confirmed working on-device — see
// requirement-ai-chatgpt.md for the original design.
//
// The Shortcut itself is deliberately generic/dumb (Get Clipboard ->
// Ask ChatGPT [Message = Clipboard] -> Copy to Clipboard) — the actual
// prompt lives in `buildPayload` below, not hardcoded in the Shortcut,
// so it can change without the user having to edit anything on-device.
//
// Flow:
//   1. start(payload:shortcutName:videoID:length:) copies `payload` to
//      the clipboard (videoID/length are just remembered for caching —
//      see `cachedSummary`/`cachePendingResult` — not sent anywhere),
//      then opens `shortcuts://x-callback-url/run-shortcut?...` with
//      input=clipboard and x-success/x-cancel/x-error all pointing back
//      at this app's own "ytrun://chatgpt-summary/<status>" URL scheme.
//   2. iOS switches to the Shortcuts app, which runs the named Shortcut
//      (reads the clipboard, asks ChatGPT, copies its reply back to
//      the clipboard) and then follows the x-success URL back here.
//      Along the way, iOS shows two "Allow Paste" prompts (Shortcut
//      reading the app's payload, this app reading the reply back) —
//      that's an iOS privacy control apps cannot suppress or
//      pre-authorize, not something wrong with this flow.
//   3. YTRunApp's `.onOpenURL` forwards that URL to `handle(url:)`,
//      which reads the clipboard as the result.
//
// `pasteManually()` is the recovery path: if step 2/3 never happens
// (the Shortcut stayed open somewhere instead of calling back), the
// user can switch back to this app themselves and tap "Paste From
// Clipboard".
final class ChatGPTShortcutBridge: ObservableObject {
    enum State: Equatable {
        case idle
        case buildingPayload
        case awaitingShortcut(startedAt: Date)
        case received(String)
        case cancelled
        case failed(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
    }

    static let maxPayloadCharacters = 100_000

    private static let callbackScheme = "ytrun"
    private static let callbackHost = "chatgpt-summary"

    @Published private(set) var state: State = .idle
    @Published private(set) var log: [LogEntry] = []
    private var lastPayload: String?
    // Which video/length the in-flight (or most recently finished) run
    // was actually for — set in `start()`, consulted when a result
    // shows up (either via `handle(url:)` or `pasteManually()`) so it
    // can be filed under the right cache key regardless of which path
    // delivered it.
    private var pendingVideoID: String?
    private var pendingLength: AIGatewaySummaryLength?
    // Same idea as `AIGatewayClient`'s cache — in memory only, and
    // deliberately scoped to just the *current* video (not a growing
    // history of every video visited this session), so reopening the
    // sheet or switching length back and forth reuses a result, but
    // navigating to another video and back just re-summarizes rather
    // than needing any cache eviction.
    private var cachedVideoID: String?
    private var cachedSummaries: [AIGatewaySummaryLength: String] = [:]

    // Based on ai-gateway's LENGTH_PROMPTS (see
    // services/youtube_summarizer.py), but the "short" one is written
    // more forcefully here — ChatGPT (via the Shortcuts action) was
    // observed being noticeably looser about "2-3 sentences" than
    // Codex was server-side, routinely landing closer to a paragraph.
    // A numeric word cap plus an explicit "don't write a paragraph"
    // seems to hold better than the sentence-count wording alone. Lives
    // here, in the app, rather than in the Shortcut: the Shortcut is
    // just "Get Clipboard -> Ask ChatGPT (Message = Clipboard) -> Copy
    // to Clipboard", generic and untouched no matter how these change.
    private static let lengthPrompts: [AIGatewaySummaryLength: String] = [
        .short: "Summarize the following YouTube video transcript in 2-3 short sentences, no more than "
            + "40 words total. Be extremely concise - a short paragraph is too long, this must read as a "
            + "quick one-line-or-two takeaway, not a mini-summary. "
            + "Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
        .paragraph: "Summarize the following YouTube video transcript in a single well-organized paragraph "
            + "(roughly 4-6 sentences) covering the main points. "
            + "Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
        .detailed: "Write a detailed summary of the following YouTube video transcript, covering all the "
            + "main points and key details across a few short paragraphs. "
            + "Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
    ]

    // Builds the plain-text payload the Shortcut receives: the prompt
    // for the chosen length, a small metadata header (title/channel/URL,
    // so the model has the source handy), then the transcript, already
    // stripped of timestamps by the caller (see
    // `DownloadManager.plainText(from:)`). Truncates rather than
    // sending an unbounded transcript — the "Ask ChatGPT" Shortcuts
    // action's own limits aren't documented.
    static func buildPayload(
        length: AIGatewaySummaryLength,
        title: String,
        channel: String?,
        videoURL: URL?,
        transcriptText: String
    ) -> String {
        var header = "Title: \(title)\n"
        if let channel, !channel.isEmpty {
            header += "Channel: \(channel)\n"
        }
        if let videoURL {
            header += "URL: \(videoURL.absoluteString)\n"
        }
        header += "\n"

        let prefix = (lengthPrompts[length] ?? lengthPrompts[.short]!) + "\n\n" + header

        if transcriptText.count > maxPayloadCharacters {
            let truncated = String(transcriptText.prefix(maxPayloadCharacters))
            return prefix + truncated + "\n\n[Transcript truncated at \(maxPayloadCharacters) characters]"
        }
        return prefix + transcriptText
    }

    // Synchronous, no Shortcuts round trip — lets a view check "do we
    // already have this?" the same way `AIGatewayClient.cachedSummary`
    // does for the server-based path.
    func cachedSummary(videoID: String, length: AIGatewaySummaryLength) -> String? {
        guard videoID == cachedVideoID else { return nil }
        return cachedSummaries[length]
    }

    func start(payload: String, shortcutName: String, videoID: String, length: AIGatewaySummaryLength) {
        pendingVideoID = videoID
        pendingLength = length
        lastPayload = payload
        state = .buildingPayload
        appendLog("Copying payload to clipboard (\(payload.count) characters)")
        UIPasteboard.general.string = payload

        guard let url = Self.shortcutURL(name: shortcutName) else {
            appendLog("Failed to build the shortcuts:// URL")
            state = .failed("Couldn't build the Shortcuts URL.")
            return
        }

        appendLog("Opening Shortcuts app: \"\(shortcutName)\"")
        state = .awaitingShortcut(startedAt: Date())
        UIApplication.shared.open(url) { [weak self] success in
            guard let self, !success else { return }
            Task { @MainActor in
                self.appendLog("UIApplication.open(_:) returned false")
                self.state = .failed("iOS couldn't open the Shortcuts app for that URL.")
            }
        }
    }

    // Called from YTRunApp's `.onOpenURL` for every URL the app is
    // opened with — returns whether it was actually ours, so unrelated
    // URL opens (should there ever be any) are left alone.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == Self.callbackScheme, url.host == Self.callbackHost else { return false }

        let status = url.pathComponents.count > 1 ? url.pathComponents[1] : "success"
        appendLog("Received callback: \(url.absoluteString)")

        switch status {
        case "cancel":
            state = .cancelled
        case "error":
            state = .failed("The Shortcut reported an error (x-error).")
        default:
            let clipboard = UIPasteboard.general.string ?? ""
            if clipboard.isEmpty {
                state = .failed("Returned from the Shortcut, but the clipboard is empty.")
            } else if clipboard == lastPayload {
                state = .failed("Clipboard still has the original transcript — the Shortcut likely didn't run, or didn't copy a new result.")
            } else {
                state = .received(clipboard)
                cachePendingResult(clipboard)
            }
        }
        appendLog("State -> \(state)")
        return true
    }

    // FR-5 recovery path — for when the Shortcut finished but never
    // actually triggered the x-success callback (e.g. it left the
    // ChatGPT app open in the foreground instead of returning here).
    func pasteManually() {
        let clipboard = UIPasteboard.general.string ?? ""
        appendLog("Manual paste read \(clipboard.count) characters from clipboard")
        if clipboard.isEmpty {
            state = .failed("Clipboard is empty.")
        } else if clipboard == lastPayload {
            state = .failed("Clipboard still has the original transcript, not a summary.")
        } else {
            state = .received(clipboard)
            cachePendingResult(clipboard)
        }
    }

    private func cachePendingResult(_ text: String) {
        guard let videoID = pendingVideoID, let length = pendingLength else { return }
        if videoID != cachedVideoID {
            cachedVideoID = videoID
            cachedSummaries = [:]
        }
        cachedSummaries[length] = text
    }

    func reset() {
        state = .idle
        lastPayload = nil
        appendLog("Reset")
    }

    private func appendLog(_ message: String) {
        log.append(LogEntry(message: message))
        // Keep only recent entries - this is a debug aid, not a record
        // that needs to survive indefinitely.
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static func shortcutURL(name: String) -> URL? {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "clipboard"),
            URLQueryItem(name: "x-success", value: "\(callbackScheme)://\(callbackHost)/success"),
            URLQueryItem(name: "x-cancel", value: "\(callbackScheme)://\(callbackHost)/cancel"),
            URLQueryItem(name: "x-error", value: "\(callbackScheme)://\(callbackHost)/error"),
        ]
        return components?.url
    }
}
