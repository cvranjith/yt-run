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

struct MacWifiInfo {
    let ssid: String?
    let ip: String?
    // The definitive answer to "will a deploy actually reach a device
    // right now" — ai-gateway runs the same devicectl pairing check
    // install_to_device.sh itself uses to find a device, rather than
    // this just being inferred from Wi-Fi. `ssid`/`ip` are purely
    // informational at that point, for telling the user which network
    // to switch to when this is false because of that.
    let proceedOK: Bool
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
            return "Set the YTRun Gateway URL and Token in Settings."
        case .invalidURL:
            return "The YTRun Gateway URL in Settings doesn't look valid."
        case .network(let error):
            return "Couldn't reach the YTRun Gateway: \(error.localizedDescription)"
        case .unauthorized:
            return "The YTRun Gateway rejected this token — check it in Settings."
        case .server(let message):
            return message
        case .decoding:
            return "Got an unexpected response from the YTRun Gateway."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

// Talks to ai-router (a Cloudflare Worker in front of the self-hosted
// ai-gateway, branded "YTRun Gateway" in Settings/UI since it also
// powers Downloads, not just AI features) via a single static shared
// bearer token — see ai-router's own README for the { "service",
// "input", "options" } request shape and { "service", "backend",
// "output", "ms" } response shape. No OAuth2/Client-ID-Secret path
// anymore — an earlier version supported calling a self-hosted
// ai-gateway directly that way, but ai-router became the only path
// actually used, so that branch (and the Settings fields for it) was
// removed rather than carried along unused.
final class AIGatewayClient: ObservableObject {
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

        let result = await performSummarize(videoID: videoID, length: length, settings: settings)

        if case .success(let summary) = result {
            if videoID != cachedVideoID {
                cachedVideoID = videoID
                cachedSummaries = [:]
            }
            cachedSummaries[length] = summary
        }
        return result
    }

    private func performSummarize(
        videoID: String,
        length: AIGatewaySummaryLength,
        settings: AppSettings
    ) async -> Result<String, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
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
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
        }
        let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
        request.httpMethod = "POST"
        // "audio" can mean a server-side ffmpeg extraction step against
        // ai-gateway's youtube_download service (see that project's own
        // comments on why) that can run well past URLSession's default
        // 60s request timeout for a longer video — this call needs
        // however long that takes, and cancelling the enclosing Task
        // (see YouTubeView's Cancel button) aborts it promptly anyway.
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
    // token actually works, without spending a real summarize/download
    // call. No dedicated health-check endpoint on ai-router — instead,
    // sends a deliberately unknown service ID and reads the *shape* of
    // the rejection: 401 means the token itself was rejected (bad
    // token); a 400 "unknown_service" means the token was accepted and
    // this got as far as service routing, i.e. the token is good.
    func testConnection(settings: AppSettings) async -> Result<Void, AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
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

    private static func configError(_ settings: AppSettings) -> AIGatewayError {
        let uriEmpty = settings.aiGatewayURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tokenEmpty = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (uriEmpty || tokenEmpty) ? .notConfigured : .invalidURL
    }

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
    // Cloudflare's edge isn't something to rely on. "startDeploy" kicks
    // it off and returns immediately; callers poll `deployStatus` on
    // their own timer.

    func macWifiStatus(settings: AppSettings) async -> Result<MacWifiInfo, AIGatewayError> {
        switch await callDeployAction("wifi_status", settings: settings) {
        case .success(let json):
            return .success(MacWifiInfo(
                ssid: json["ssid"] as? String,
                ip: json["ip"] as? String,
                proceedOK: json["proceed_ok"] as? Bool ?? false
            ))
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

    // Every mac_deploy response is just a flat, small JSON object, so
    // there's no need for per-action response parsing beyond
    // unwrapping ai-router's "output" envelope.
    private func callDeployAction(_ action: String, settings: AppSettings) async -> Result<[String: Any], AIGatewayError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(Self.configError(settings))
        }
        let token = settings.aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service": "local.deploy",
            "options": ["action": action],
        ])
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

        return .success((json["output"] as? [String: Any]) ?? json)
    }
}
