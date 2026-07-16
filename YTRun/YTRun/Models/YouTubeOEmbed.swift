//
//  YouTubeOEmbed.swift
//  YTRun
//

import Foundation

// YouTube's public oEmbed endpoint — no API key, no quota, works for any
// public video URL. Shared by CloudSyncService (resolving titles before a
// cloud push) and Daily History (resolving titles for on-screen display).
enum YouTubeOEmbed {
    static func fetchTitle(for videoURLString: String) async -> String? {
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

        return decoded.title
    }

    private struct OEmbedResponse: Decodable {
        let title: String
    }
}
