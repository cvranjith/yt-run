//
//  AIGatewayClient.swift
//  YTRun
//

import Foundation
import Combine

enum AIGatewaySummaryLength: String, CaseIterable, Identifiable {
    case short, paragraph, detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "Short"
        case .paragraph: return "Paragraph"
        case .detailed: return "Detailed"
        }
    }
}

enum AIGatewayError: Error {
    case notConfigured
    case invalidURL
    case network(Error)
    case unauthorized
    case server(String)
    case decoding

    var message: String {
        switch self {
        case .notConfigured:
            return "Set the AI Gateway URL, Client ID, and Client Secret in Settings first."
        case .invalidURL:
            return "The AI Gateway URL in Settings doesn't look valid."
        case .network(let error):
            return "Couldn't reach the AI Gateway: \(error.localizedDescription)"
        case .unauthorized:
            return "The AI Gateway rejected these credentials — check Client ID/Secret in Settings."
        case .server(let message):
            return message
        case .decoding:
            return "Got an unexpected response from the AI Gateway."
        }
    }
}

// Talks to a self-hosted ai-gateway (see that project's own README) —
// its OAuth2 Client Credentials flow, then its single POST /invoke
// endpoint with service_id "youtube_summarizer". The bearer token is
// cached in memory only (never persisted to disk) and refreshed a
// little ahead of its stated expiry, so summarizing several videos in
// one app session normally only needs one sign-in round trip.
final class AIGatewayClient: ObservableObject {
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?
    // Summaries are deterministic enough per (video, length) that
    // there's no reason to hit the gateway again for one already
    // fetched — closing and reopening the Summary sheet for the same
    // video, or switching the length picker back to one already seen,
    // should just come from here. Deliberately scoped to only the
    // *current* video (not a growing history of every video visited
    // this session) — navigating to another video and back should
    // just re-summarize, which avoids needing any cache eviction for
    // what's a lightweight, personal-use feature.
    private var cachedVideoID: String?
    private var cachedSummaries: [AIGatewaySummaryLength: String] = [:]

    // Synchronous, no network — lets a view check "do we already have
    // this?" (e.g. on appear, or right when the length picker changes)
    // without that check itself counting as "asking the server."
    func cachedSummary(videoID: String, length: AIGatewaySummaryLength) -> String? {
        guard videoID == cachedVideoID else { return nil }
        return cachedSummaries[length]
    }

    func summarize(
        videoID: String,
        length: AIGatewaySummaryLength,
        settings: AppSettings
    ) async -> Result<String, AIGatewayError> {
        if let cached = cachedSummary(videoID: videoID, length: length) {
            return .success(cached)
        }

        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
        }

        let tokenResult = await token(baseURL: baseURL, settings: settings)
        guard case .success(let accessToken) = tokenResult else {
            if case .failure(let error) = tokenResult { return .failure(error) }
            return .failure(.decoding)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("invoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service_id": "youtube_summarizer",
            "params": ["video_id": videoID, "length": length.rawValue],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }

        if http.statusCode == 401 {
            // The token was valid a moment ago but got rejected now —
            // most likely the gateway restarted with a fresh signing
            // secret. Drop the cache so the next attempt re-signs-in
            // rather than repeating the same now-dead token.
            cachedToken = nil
            cachedTokenExpiry = nil
            return .failure(.unauthorized)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }

        guard (200...299).contains(http.statusCode) else {
            return .failure(.server((json["error"] as? String) ?? "Request failed (\(http.statusCode))."))
        }

        guard let result = json["result"] as? [String: Any], let summary = result["summary"] as? String else {
            return .failure(.decoding)
        }
        if videoID != cachedVideoID {
            cachedVideoID = videoID
            cachedSummaries = [:]
        }
        cachedSummaries[length] = summary
        return .success(summary)
    }

    // Used by Settings' "Test Connection" — just proves the credentials
    // actually work, without spending an /invoke call on a real video.
    func testConnection(settings: AppSettings) async -> Result<Void, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
        }
        switch await token(baseURL: baseURL, settings: settings) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private func token(baseURL: URL, settings: AppSettings) async -> Result<String, AIGatewayError> {
        if let cachedToken, let cachedTokenExpiry, cachedTokenExpiry > Date() {
            return .success(cachedToken)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": settings.aiGatewayClientID,
            "client_secret": settings.aiGatewayClientSecret,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }

        if http.statusCode == 401 {
            return .failure(.unauthorized)
        }
        guard (200...299).contains(http.statusCode),
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "Sign-in failed."
            return .failure(.server(message))
        }

        cachedToken = accessToken
        // Refresh a little ahead of the real expiry rather than cutting
        // it exactly at the wire.
        cachedTokenExpiry = Date().addingTimeInterval(expiresIn - 30)
        return .success(accessToken)
    }

    private static func configError(_ settings: AppSettings) -> AIGatewayError {
        let missingCredentials = settings.aiGatewayURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.aiGatewayClientID.isEmpty
            || settings.aiGatewayClientSecret.isEmpty
        return missingCredentials ? .notConfigured : .invalidURL
    }

    private static func baseURL(from settings: AppSettings) -> URL? {
        var trimmed = settings.aiGatewayURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.aiGatewayClientID.isEmpty, !settings.aiGatewayClientSecret.isEmpty else {
            return nil
        }
        // Tolerate a trailing slash so "https://host/gateway/" and
        // "https://host/gateway" both work the same.
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }
}
