//
//  YouTubeOEmbed.swift
//  YTRun
//

import Foundation

// One video's title/channel, as YouTube's public oEmbed endpoint
// reports them — no API key, no quota, works for any public video URL.
struct YouTubeOEmbedInfo {
    let title: String?
    let authorName: String?
}

// Shared by CloudSyncService and DailyDetailView (resolving missing
// title/channel for on-screen display and before a cloud push) and
// YouTubeView (resolving the current video's channel for category
// classification and recording, when the in-page DOM scrape — see
// `YouTubeWebViewStore`'s `pageInfoJS` — hasn't produced one yet, or
// never does for a short visit). Deterministic where the live scrape
// isn't: it's a server-side lookup keyed by URL, not dependent on the
// page having actually rendered the channel element in time.
enum YouTubeOEmbed {
    static func fetchInfo(for videoURLString: String) async -> YouTubeOEmbedInfo? {
        guard
            var components = URLComponents(string: "https://www.youtube.com/oembed"),
            !videoURLString.isEmpty
        else { return nil }

        components.queryItems = [
            URLQueryItem(name: "url", value: videoURLString),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let requestURL = components.url else { return nil }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 8

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(OEmbedResponse.self, from: data)
        else { return nil }

        return YouTubeOEmbedInfo(title: decoded.title, authorName: decoded.author_name)
    }

    // Thin convenience for the couple of call sites that only ever
    // wanted the title.
    static func fetchTitle(for videoURLString: String) async -> String? {
        await fetchInfo(for: videoURLString)?.title
    }

    private struct OEmbedResponse: Decodable {
        let title: String?
        let author_name: String?
    }
}
