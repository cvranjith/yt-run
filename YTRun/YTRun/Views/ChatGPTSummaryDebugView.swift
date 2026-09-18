//
//  ChatGPTSummaryDebugView.swift
//  YTRun
//

import SwiftUI

// A second, independent path to a summary via the user's own ChatGPT
// iPhone app and a hand-built Shortcut, instead of ai-gateway (see
// `SummaryView`/`AIGatewayClient` for the server-based path — this
// doesn't touch or replace that; both are peer options on the YouTube
// screen's Download menu). See `ChatGPTShortcutBridge` and
// chatgpt-shortcut-setup.md for the Shortcut this depends on.
struct ChatGPTSummaryDebugView: View {
    @EnvironmentObject var webViewStore: YouTubeWebViewStore
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var bridge: ChatGPTShortcutBridge
    @Environment(\.dismiss) private var dismiss

    @State private var length: AIGatewaySummaryLength = .short
    @State private var isPreparing = false
    @State private var prepareError: String?
    @State private var lastPayloadPreview: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Length", selection: $length) {
                        ForEach(AIGatewaySummaryLength.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isPreparing)
                    .onChange(of: length) { _, _ in
                        // A cache lookup, not a live request — resets
                        // any in-flight/terminal state from the
                        // previous length so `displayedSummary` below
                        // re-derives cleanly: shows this length's
                        // cached result if there is one, else blank
                        // with "Send to ChatGPT" rather than the old
                        // length's text sitting under "Regenerate".
                        bridge.reset()
                        prepareError = nil
                        lastPayloadPreview = nil
                    }
                }

                Section {
                    Button {
                        Task { await sendToShortcut() }
                    } label: {
                        if isPreparing {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(displayedSummary == nil ? "Send to ChatGPT" : "Regenerate")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)

                    if let prepareError {
                        Text(prepareError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let displayedSummary {
                    Section {
                        Text(displayedSummary)
                            .textSelection(.enabled)
                        ShareLink(item: displayedSummary)
                    }
                }

                // Compact status line — only worth expanding on with a
                // Reset/manual-paste option when something's actually
                // in flight or went wrong; otherwise just a small,
                // unobtrusive row rather than its own prominent section.
                Section {
                    HStack {
                        statusRow
                        Spacer()
                        if bridge.state != .idle {
                            Button("Reset") { bridge.reset() }
                                .font(.caption)
                        }
                    }
                    if case .awaitingShortcut = bridge.state {
                        Button("Check for Result") {
                            bridge.checkForResultManually()
                        }
                        .font(.caption)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                Section {
                    DisclosureGroup("Debug Info") {
                        if let lastPayloadPreview {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last Payload Sent")
                                    .font(.caption).bold()
                                Text(lastPayloadPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(6)
                            }
                        }
                        if bridge.log.isEmpty {
                            Text("No log entries yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(bridge.log.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Summarize via ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // `bridge` is a shared, app-wide object, so its `state`
                // can be left over from a previous video/length by the
                // time this sheet is reopened — reset it so the cache
                // lookup below (via `displayedSummary`) is what decides
                // what's shown, not a stale terminal state.
                bridge.reset()
            }
        }
    }

    // What to actually show: a live/just-finished result takes
    // priority; otherwise, once idle, fall back to whatever's cached
    // for the current video + length (the same shape as
    // `AIGatewayClient.cachedSummary`/`SummaryView.refreshFromCache`).
    private var displayedSummary: String? {
        if case .received(let text) = bridge.state { return text }
        guard case .idle = bridge.state, let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            return nil
        }
        return bridge.cachedSummary(videoID: videoID, length: length)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch bridge.state {
        case .idle:
            Text("Idle").font(.caption).foregroundStyle(.secondary)
        case .buildingPayload:
            Label("Preparing transcript…", systemImage: "doc.text").font(.caption)
        case .awaitingShortcut(let startedAt):
            Label("Waiting for the Shortcut… (\(startedAt, style: .relative))", systemImage: "hourglass")
                .font(.caption)
        case .received:
            Label("Received", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func sendToShortcut() async {
        guard let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            prepareError = "Couldn't tell which video this is — try again once the page has fully loaded."
            return
        }

        isPreparing = true
        prepareError = nil

        async let infoTask = webViewStore.fetchDownloadInfo()
        async let captionsTask = downloadManager.fetchCaptionEvents(videoID: videoID)
        let (info, captionsResult) = await (infoTask, captionsTask)

        switch captionsResult {
        case .success(let events):
            let transcript = DownloadManager.plainText(from: events)
            let payload = ChatGPTShortcutBridge.buildPayload(
                length: length,
                title: info?.title ?? "Video",
                channel: webViewStore.currentChannelName,
                videoURL: webViewStore.currentURL,
                transcriptText: transcript
            )
            lastPayloadPreview = String(payload.prefix(400))
            bridge.start(payload: payload, shortcutName: settings.chatGPTShortcutName, videoID: videoID, length: length)
        case .failure(let error):
            prepareError = error.message
        }
        isPreparing = false
    }
}

#Preview {
    ChatGPTSummaryDebugView()
        .environmentObject(YouTubeWebViewStore())
        .environmentObject(DownloadManager())
        .environmentObject(AppSettings())
        .environmentObject(ChatGPTShortcutBridge())
}
