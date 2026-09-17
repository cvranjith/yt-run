//
//  DownloadsView.swift
//  YTRun
//

import SwiftUI
import AVKit

// Plain filesystem-backed list (not a `@Query`) — `DownloadManager`
// doesn't persist its own metadata, so this reloads directly off
// `DownloadManager.listDownloads()` on appear and after every delete.
struct DownloadsView: View {
    private static let textExtensions: Set<String> = ["txt", "srt"]

    @State private var downloads: [DownloadedFile] = []
    @State private var selectedFile: DownloadedFile?
    // Shared with `CaptionsViewerView` via the same `@AppStorage` key.
    @AppStorage("transcriptFontSize") private var fontSize: Double = 17

    var body: some View {
        List {
            if downloads.isEmpty {
                ContentUnavailableView(
                    "No Downloads Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Use the download button on the YouTube screen to save a video — or just its audio, in Listen Mode — here.")
                )
            } else {
                ForEach(downloads) { file in
                    // `.onTapGesture` rather than wrapping the row in a
                    // `Button` — a nested Button was silently eating the
                    // List row's own swipe gesture, making both
                    // `.onDelete` and `.swipeActions` below unreachable.
                    // A plain tap gesture coexists with them correctly.
                    DownloadRow(file: file)
                        .onTapGesture {
                            selectedFile = file
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(file)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete(perform: deleteDownloads)
            }
        }
        .navigationTitle("Downloads")
        .onAppear(perform: reload)
        .sheet(item: $selectedFile) { file in
            NavigationStack {
                Group {
                    if Self.textExtensions.contains(file.url.pathExtension.lowercased()) {
                        TextFileViewer(url: file.url, fontSize: $fontSize)
                    } else {
                        VideoPlayer(player: AVPlayer(url: file.url))
                            .ignoresSafeArea()
                    }
                }
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { selectedFile = nil }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if Self.textExtensions.contains(file.url.pathExtension.lowercased()) {
                            FontSizeControl(fontSize: $fontSize)
                        }
                        // A delete action reachable from right inside the
                        // viewer — not just the list's swipe action —
                        // since deciding "I don't want this" often
                        // happens right after actually looking at it.
                        Button(role: .destructive) {
                            delete(file)
                            selectedFile = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete")
                    }
                }
            }
        }
    }

    private func reload() {
        downloads = DownloadManager.listDownloads()
    }

    private func delete(_ file: DownloadedFile) {
        try? DownloadManager.delete(file)
        reload()
    }

    private func deleteDownloads(at offsets: IndexSet) {
        for index in offsets {
            try? DownloadManager.delete(downloads[index])
        }
        reload()
    }
}

private struct DownloadRow: View {
    let file: DownloadedFile

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let createdAt = file.createdAt {
                        Text(createdAt, style: .date)
                    }
                    Text(Self.byteFormatter.string(fromByteCount: file.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ["txt", "srt"].contains(file.url.pathExtension.lowercased()) ? "doc.text" : "play.circle")
                .foregroundStyle(.secondary)
            // Gives these local files somewhere to actually go — Files,
            // AirDrop, another app — rather than being stuck in the app.
            // A separate tappable control from the row's own Button
            // above; tapping it shares instead of playing.
            ShareLink(item: file.url)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// Plain read-only viewer for a saved caption transcript (.txt) or
// subtitle file (.srt) — `VideoPlayer` can't render either, so these
// get their own simple presentation instead. `.textSelection(.enabled)`
// lets the transcript actually be copied out, not just looked at.
private struct TextFileViewer: View {
    let url: URL
    @Binding var fontSize: Double

    var body: some View {
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "Couldn't read this file.")
            .components(separatedBy: .newlines)
        ScrollView {
            // A lazy list of per-line Text views, not one giant Text
            // holding the whole file — a single Text with this much
            // content (100k+ characters for a longer transcript) hit a
            // real SwiftUI rendering cliff on-device and simply showed
            // nothing. LazyVStack only lays out the lines actually on
            // screen.
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
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

#Preview {
    NavigationStack {
        DownloadsView()
    }
}
