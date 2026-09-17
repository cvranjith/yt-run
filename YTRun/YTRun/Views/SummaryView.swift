//
//  SummaryView.swift
//  YTRun
//

import SwiftUI

// Summarizes the current video's transcript via a self-hosted
// ai-gateway (see `AIGatewayClient`) and, once fetched, can read the
// result aloud on-device (see `SpeechReader`) — fully local
// text-to-speech, no further network call for that part.
struct SummaryView: View {
    @EnvironmentObject var webViewStore: YouTubeWebViewStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var aiGatewayClient: AIGatewayClient
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speechReader = SpeechReader()

    @State private var length: AIGatewaySummaryLength = .short
    @State private var summary: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Length", selection: $length) {
                    ForEach(AIGatewaySummaryLength.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .disabled(isLoading)
                .onChange(of: length) { _, _ in
                    // A cache lookup, not a server request — safe to do
                    // just from picking a length. Shows the cached
                    // summary for this length if one exists already, or
                    // clears back to the blank "Summarize" state (never
                    // leaves the *previous* length's text on screen
                    // looking like it belongs to this one).
                    refreshFromCache()
                }

                // No auto-fetch on appear and no auto-refetch when the
                // length picker changes — picking a length is a
                // deliberate choice the user should get to make before
                // any request goes out, not something that fires a
                // (possibly wrong-length, wasted) request on its own.
                Button {
                    Task { await summarize() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(summary == nil && errorMessage == nil ? "Summarize" : "Regenerate")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .disabled(isLoading)

                Group {
                    // `summary` checked first (even while `isLoading`,
                    // for a Regenerate) so a prior result stays visible
                    // instead of flashing blank while a new one loads.
                    if let summary {
                        ScrollView {
                            Text(summary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Couldn't Summarize",
                            systemImage: "text.bubble",
                            description: Text(errorMessage)
                        )
                    } else if isLoading {
                        ProgressView("Summarizing…")
                    } else {
                        ContentUnavailableView(
                            "Ready to Summarize",
                            systemImage: "text.bubble",
                            description: Text("Choose a length above, then tap Summarize.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let summary {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ShareLink(item: summary)
                        readAloudButton(for: summary)
                    }
                }
            }
            .onAppear {
                // Also just a cache lookup — reopening the sheet for a
                // video already summarized this session should show it
                // straight away, with no tap and no server round trip.
                refreshFromCache()
            }
            .onDisappear {
                // Otherwise speech keeps going after the sheet closes,
                // reading a summary the user can no longer even see.
                speechReader.stop()
            }
        }
    }

    @ViewBuilder
    private func readAloudButton(for summary: String) -> some View {
        if speechReader.isSpeaking && !speechReader.isPaused {
            Button {
                speechReader.pause()
            } label: {
                Image(systemName: "pause.circle")
            }
            .accessibilityLabel("Pause reading")
        } else if speechReader.isPaused {
            Button {
                speechReader.resume()
            } label: {
                Image(systemName: "play.circle")
            }
            .accessibilityLabel("Resume reading")
        } else {
            Button {
                // Courtesy pause so the read-aloud voice and the video's
                // own audio don't talk over each other.
                webViewStore.pause()
                speechReader.speak(summary)
            } label: {
                Image(systemName: "speaker.wave.2.circle")
            }
            .accessibilityLabel("Read summary aloud")
        }
    }

    // No network — just reflects whatever `AIGatewayClient` already has
    // cached for the video/length combination currently selected.
    private func refreshFromCache() {
        errorMessage = nil
        guard let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            summary = nil
            return
        }
        summary = aiGatewayClient.cachedSummary(videoID: videoID, length: length)
    }

    private func summarize() async {
        guard let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            errorMessage = "Couldn't tell which video this is — try again once the page has fully loaded."
            summary = nil
            return
        }

        let requestedLength = length
        isLoading = true
        speechReader.stop()

        let result = await aiGatewayClient.summarize(videoID: videoID, length: requestedLength, settings: settings)
        // The length picker may have changed while this was in flight —
        // if so, this result is stale (it's already been cached by
        // AIGatewayClient regardless, so nothing is lost); only apply it
        // to the screen if it still matches what's currently selected.
        if requestedLength == length {
            switch result {
            case .success(let text):
                summary = text
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.message
                summary = nil
            }
        }
        isLoading = false
    }
}

#Preview {
    SummaryView()
        .environmentObject(YouTubeWebViewStore())
        .environmentObject(AppSettings())
        .environmentObject(AIGatewayClient())
}
