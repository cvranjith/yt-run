//
//  VideoDetailView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Stats for a single video — its segments may span several watch
// stretches (e.g. resumed after locking the phone), so everything here
// is aggregated across all of them. "Watch Again" reopens it through the
// app's own YouTube screen rather than externally, so it still counts
// against the daily/binge gate like any other watch — consistent with
// the app's whole premise of "only watch through this app."
struct VideoDetailView: View {
    let segments: [WatchSegment]

    @EnvironmentObject private var webViewStore: YouTubeWebViewStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingHideConfirmation = false

    private var first: WatchSegment? { segments.first }
    private var isHidden: Bool { first?.isHidden ?? false }
    private var totalSeconds: Int { segments.reduce(0) { $0 + $1.durationSeconds } }
    private var viewSeconds: Int { segments.filter { !$0.isBackground }.reduce(0) { $0 + $1.durationSeconds } }
    private var listenSeconds: Int { segments.filter { $0.isBackground && !$0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }
    private var carSeconds: Int { segments.filter { $0.isBackground && $0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }

    var body: some View {
        List {
            Section {
                statRow("Channel", first?.channelName ?? "Unknown")
                statRow("Type", first?.isShorts == true ? "Shorts" : "Video")
            }

            Section {
                statRow("Total watched", formatDuration(totalSeconds))
                statRow("View (screen on)", formatDuration(viewSeconds))
                statRow("Listen (locked/background)", formatDuration(listenSeconds))
                if carSeconds > 0 {
                    statRow("Car (locked, car audio)", formatDuration(carSeconds))
                }
            } header: {
                Text("Watched")
            } footer: {
                Text("This is how long you watched, not the video's full length — YouTube doesn't expose that without a paid API.")
            }

            if let urlString = first?.videoURL, let url = URL(string: urlString) {
                Section {
                    NavigationLink {
                        // Loading here (rather than via a tap gesture
                        // bolted onto the link) avoids the two gesture
                        // recognizers fighting each other — this way the
                        // load only happens once the destination view is
                        // actually pushed.
                        YouTubeView()
                            .onAppear { webViewStore.load(url) }
                    } label: {
                        Label("Watch Again", systemImage: "play.circle.fill")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isShowingHideConfirmation = true
                    } label: {
                        Label("Hide This Video", systemImage: "eye.slash")
                    }
                } footer: {
                    Text("Removes the title, link, and channel from history. Watch time still counts toward your totals. This can't be undone.")
                }
            }
        }
        .navigationTitle(isHidden ? "Hidden video" : (first?.videoTitle ?? "Video"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Hide this video?",
            isPresented: $isShowingHideConfirmation
        ) {
            Button("Hide Video", role: .destructive) {
                WatchSegment.hide(segments)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return remaining == 0 ? "\(minutes) min" : "\(minutes)m \(remaining)s"
    }
}

#Preview {
    NavigationStack {
        VideoDetailView(segments: [
            WatchSegment(date: Date(), durationSeconds: 600, isBackground: false, isCarAudio: false, isShorts: false, channelName: "Some Channel", videoURL: "https://m.youtube.com/watch?v=abc123"),
            WatchSegment(date: Date(), durationSeconds: 180, isBackground: true, isCarAudio: false, isShorts: false, channelName: "Some Channel", videoURL: "https://m.youtube.com/watch?v=abc123")
        ])
    }
    .environmentObject(AppSettings())
    .environmentObject(UsageTracker())
    .environmentObject(YouTubeWebViewStore())
}
