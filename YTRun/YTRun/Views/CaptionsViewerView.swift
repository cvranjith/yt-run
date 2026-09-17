//
//  CaptionsViewerView.swift
//  YTRun
//

import SwiftUI

// Shows the current video's captions as a readable transcript right
// away — saving to a file (.txt or .srt) is an explicit, optional
// action from here, not the only way to see them. See
// `DownloadManager.fetchCaptionEvents(videoID:)` for how the transcript
// is actually found.
struct CaptionsViewerView: View {
    @EnvironmentObject var webViewStore: YouTubeWebViewStore
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var events: [CaptionEvent] = []
    @State private var videoTitle = "Video"
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var saveResultMessage: String?
    // Controls both what's currently displayed and what Save/Share act
    // on — one toggle instead of separate "as text" / "as SRT" actions.
    @State private var viewFormat: CaptionFormat = .text
    // Shared with `DownloadsView`'s `TextFileViewer` via the same
    // `@AppStorage` key, so the preference is consistent (and persists)
    // across both places a transcript can be read.
    @AppStorage("transcriptFontSize") private var fontSize: Double = 17

    private var displayText: String {
        viewFormat == .text ? DownloadManager.plainText(from: events) : DownloadManager.srt(from: events)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !events.isEmpty {
                    Picker("Format", selection: $viewFormat) {
                        Text("Text").tag(CaptionFormat.text)
                        Text("SRT").tag(CaptionFormat.srt)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                Group {
                    if isLoading {
                        ProgressView("Loading captions…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "No Captions",
                            systemImage: "captions.bubble",
                            description: Text(errorMessage)
                        )
                    } else {
                        ScrollView {
                            // A lazy list of per-line Text views, not one
                            // giant Text holding the whole transcript —
                            // a single Text with this much content (100k+
                            // characters for a longer video) hit a real
                            // SwiftUI rendering cliff on-device and
                            // simply showed nothing. LazyVStack only lays
                            // out the lines actually on screen.
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(displayText.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                }
                            }
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !events.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        FontSizeControl(fontSize: $fontSize)
                        // Shares the transcript text directly (no
                        // save-first step needed) — respects whichever
                        // format is currently toggled above.
                        ShareLink(item: displayText)
                        Button {
                            save(viewFormat)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("Save")
                    }
                }
            }
            .task {
                await load()
            }
            .alert("Captions", isPresented: Binding(
                get: { saveResultMessage != nil },
                set: { if !$0 { saveResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveResultMessage ?? "")
            }
        }
    }

    private func load() async {
        guard let videoID = DownloadManager.videoID(from: webViewStore.currentURL) else {
            errorMessage = "Couldn't tell which video this is — try again once the page has fully loaded."
            isLoading = false
            return
        }

        // Title is only needed for the save filename; independent of the
        // caption fetch itself, so these run concurrently.
        async let infoTask = webViewStore.fetchDownloadInfo()
        async let resultTask = downloadManager.fetchCaptionEvents(videoID: videoID)
        let (info, result) = await (infoTask, resultTask)
        videoTitle = info?.title ?? "Video"

        switch result {
        case .success(let fetchedEvents):
            events = fetchedEvents
        case .failure(let error):
            errorMessage = error.message
        }
        isLoading = false
    }

    private func save(_ format: CaptionFormat) {
        let result = downloadManager.saveCaptionFile(events: events, title: videoTitle, format: format)
        switch result {
        case .success(let url):
            saveResultMessage = "Saved as \(url.lastPathComponent)."
        case .failure(let error):
            saveResultMessage = error.message
        }
    }
}

// A- / A+ pair for adjusting transcript text size — shared by both
// `CaptionsViewerView` and `DownloadsView`'s `TextFileViewer` via the
// same `@AppStorage` binding they're each passed.
struct FontSizeControl: View {
    @Binding var fontSize: Double

    private static let range: ClosedRange<Double> = 12...30
    private static let step: Double = 2

    var body: some View {
        HStack(spacing: 0) {
            Button {
                fontSize = max(Self.range.lowerBound, fontSize - Self.step)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(fontSize <= Self.range.lowerBound)

            Button {
                fontSize = min(Self.range.upperBound, fontSize + Self.step)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(fontSize >= Self.range.upperBound)
        }
    }
}

#Preview {
    CaptionsViewerView()
        .environmentObject(YouTubeWebViewStore())
        .environmentObject(DownloadManager())
}
