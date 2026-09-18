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

enum AIGatewayDownloadKind: String {
    case video, audio
}

struct AIGatewayDownloadInfo {
    let title: String
    let ext: String
    let url: URL
    let filesize: Int?
}

enum MacDeployStatus: String {
    case idle, running, success, failed
}

struct MacDeployStatusInfo {
    let status: MacDeployStatus
    let logTail: String?
}

enum AIGatewayError: Error {
    case notConfigured
    case invalidURL
    case network(Error)
    case unauthorized
    case server(String)
    case decoding
    case cancelled

    var message: String {
        switch self {
        case .notConfigured:
            return "Set the AI Gateway URL in Settings, plus either a Token or a Client ID/Secret."
        case .invalidURL:
            return "The AI Gateway URL in Settings doesn't look valid."
        case .network(let error):
            return "Couldn't reach the AI Gateway: \(error.localizedDescription)"
        case .unauthorized:
            return "The AI Gateway rejected these credentials — check the Token or Client ID/Secret in Settings."
        case .server(let message):
            return message
        case .decoding:
            return "Got an unexpected response from the AI Gateway."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

// Talks to either of two backends, chosen by which credentials are
// filled in in Settings — same `aiGatewayURI` field either way, since
// it's just "whichever backend you're currently pointed at":
//
// - Client ID + Secret set (and no Token): the original path, straight
//   to a self-hosted ai-gateway (see that project's own README) via
//   its OAuth2 Client Credentials flow, then POST /invoke with
//   service_id "youtube_summarizer"/"youtube_download". The bearer
//   token here is cached in memory only (never persisted to disk) and
//   refreshed a little ahead of its stated expiry.
// - Token set: routes through ai-router (a Cloudflare Worker in front
//   of ai-gateway and, eventually, other backends) instead — POST
//   /v1/invoke with service "local.codex", sent as
//   `Authorization: Bearer <token>` with no exchange step at all: this
//   token is a plain static shared secret, not an OAuth token, so
//   there's nothing to cache or refresh here.
//
// Downloads follow the same branch as Summarize — Token set means both
// features route through ai-router (as "local.codex" and
// "local.download" respectively); otherwise both go straight to
// ai-gateway. One credential set decides the backend for everything,
// so `aiGatewayURI` only ever needs to point at one place at a time.
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

        let result: Result<String, AIGatewayError>
        if Self.isTokenMode(settings) {
            result = await summarizeViaRouter(videoID: videoID, length: length, settings: settings)
        } else {
            result = await summarizeViaGateway(videoID: videoID, length: length, settings: settings)
        }

        if case .success(let summary) = result {
            if videoID != cachedVideoID {
                cachedVideoID = videoID
                cachedSummaries = [:]
            }
            cachedSummaries[length] = summary
        }
        return result
    }

    // Client ID/Secret path — OAuth2 to ai-gateway directly, unchanged
    // from before ai-router existed.
    private func summarizeViaGateway(
        videoID: String,
        length: AIGatewaySummaryLength,
        settings: AppSettings
    ) async -> Result<String, AIGatewayError> {
        guard Self.hasGatewayCredentials(settings), let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.gatewayConfigError(settings))
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
        return .success(summary)
    }

