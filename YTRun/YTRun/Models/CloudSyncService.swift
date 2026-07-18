//
//  CloudSyncService.swift
//  YTRun
//

import Foundation
import SwiftData
import Combine

// Pushes watch history to the same OCI Object Storage bucket (via a
// Pre-Authenticated Request URL) used by the `screentime` and
// `we-gym-with-w` projects, under its own `fit/ytrun/` prefix — following
// the same convention: one JSON file per day
// (`fit/ytrun/data/<date>.json`), plus a maintained
// `fit/ytrun/data/index.json` listing which dates exist, so a future
// reader doesn't need to list the bucket.
//
// NOTE: the PAR is scoped to only permit object names starting with
// "fit/" (confirmed against `we-gym-with-w`'s own `PFX = "fit/"` — a
// `ytrun/`-only prefix gets a 401 "PAR does not exist" from OCI), hence
// nesting under `fit/` rather than using `ytrun/` as a top-level prefix.
//
// Triggered implicitly on app-foreground events (see `ContentView`,
// `YouTubeView`) rather than on any kind of OS-scheduled background
// timer — iOS background tasks don't run on a reliable clock, so "every
// hour" isn't actually achievable, but "whenever the app is actually
// open" is, and `daysNeedingSync` already re-syncs any day since the
// last successful sync (tracked via `lastSyncAt`, in UserDefaults), so a
// missed day (app not opened yesterday) catches up automatically on the
// next sync. A manual "Sync to Cloud" button remains available too.
//
// The PAR itself grants write access to anyone who has it, so it lives in
// Secrets.swift (gitignored, not committed) rather than here — see
// Secrets.swift.example for the template.
@MainActor
final class CloudSyncService: ObservableObject {
    private static let parBase = Secrets.ociParBase
    private static let prefix = "fit/ytrun/data/"

    private static let lastSyncAtKey = "cloudSync.lastSyncAt"

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncSummary: String?
    @Published private(set) var lastSyncError: String?

    init() {
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncAtKey) as? Date
    }

    // MARK: - Public entry point

    func sync(modelContext: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let allSegments = try modelContext.fetch(FetchDescriptor<WatchSegment>())

            await resolveMissingTitles(in: allSegments)
            // Save the resolved titles before uploading, so the JSON we
            // push actually includes them.
            try modelContext.save()

            let days = daysNeedingSync(from: allSegments)
            var videoCount = 0

            for day in days.sorted() {
                let daySegments = allSegments.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                videoCount += try await pushDay(day, segments: daySegments)
            }

            if !days.isEmpty {
                try await updateIndex(with: days)
            }

            // Best-effort, like title resolution — a failed debug push
            // shouldn't fail the whole sync.
            await pushDebugLogIfNeeded()

            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncAtKey)
            lastSyncSummary = days.isEmpty
                ? "Already up to date."
                : "Synced \(days.count) day\(days.count == 1 ? "" : "s"), \(videoCount) video\(videoCount == 1 ? "" : "s")."
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: - Title resolution

    // Fills in `videoTitle` for any segment missing it, via YouTube's
    // public oEmbed endpoint (no API key, no quota — works for any public
    // video URL). Resolves each unique URL once and applies it to every
    // segment sharing that URL. Failures are silent per-video — a title
    // just stays nil, it doesn't fail the whole sync.
    private func resolveMissingTitles(in segments: [WatchSegment]) async {
        let missing = segments.filter { $0.videoTitle == nil && $0.videoURL != nil }
        let uniqueURLs = Set(missing.compactMap(\.videoURL))
        guard !uniqueURLs.isEmpty else { return }

        var resolved: [String: String] = [:]
        for urlString in uniqueURLs {
            if let title = await YouTubeOEmbed.fetchTitle(for: urlString) {
                resolved[urlString] = title
            }
        }
        guard !resolved.isEmpty else { return }

        for segment in missing {
            if let url = segment.videoURL, let title = resolved[url] {
                segment.videoTitle = title
            }
        }
    }

    // MARK: - Day selection

    // Any calendar day with a segment dated on/after the last successful
    // sync gets re-pushed in full (each day's file is always a complete
    // overwrite, never a partial append) — simplest way to guarantee nothing
    // gets missed after skipping a day or more, without tracking per-segment
    // sync state.
    private func daysNeedingSync(from segments: [WatchSegment]) -> [Date] {
        let calendar = Calendar.current
        let cutoff = lastSyncAt.map { calendar.startOfDay(for: $0) }
        let days = segments
            .map { calendar.startOfDay(for: $0.date) }
            .filter { cutoff == nil || $0 >= cutoff! }
        return Array(Set(days))
    }

    // MARK: - Debug log (temporary — see `ChannelScrapeDebugLog`)

    // Pushes the local channel-scrape-miss log to its own path (not under
    // `data/`, since it's not watch history) so it can be inspected
    // remotely without needing HTML manually relayed. Overwrites in full
    // each time — the local log is already capped, so this is always
    // small.
    private func pushDebugLogIfNeeded() async {
        let entries = ChannelScrapeDebugLog.load()
        guard !entries.isEmpty, let body = try? JSONEncoder().encode(entries) else { return }
        guard let url = URL(string: Self.parBase + "fit/ytrun/debug/channel-misses.json") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Upload

    @discardableResult
    private func pushDay(_ day: Date, segments: [WatchSegment]) async throws -> Int {
        let isoDate = Self.dayFormatter.string(from: day)
        let videos = segments.map { segment in
            VideoEntry(
                url: segment.videoURL,
                title: segment.videoTitle,
                channel: segment.channelName,
                isShorts: segment.isShorts,
                isBackground: segment.isBackground,
                isCarAudio: segment.isCarAudio,
                durationSeconds: segment.durationSeconds,
                startedAt: ISO8601DateFormatter().string(from: segment.date)
            )
        }
        let payload = DayPayload(date: isoDate, videos: videos)
        let body = try JSONEncoder().encode(payload)
        try await put(path: "\(isoDate).json", body: body)
        return videos.count
    }

    private func updateIndex(with newDays: [Date]) async throws {
        var index = (try? await getIndex()) ?? []
        let newDateStrings = newDays.map { Self.dayFormatter.string(from: $0) }
        var changed = false
        for dateString in newDateStrings where !index.contains(dateString) {
            index.append(dateString)
            changed = true
        }
        guard changed else { return }
        index.sort()
        let body = try JSONEncoder().encode(index)
        try await put(path: "index.json", body: body)
    }

    private func getIndex() async throws -> [String] {
        let url = URL(string: Self.parBase + Self.prefix + "index.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func put(path: String, body: Data) async throws {
        let url = URL(string: Self.parBase + Self.prefix + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudSyncError.uploadFailed(path: path)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }()

    private struct VideoEntry: Codable {
        let url: String?
        let title: String?
        let channel: String?
        let isShorts: Bool
        let isBackground: Bool
        let isCarAudio: Bool
        let durationSeconds: Int
        let startedAt: String
    }

    private struct DayPayload: Codable {
        let date: String
        let videos: [VideoEntry]
    }

    enum CloudSyncError: LocalizedError {
        case uploadFailed(path: String)

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let path):
                return "Upload failed for \(path)"
            }
        }
    }
}
