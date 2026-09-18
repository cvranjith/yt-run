//
//  ChatGPTShortcutIntents.swift
//  YTRun
//

import AppIntents

// These two App Intents are what the "Summarize via ChatGPT" Shortcut
// (see chatgpt-shortcut-setup.md) actually calls, instead of "Get
// Clipboard" / "Copy to Clipboard" — no build-time registration beyond
// this file existing in the app target; App Intents are auto-discovered
// and show up in the Shortcuts app's action list under YTRun once the
// app has been built and launched at least once.
struct GetPendingTranscript: AppIntent {
    static var title: LocalizedStringResource = "Get Pending Transcript"
    static var openAppWhenRun = false

    func perform() async throws -> some ReturnsValue<String> {
        .result(value: TranscriptExchange.pendingPayload ?? "")
    }
}

struct SaveSummary: AppIntent {
    static var title: LocalizedStringResource = "Save Summary"
    static var openAppWhenRun = false

    @Parameter(title: "Summary")
    var summary: String

    func perform() async throws -> some IntentResult {
        TranscriptExchange.receivedSummary = summary
        return .result()
    }
}
