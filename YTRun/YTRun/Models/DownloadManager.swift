//
//  DownloadManager.swift
//  YTRun
//

import Foundation
import Combine

// Result of `YouTubeWebViewStore.fetchDownloadInfo()` — the current
// page's title plus whichever media stream URLs were found (see
// `downloadInfoJS`). `videoURL`/`audioURL` are independently nilable: a
// video with only one of the two just means the other kind of download
// isn't available for it, not a failure to fetch info at all.
struct DownloadInfo {
    let title: String
    let userAgent: String?
    let videoURL: URL?
    let audioURL: URL?
}

enum DownloadError: Error {
    case alreadyInProgress
    case noStreamAvailable
    case network(Error)
    case fileSystem(Error)

    var message: String {
        switch self {
        case .alreadyInProgress:
            return "A download is already in progress."
        case .noStreamAvailable:
            return "This video's stream isn't available for direct download — YouTube may have protected it, or (for audio) it may need a few seconds of playback first before its stream URL is known."
        case .network(let error):
            return "Download failed: \(error.localizedDescription)"
        case .fileSystem(let error):
            return "Couldn't save the file: \(error.localizedDescription)"
        }
    }
}

// A file already saved under `DownloadManager.downloadsDirectory` —
// listed straight off the filesystem rather than a separate persisted
// model, since the directory itself is already the source of truth for
// "what's downloaded" (see `DownloadManager.listDownloads()`).
struct DownloadedFile: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let sizeBytes: Int64
    let createdAt: Date?
}

// Downloads the currently-playing video (or, in Listen Mode, just its
// audio) to the app's own Documents/Downloads folder. No queue — one
// download at a time, matching the single Download button that triggers
// this (see `YouTubeView`).
//
// This is inherently best-effort and won't work for every video: it only
// ever uses stream URLs that either came unciphered from YouTube's own
// embedded player metadata, or that the real player already resolved and
// used itself (see `downloadInfoJS`) — there's no signature-cipher
// solving here, which is the large, constantly-shifting undertaking that
// makes a tool like yt-dlp so much bigger than this.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var isDownloading = false

    static let downloadsDirectory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return downloads
    }()

    func download(info: DownloadInfo, audioOnly: Bool) async -> Result<URL, DownloadError> {
        guard !isDownloading else { return .failure(.alreadyInProgress) }
        guard let sourceURL = audioOnly ? info.audioURL : info.videoURL else {
            return .failure(.noStreamAvailable)
        }

        isDownloading = true
        defer { isDownloading = false }

        var request = URLRequest(url: sourceURL)
        if let userAgent = info.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            return .failure(.network(error))
        }

        let ext = Self.fileExtension(mimeType: response.mimeType, audioOnly: audioOnly)
        let destinationURL = Self.uniqueDestinationURL(title: info.title, extension: ext)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        } catch {
            return .failure(.fileSystem(error))
        }
        return .success(destinationURL)
    }

    // MARK: - Listing / deleting

    static func listDownloads() -> [DownloadedFile] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return items.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            return DownloadedFile(
                id: url,
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                sizeBytes: Int64(values?.fileSize ?? 0),
                createdAt: values?.creationDate
            )
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func delete(_ file: DownloadedFile) throws {
        try FileManager.default.removeItem(at: file.url)
    }

    // MARK: - Filename

    private static func fileExtension(mimeType: String?, audioOnly: Bool) -> String {
        switch mimeType {
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "audio/mp4": return "m4a"
        case "audio/webm": return "weba"
        default: return audioOnly ? "m4a" : "mp4"
        }
    }

    private static let invalidFilenameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")

    // Sanitizes the video title into a filesystem-safe name, truncated so
    // it stays reasonable to look at in Files/share sheets, with a short
    // random suffix so two videos that happen to share a (possibly
    // truncated) title don't silently overwrite each other.
    private static func uniqueDestinationURL(title: String, extension ext: String) -> URL {
        var sanitized = title.components(separatedBy: invalidFilenameCharacters).joined(separator: " ")
        sanitized = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if sanitized.isEmpty { sanitized = "Video" }
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80))
        }

        let suffix = String(UUID().uuidString.prefix(6))
        return downloadsDirectory.appendingPathComponent("\(sanitized) (\(suffix)).\(ext)")
    }
}
