//
//  DownloadsView.swift
//  YTRun
//

import SwiftUI

// Plain filesystem-backed list (not a `@Query`) — `DownloadManager`
// doesn't persist its own metadata, so this reloads directly off
// `DownloadManager.listDownloads()` on appear and after every delete.
struct DownloadsView: View {
    @State private var downloads: [DownloadedFile] = []

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
                    DownloadRow(file: file)
                }
                // Standard iOS swipe-to-delete, same idiom as
                // `RunHistoryView` — deletes the actual file on disk.
                .onDelete(perform: deleteDownloads)
            }
        }
        .navigationTitle("Downloads")
        .onAppear(perform: reload)
    }

    private func reload() {
        downloads = DownloadManager.listDownloads()
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
            // Gives these local files somewhere to actually go — Files,
            // AirDrop, another app — rather than being stuck in the app.
            ShareLink(item: file.url)
                .labelStyle(.iconOnly)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
    }
}