    // Token path — straight to ai-router with a static shared bearer
    // token, no exchange step. See ai-router's own README for the
    // { "service", "input", "options" } request shape and
    // { "service", "backend", "output", "ms" } response shape.
    private func summarizeViaRouter(
        videoID: String,
        length: AIGatewaySummaryLength,
        settings: AppSettings
    ) async -> Result<String, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(.invalidURL)
        }
        let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service": "local.codex",
            "input": videoID,
            "options": ["length": length.rawValue],
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
            return .failure(.unauthorized)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }

        guard (200...299).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }

        guard let output = json["output"] as? String else {
            return .failure(.decoding)
        }
        return .success(output)
    }

    // Resolves a direct, ready-to-download URL via the youtube_download
    // service (see ai-gateway's services/youtube_download.py) — no
    // video bytes pass through the gateway/router or this method; the
    // caller downloads `url` itself straight from YouTube's CDN, which
    // is what gives a normal URLSession download-progress callback for
    // free. Not cached (each resolved URL is signed/time-limited, so
    // there'd be little point).
    func resolveDownloadURL(
        videoID: String,
        kind: AIGatewayDownloadKind,
        settings: AppSettings
    ) async -> Result<AIGatewayDownloadInfo, AIGatewayError> {
        if Self.isTokenMode(settings) {
            return await resolveDownloadURLViaRouter(videoID: videoID, kind: kind, settings: settings)
        }
        return await resolveDownloadURLViaGateway(videoID: videoID, kind: kind, settings: settings)
    }

    // Client ID/Secret path — OAuth2 to ai-gateway directly, unchanged
    // from before ai-router existed.
    private func resolveDownloadURLViaGateway(
        videoID: String,
        kind: AIGatewayDownloadKind,
        settings: AppSettings
    ) async -> Result<AIGatewayDownloadInfo, AIGatewayError> {
        guard Self.hasGatewayCredentials(settings), let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.gatewayConfigError(settings))
        }

        let tokenResult = await token(baseURL: baseURL, settings: settings)
        guard case .success(let accessToken) = tokenResult else {
            if case .failure(let error) = tokenResult { return .failure(error) }
            return .failure(.decoding)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("invoke"))
        request.httpMethod = "POST"
        // "audio" can mean a server-side ffmpeg extraction step against
        // ai-gateway's youtube_download service (see that project's own
        // comments on why) that can run well past URLSession's default
        // 60s request timeout for a longer video — this call needs
        // however long that takes, and cancelling the enclosing Task
        // (see YouTubeView's Cancel button) aborts it promptly anyway.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service_id": "youtube_download",
            "params": ["video_id": videoID, "kind": kind.rawValue],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                return .failure(.cancelled)
            }
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }

        if http.statusCode == 401 {
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

        guard let result = json["result"] as? [String: Any] else {
            return .failure(.decoding)
        }
        return Self.downloadInfo(from: result, baseURL: baseURL)
    }

    // Token path — straight to ai-router, "local.download" service.
    // Same request/response envelope as summarizeViaRouter, except
    // `output` here is the nested title/ext/url/filesize object instead
    // of a plain string.
    private func resolveDownloadURLViaRouter(
        videoID: String,
        kind: AIGatewayDownloadKind,
        settings: AppSettings
    ) async -> Result<AIGatewayDownloadInfo, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(.invalidURL)
        }
        let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
        request.httpMethod = "POST"
        // See the matching comment in resolveDownloadURLViaGateway —
        // "audio" can take a while server-side.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service": "local.download",
            "input": videoID,
            "options": ["kind": kind.rawValue],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                return .failure(.cancelled)
            }
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }

        if http.statusCode == 401 {
            return .failure(.unauthorized)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }

        guard (200...299).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }

        guard let output = json["output"] as? [String: Any] else {
            return .failure(.decoding)
        }
        // ai-router already resolves "local.download"'s audio path to an
        // absolute URL itself (it knows its own AI_GATEWAY_URL), but
        // resolving here too is harmless and keeps this call site
        // symmetric with the direct-gateway one above.
        return Self.downloadInfo(from: output, baseURL: baseURL)
    }

    // `result["url"]` is either already absolute (the "video" kind's
    // direct YouTube CDN URL) or a path relative to `baseURL` (the
    // "audio" kind's server-extracted file — see ai-gateway's
    // services/youtube_download.py for why). `URL(string:relativeTo:)`
    // handles both the same way: an absolute string ignores
    // `relativeTo` entirely, so there's no need to branch on which case
    // this is.
    private static func downloadInfo(from result: [String: Any], baseURL: URL) -> Result<AIGatewayDownloadInfo, AIGatewayError> {
        guard let urlString = result["url"] as? String,
              let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL,
              let ext = result["ext"] as? String else {
            return .failure(.decoding)
        }
        return .success(AIGatewayDownloadInfo(
            title: result["title"] as? String ?? "Video",
            ext: ext,
            url: url,
            filesize: result["filesize"] as? Int
        ))
    }

    // Used by Settings' "Test Connection" — just proves the configured
    // credentials actually work, without spending a real summarize/
    // download call. Tests whichever path is currently configured.
    func testConnection(settings: AppSettings) async -> Result<Void, AIGatewayError> {
        if Self.isTokenMode(settings) {
            return await testRouterConnection(settings: settings)
        }
        guard Self.hasGatewayCredentials(settings), let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.gatewayConfigError(settings))
        }
        switch await token(baseURL: baseURL, settings: settings) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    // No dedicated health-check endpoint on ai-router — instead, sends
    // a deliberately unknown service ID and reads the *shape* of the
    // rejection: 401 means the token itself was rejected (bad token);
    // a 400 "unknown_service" means the token was accepted and this
    // got as far as service routing, i.e. the token is good. Avoids
    // spending a real local.codex call just to test credentials.
    private func testRouterConnection(settings: AppSettings) async -> Result<Void, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(.invalidURL)
        }
        let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["service": "__ping__"])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }
        if http.statusCode == 401 { return .failure(.unauthorized) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }
        if http.statusCode == 400, (json["error"] as? String) == "unknown_service" {
            return .success(())
        }
        return .failure(.server((json["error"] as? String) ?? "Unexpected response (\(http.statusCode))."))
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

    // Whether Summarize and Downloads should route through ai-router (a
    // Token is set) rather than ai-gateway directly. Token takes
    // priority if both happen to be filled in.
    private static func isTokenMode(_ settings: AppSettings) -> Bool {
        !settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasGatewayCredentials(_ settings: AppSettings) -> Bool {
        !settings.aiGatewayClientID.isEmpty && !settings.aiGatewayClientSecret.isEmpty
    }

    private static func gatewayConfigError(_ settings: AppSettings) -> AIGatewayError {
        let missingCredentials = settings.aiGatewayURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !hasGatewayCredentials(settings)
        return missingCredentials ? .notConfigured : .invalidURL
    }

    // Only checks the URL itself — which credentials are required
    // beyond that depends on which path the caller is taking (Token
    // for ai-router, Client ID/Secret for ai-gateway directly), each
    // checked separately by that caller.
    private static func baseURL(from settings: AppSettings) -> URL? {
        var trimmed = settings.aiGatewayURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Tolerate a trailing slash so "https://host/gateway/" and
        // "https://host/gateway" both work the same.
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    // MARK: - Mac deploy (self-update)
    //
    // Lets the app trigger a real rebuild+reinstall of itself onto this
    // device via ai-gateway's mac_deploy service — see that project's
    // own comments for why this is three quick actions rather than one
    // long-blocking call: a real deploy is a multi-minute clean build,
    // and holding a single HTTP request open that long through
    // Cloudflare's edge (when routed via ai-router) isn't something to
    // rely on. "startDeploy" kicks it off and returns immediately;
    // callers poll `deployStatus` on their own timer.

    func macWifiSSID(settings: AppSettings) async -> Result<String?, AIGatewayError> {
        switch await callDeployAction("wifi_status", settings: settings) {
        case .success(let json):
            return .success(json["ssid"] as? String)
        case .failure(let error):
            return .failure(error)
        }
    }

    func startDeploy(settings: AppSettings) async -> Result<Void, AIGatewayError> {
        switch await callDeployAction("start_deploy", settings: settings) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func deployStatus(settings: AppSettings) async -> Result<MacDeployStatusInfo, AIGatewayError> {
        switch await callDeployAction("deploy_status", settings: settings) {
        case .success(let json):
            let status = MacDeployStatus(rawValue: (json["status"] as? String) ?? "") ?? .idle
            return .success(MacDeployStatusInfo(status: status, logTail: json["log_tail"] as? String))
        case .failure(let error):
            return .failure(error)
        }
    }

    // Shared by all three calls above — unlike summarize/download,
    // every mac_deploy response is just a flat, small JSON object, so
    // there's no need for per-action response parsing beyond unwrapping
    // whichever envelope ("output" from ai-router, "result" from
    // ai-gateway directly) the call came back in.
    private func callDeployAction(_ action: String, settings: AppSettings) async -> Result<[String: Any], AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.gatewayConfigError(settings))
        }

        var request: URLRequest
        if Self.isTokenMode(settings) {
            let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
            request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "service": "local.deploy",
                "options": ["action": action],
            ])
        } else {
            guard Self.hasGatewayCredentials(settings) else {
                return .failure(Self.gatewayConfigError(settings))
            }
            let tokenResult = await token(baseURL: baseURL, settings: settings)
            guard case .success(let accessToken) = tokenResult else {
                if case .failure(let error) = tokenResult { return .failure(error) }
                return .failure(.decoding)
            }
            request = URLRequest(url: baseURL.appendingPathComponent("invoke"))
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "service_id": "mac_deploy",
                "params": ["action": action],
            ])
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

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
        if http.statusCode == 401 { return .failure(.unauthorized) }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }

        return .success((json["output"] as? [String: Any]) ?? (json["result"] as? [String: Any]) ?? json)
    }
}
