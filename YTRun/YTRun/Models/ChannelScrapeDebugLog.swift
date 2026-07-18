//
//  ChannelScrapeDebugLog.swift
//  YTRun
//

import Foundation

// Temporary diagnostic aid for fixing channel-name scraping remotely.
// Channel extraction is best-effort CSS/microdata scraping (see
// `YouTubeWebViewStore.pageInfoJS`) that can silently start missing
// whenever YouTube changes its markup — with no way to see what the page
// actually looked like without this. Whenever extraction misses, a
// snippet of the relevant HTML is captured here, capped and rotated in
// UserDefaults, and pushed to the cloud alongside regular sync so it can
// be inspected without needing it manually relayed. Safe to delete
// entirely once channel scraping is reliable.
enum ChannelScrapeDebugLog {
    private static let key = "channelScrapeDebug.entries"
    private static let maxEntries = 30

    struct Entry: Codable {
        let capturedAt: Date
        let url: String
        let html: String
    }

    static func record(url: String, html: String) {
        var entries = load()
        // Skip back-to-back captures for the same URL — the periodic
        // poll in `pageInfoJS` would otherwise spam near-identical
        // entries while sitting on one video.
        if entries.last?.url == url { return }
        entries.append(Entry(capturedAt: Date(), url: url, html: html))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        save(entries)
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
