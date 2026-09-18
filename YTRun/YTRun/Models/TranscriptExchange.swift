//
//  TranscriptExchange.swift
//  YTRun
//

import Foundation

// Hand-off point between YTRun and the "Summarize via ChatGPT" Shortcut
// (see `ChatGPTShortcutBridge`, `ChatGPTShortcutIntents.swift`) —
// replaces the clipboard as the data channel. The Shortcut now calls
// this app's own App Intents ("Get Pending Transcript" / "Save
// Summary") directly instead of reading/writing the system pasteboard,
// which is what actually removes the "Allow Paste" prompts: App
// Intents pass values through the Shortcuts execution engine itself,
// never through the pasteboard at all.
//
// Backed by UserDefaults rather than a plain in-memory singleton:
// opening the Shortcuts app to run the Shortcut backgrounds this app,
// and while iOS usually keeps a just-backgrounded process alive for
// the handful of seconds this round trip takes, that's not guaranteed
// - if iOS reclaims the process and a fresh one is launched to service
// the App Intent, plain in-memory state would already be gone. A
// couple of small strings in UserDefaults survives that.
enum TranscriptExchange {
    private static let payloadKey = "chatGPTShortcutPendingPayload"
    private static let summaryKey = "chatGPTShortcutReceivedSummary"

    static var pendingPayload: String? {
        get { UserDefaults.standard.string(forKey: payloadKey) }
        set { UserDefaults.standard.set(newValue, forKey: payloadKey) }
    }

    static var receivedSummary: String? {
        get { UserDefaults.standard.string(forKey: summaryKey) }
        set { UserDefaults.standard.set(newValue, forKey: summaryKey) }
    }
}
