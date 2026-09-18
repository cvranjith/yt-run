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

// One caption line, already stripped of the raw JSON shape it arrived
// in — used both to render the on-screen transcript and, if the user
// chooses to save it, to build a .txt or .srt file from the exact same
// fetched data (no re-fetching just to save what's already on screen).
struct CaptionEvent {
    let startMs: Int?
    let durationMs: Int?
    let text: String
}

enum CaptionFormat {
    case text
    case srt

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .srt: return "srt"
        }
    }
}

enum DownloadError: Error {
    case alreadyInProgress
    case noCaptionsAvailable
    case network(Error)
    case fileSystem(Error)
    case emptyOrTruncated
    case gateway(AIGatewayError)

    var message: String {
        switch self {
        case .alreadyInProgress:
            return "A download is already in progress."
        case .noCaptionsAvailable:
            return "No usable captions were found for this video."
        case .network(let error):
            return "Download failed: \(error.localizedDescription)"
        case .fileSystem(let error):
            return "Couldn't save the file: \(error.localizedDescription)"
        case .emptyOrTruncated:
            return "The download came back empty or incomplete, so it wasn't saved. This can happen if YouTube's stream link expired mid-download — try again."
        case .gateway(let error):
            return error.message
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
    // 0...1, meaningful only while `isDownloading` — drives the
    // progress bar in YouTubeView. Reported by `DownloadTaskCoordinator`
    // below, which only knows the total size once the server actually
    // sends a Content-Length — before that (or if it never does), this
    // just stays at 0 and the UI falls back to an indeterminate spinner.
    @Published private(set) var downloadProgress: Double = 0

    static let downloadsDirectory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return downloads
    }()

    // Resolves a direct download URL via ai-gateway's youtube_download
    // service (see `AIGatewayClient.resolveDownloadURL`), then downloads
    // it directly from YouTube's own CDN — no video bytes ever pass
    // through the gateway. Replaces the old approach of scraping
    // `ytInitialPlayerResponse` in the WebView for an unciphered stream
    // URL, which only worked for a subset of videos; yt-dlp server-side
    // resolves a working URL for effectively any video.
    func download(
        videoID: String,
        kind: AIGatewayDownloadKind,
        title fallbackTitle: String,
        aiGatewayClient: AIGatewayClient,
        settings: AppSettings
    ) async -> Result<URL, DownloadError> {
        guard !isDownloading else { return .failure(.alreadyInProgress) }

        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadProgress = 0
        }

        let resolved: AIGatewayDownloadInfo
        switch await aiGatewayClient.resolveDownloadURL(videoID: videoID, kind: kind, settings: settings) {
        case .success(let info):
            resolved = info
        case .failure(let error):
            return .failure(.gateway(error))
        }

        let coordinator = DownloadTaskCoordinator { [weak self] fraction in
            self?.downloadProgress = fraction
        }

        let tempURL: URL
        do {
            tempURL = try await coordinator.start(request: URLRequest(url: resolved.url))
        } catch {
            return .failure(.network(error))
        }

        // Same sanity check as before: a "successful" response that's
        // actually empty/truncated (e.g. the resolved URL expired mid-
        // download) shouldn't be reported as a saved file.
        let minimumValidBytes: Int64 = 32 * 1024
        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? nil
        guard let size = downloadedSize, size >= minimumValidBytes else {
            try? FileManager.default.removeItem(at: tempURL)
            return .failure(.emptyOrTruncated)
        }

        let destinationURL = Self.uniqueDestinationURL(
            title: resolved.title.isEmpty ? fallbackTitle : resolved.title,
            extension: resolved.ext
        )
        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        } catch {
            return .failure(.fileSystem(error))
        }
        return .success(destinationURL)
    }

    // Fetches the video's captions for on-screen viewing — saving to a
    // file is a separate, later step (`saveCaptionFile`) using the same
    // events, so viewing never requires committing to a save.
    //
    // Two earlier approaches were dead ends, both confirmed with hard
    // evidence rather than assumption:
    // 1. Reading `ytInitialPlayerResponse.captions` out of the already-
    //    loaded page — genuinely `null` for some videos even when CC is
    //    visibly available, apparently only populated once the user
    //    actually toggles CC on in the player.
    // 2. The legacy `timedtext?type=list` discovery endpoint — confirmed
    //    dead server-side for *any* caller via a plain `curl` with no
    //    session at all (HTTP 200, `content-length: 0`, even for videos
    //    that definitely have captions).
    //
    // What actually works (verified the same way, via `curl`, before
    // implementing): request a *fresh* player response from YouTube's
    // internal `/youtubei/v1/player` API using the ANDROID client
    // context — the same technique the `youtube-transcript-api` Python
    // library uses. This is a stateless API call (no cookies/session
    // needed) that returns full caption track data, including a
    // baseUrl already signed and ready to fetch directly — unlike the
    // dead discovery endpoint, that per-track URL still works fine.
    // Entirely native networking now; no WebView/JS bridging involved.
    // Cheap presence check — reuses the same lookup `fetchCaptionEvents`
    // does, but stops as soon as it knows whether any caption track
    // exists, without fetching a transcript. Lets the UI grey out "View
    // Captions"/"Summarize" for videos with none at all, the same way
    // YouTube's own apps do — by asking an INNERTUBE client context
    // that actually includes caption tracks in its player response.
    // (The mobile web page's own embedded `ytInitialPlayerResponse`
    // does NOT reliably include this — confirmed absent even for videos
    // that do have captions — which is why this native check exists
    // instead of just reading something already on the page.)
    func hasCaptions(videoID: String) async -> Bool {
        guard let apiKey = await Self.fetchInnertubeAPIKey(videoID: videoID) else { return false }
        guard let tracks = await Self.fetchCaptionTracks(videoID: videoID, apiKey: apiKey) else { return false }
        return !tracks.isEmpty
    }

    // Scoped to just the current video, same reasoning as
    // AIGatewayClient/ChatGPTShortcutBridge's summary caches — avoids
    // an unnecessary repeat trip to YouTube's INNERTUBE API when the
    // same video's transcript is asked for more than once in a row
    // (View Captions, then Summarize via ChatGPT, then a different
    // length, etc.), without needing any cache eviction: moving to a
    // different video just replaces it.
    private var cachedTranscriptVideoID: String?
    private var cachedTranscriptEvents: [CaptionEvent]?

    func fetchCaptionEvents(videoID: String) async -> Result<[CaptionEvent], DownloadError> {
        if videoID == cachedTranscriptVideoID, let cached = cachedTranscriptEvents {
            return .success(cached)
        }

        guard let apiKey = await Self.fetchInnertubeAPIKey(videoID: videoID) else {
            return .failure(.noCaptionsAvailable)
        }
        guard let tracks = await Self.fetchCaptionTracks(videoID: videoID, apiKey: apiKey),
              let track = Self.bestTrack(from: tracks) else {
            return .failure(.noCaptionsAvailable)
        }

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: Self.withJSON3Format(track.baseURL))
        } catch {
            return .failure(.network(error))
        }

        guard let transcript = try? JSONDecoder().decode(CaptionJSON3.self, from: data),
              let rawEvents = transcript.events else {
            return .failure(.noCaptionsAvailable)
        }

        let events: [CaptionEvent] = rawEvents.compactMap { event in
            guard let segs = event.segs else { return nil }
            let text = segs.compactMap { $0.utf8 }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CaptionEvent(startMs: event.tStartMs, durationMs: event.dDurationMs, text: text)
        }
        guard !events.isEmpty else { return .failure(.noCaptionsAvailable) }
        cachedTranscriptVideoID = videoID
        cachedTranscriptEvents = events
        return .success(events)
    }

    // Writes already-fetched caption events (from `fetchCaptionEvents`)
    // to a file — synchronous and network-free, since there's nothing
    // left to fetch at this point.
    func saveCaptionFile(events: [CaptionEvent], title: String, format: CaptionFormat) -> Result<URL, DownloadError> {
        let content = format == .text ? Self.plainText(from: events) : Self.srt(from: events)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noCaptionsAvailable)
        }

        let destinationURL = Self.uniqueDestinationURL(title: "\(title) captions", extension: format.fileExtension)
        do {
            try content.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.fileSystem(error))
        }
        return .success(destinationURL)
    }

    // Shared by every feature that needs to know which video is
    // currently on screen (captions, summarize) — pulled from the `v`
    // query item on the watch-page URL, same as everywhere else in the
    // app that already parses one out.
    static func videoID(from url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value
    }

    static func plainText(from events: [CaptionEvent]) -> String {
        events.map { $0.text }.joined(separator: "\n")
    }

    static func srt(from events: [CaptionEvent]) -> String {
        var blocks: [String] = []
        var index = 1
        for event in events {
            guard let start = event.startMs, let duration = event.durationMs else { continue }
            blocks.append("\(index)\n\(srtTimestamp(ms: start)) --> \(srtTimestamp(ms: start + duration))\n\(event.text)")
            index += 1
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func srtTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let milliseconds = ms % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    // MARK: - Caption track discovery (YouTube's "timedtext" endpoints)

    // Matches the shape of `timedtext?...&fmt=json3` — a flat list of
    // "events", each optionally carrying one or more text segments and
    // (for actual caption lines, as opposed to pure positioning events)
    // a start time + duration in milliseconds.
    private struct CaptionJSON3: Decodable {
        struct Event: Decodable {
            struct Segment: Decodable {
                let utf8: String?
            }
            let tStartMs: Int?
            let dDurationMs: Int?
            let segs: [Segment]?
        }
        let events: [Event]?
    }

    private struct CaptionTrackInfo {
        let languageCode: String
        let name: String
        let isAutoGenerated: Bool
        let baseURL: URL
    }

    // A plain, realistic desktop UA for the watch-page HTML fetch below
    // — the only one of these three requests that seemed to care about
    // looking like a real browser during `curl` testing (the INNERTUBE
    // POST and the caption fetch itself worked fine even with curl's own
    // default UA).
    private static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    // Step 1: YouTube's own watch-page HTML embeds its current
    // `INNERTUBE_API_KEY` (a public, non-account-specific key — not a
    // secret, just required as a query parameter on the API call below).
    private static func fetchInnertubeAPIKey(videoID: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""INNERTUBE_API_KEY":"([a-zA-Z0-9_-]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let keyRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[keyRange])
    }

    // Step 2: a fresh player response via YouTube's internal
    // `/youtubei/v1/player` API, specifically using the ANDROID client
    // context (the same trick `youtube-transcript-api` uses) — this
    // returns full caption track data (including a ready-to-fetch,
    // pre-signed `baseUrl` per track) even when the currently-loaded
    // web page's own embedded state doesn't have it.
    private struct InnertubePlayerResponse: Decodable {
        struct Captions: Decodable {
            struct TracklistRenderer: Decodable {
                let captionTracks: [CaptionTrackJSON]?
            }
            let playerCaptionsTracklistRenderer: TracklistRenderer?
        }
        let captions: Captions?
    }

    private struct CaptionTrackJSON: Decodable {
        struct Name: Decodable {
            struct Run: Decodable { let text: String }
            let runs: [Run]?
        }
        let baseUrl: String
        let languageCode: String
        let kind: String?
        let name: Name?
    }

    private static func fetchCaptionTracks(videoID: String, apiKey: String) async -> [CaptionTrackInfo]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38"]],
            "videoId": videoID
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(InnertubePlayerResponse.self, from: data),
              let rawTracks = response.captions?.playerCaptionsTracklistRenderer?.captionTracks else {
            return nil
        }

        return rawTracks.compactMap { track in
            guard let baseURL = URL(string: track.baseUrl) else { return nil }
            return CaptionTrackInfo(
                languageCode: track.languageCode,
                name: track.name?.runs?.first?.text ?? "",
                isAutoGenerated: track.kind == "asr",
                baseURL: baseURL
            )
        }
    }

    // Prefers a manually-created track (usually cleaner than
    // auto-generated) in English, then any manual track, then whatever's
    // first (typically the auto-generated one) — a reasonable default
    // given there's no per-track picker here.
    private static func bestTrack(from tracks: [CaptionTrackInfo]) -> CaptionTrackInfo? {
        let manual = tracks.filter { !$0.isAutoGenerated }
        return manual.first { $0.languageCode == "en" } ?? manual.first ?? tracks.first
    }

    // Step 3's URL comes back already signed and complete (with
    // `&fmt=srv3` by default) — just swap the format for the
    // easier-to-parse structured JSON, rather than building the URL
    // from scratch the way the dead discovery endpoint required.
    private static func withJSON3Format(_ url: URL) -> URL {
        var urlString = url.absoluteString
        if urlString.contains("fmt=srv3") {
            urlString = urlString.replacingOccurrences(of: "fmt=srv3", with: "fmt=json3")
        } else if !urlString.contains("fmt=") {
            urlString += (urlString.contains("?") ? "&" : "?") + "fmt=json3"
        }
        return URL(string: urlString) ?? url
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

// Reports fractional download progress for `URLSession.download(for:
// delegate:)` — `didWriteData` is called throughout the download,
// independent of the async call's own return (which still resolves
// normally once the transfer finishes; this delegate has nothing to do
// there beyond satisfying the protocol's required method).
// Drives one download via a dedicated `URLSession` + classic delegate
// callbacks, bridged back to async/await with a continuation — the
// older, thoroughly battle-tested pattern for tracking download
// progress, used here instead of the newer `URLSession.download(for:
// delegate:)` convenience API (tried first) since that gave no visible
// progress in practice. `didFinishDownloadingTo` must move the file
// itself: the temp location it's handed is deleted the moment that
// method returns.
private final class DownloadTaskCoordinator: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func start(request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [onProgress] in
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let movedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: movedURL)
            continuation?.resume(returning: movedURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
