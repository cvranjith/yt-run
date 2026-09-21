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

// Which backend "Summarize" uses. `ytRunGateway` is the original path
// (server-side transcript fetch + Codex, via ai-router). The other
// three call a provider's own API directly from the app, using the
// same client-side transcript fetch "View Captions" already relies on
// (see DownloadManager.fetchCaptionEvents) — no server involved for
// those at all, which is what lets someone other than the app's
// original owner use Summarize with just their own API key, no access
// to the home-hosted gateway needed.
enum AISummaryProvider: String, CaseIterable, Identifiable {
    case ytRunGateway, openAICompatible, gemini, claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytRunGateway: return "YTRun Gateway"
        case .openAICompatible: return "OpenAI (compatible)"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }
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
            return "This AI provider isn't fully configured yet — check its settings under AI Providers."
        case .invalidURL:
            return "That URL doesn't look valid — check it in Settings."
        case .network(let error):
            return "Couldn't reach the server: \(error.localizedDescription)"
        case .unauthorized:
            return "The request was rejected — check the token/API key in Settings."
        case .server(let message):
            return message
        case .decoding:
            return "Got an unexpected response."
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

    // `downloadManager` is only actually used for direct-provider
    // summaries (see below) — YTRun Gateway fetches its own transcript
    // server-side, same as always. Threaded through as a parameter
    // rather than AIGatewayClient owning a DownloadManager reference,
    // since the two are siblings (both owned/injected at ContentView),
    // not naturally one containing the other.
    func summarize(
        videoID: String,
        length: AIGatewaySummaryLength,
        settings: AppSettings,
        downloadManager: DownloadManager
    ) async -> Result<String, AIGatewayError> {
        if let cached = cachedSummary(videoID: videoID, length: length) {
            return .success(cached)
        }

        let result: Result<String, AIGatewayError>
        switch settings.defaultSummaryProvider {
        case .ytRunGateway:
            result = await performSummarize(videoID: videoID, length: length, settings: settings)
        case .openAICompatible, .gemini, .claude:
            result = await summarizeViaDirectProvider(
                videoID: videoID,
                length: length,
                provider: settings.defaultSummaryProvider,
                settings: settings,
                downloadManager: downloadManager
            )
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

    // MARK: - Direct-provider summarization (no server involved)
    //
    // Fetches the transcript client-side (the exact same path "View
    // Captions" already uses — see DownloadManager.fetchCaptionEvents)
    // and sends it straight to whichever provider's own API, using the
    // key/model configured for it. Same length-based instructions as
    // ai-gateway's own youtube_summarizer.py, kept in sync by hand so
    // output quality/behavior feels consistent regardless of which
    // path a given install is actually using.
    private static let lengthPrompts: [AIGatewaySummaryLength: String] = [
        .short: "Summarize the following YouTube video transcript in 2-3 concise sentences. Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
        .paragraph: "Summarize the following YouTube video transcript in a single well-organized paragraph (roughly 4-6 sentences) covering the main points. Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
        .detailed: "Write a detailed summary of the following YouTube video transcript, covering all the main points and key details across a few short paragraphs. Output only the summary itself, nothing else - no preamble, no headings, no quotes around it.",
    ]

    private func summarizeViaDirectProvider(
        videoID: String,
        length: AIGatewaySummaryLength,
        provider: AISummaryProvider,
        settings: AppSettings,
        downloadManager: DownloadManager
    ) async -> Result<String, AIGatewayError> {
        let events: [CaptionEvent]
        switch await downloadManager.fetchCaptionEvents(videoID: videoID) {
        case .success(let fetched): events = fetched
        case .failure(let error): return .failure(.server(error.message))
        }
        let transcript = DownloadManager.plainText(from: events).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return .failure(.server("No usable captions were found for this video."))
        }

        let instructions = (Self.lengthPrompts[length] ?? "") + " Write the summary in the same language as the transcript."

        switch provider {
        case .ytRunGateway:
            return .failure(.server("Unreachable - ytRunGateway doesn't use this path."))
        case .openAICompatible:
            return await callOpenAICompatible(instructions: instructions, transcript: transcript, settings: settings)
        case .gemini:
            return await callGemini(instructions: instructions, transcript: transcript, settings: settings)
        case .claude:
            return await callClaude(instructions: instructions, transcript: transcript, settings: settings)
        }
    }

    // OpenAI's Chat Completions API — also what Grok (genuinely OpenAI-
    // SDK-compatible) and any self-hosted compatible server speak, just
    // via a different base URL.
    private func callOpenAICompatible(instructions: String, transcript: String, settings: AppSettings) async -> Result<String, AIGatewayError> {
        var trimmedBase = settings.openAICompatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = settings.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !apiKey.isEmpty, !model.isEmpty else { return .failure(.notConfigured) }
        if trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        guard let baseURL = URL(string: trimmedBase) else { return .failure(.invalidURL) }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": transcript],
            ],
            "max_tokens": 1024,
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
        if http.statusCode == 401 { return .failure(.unauthorized) }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return .failure(.decoding)
        }
        return .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func callGemini(instructions: String, transcript: String, settings: AppSettings) async -> Result<String, AIGatewayError> {
        let apiKey = settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else { return .failure(.notConfigured) }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["parts": [["text": transcript]]]],
            "generationConfig": ["maxOutputTokens": 1024],
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
        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            return .failure(.decoding)
        }
        return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func callClaude(instructions: String, transcript: String, settings: AppSettings) async -> Result<String, AIGatewayError> {
        let apiKey = settings.claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else { return .failure(.notConfigured) }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": instructions,
            "messages": [["role": "user", "content": transcript]],
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
        if http.statusCode == 401 { return .failure(.unauthorized) }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            return .failure(.decoding)
        }
        return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // One-word video-category classification, for the per-channel
    // category cache (see `ChannelCategoryResolver`). Reuses the same
    // three direct-provider adapters `summarizeViaDirectProvider` calls —
    // they're already just "send instructions + arbitrary text, get text
    // back," nothing summarization-specific about them. Deliberately
    // never routed through `ytRunGateway` (that's a server-side Codex
    // service with no generic classify endpoint) or a new YouTube Data
    // API key (unused anywhere else in this app) — just whichever
    // already-configured direct provider is available, preferring the
    // one Summarize itself defaults to. Returns nil (not "Other") when no
    // provider is configured at all, so a guess is never cached that was
    // never actually made — it's retried once a key exists.
    func classifyChannelCategory(channelName: String, videoTitle: String?, knownCategories: [String], settings: AppSettings) async -> String? {
        guard let provider = Self.availableDirectProvider(settings: settings) else { return nil }

        let instructions = "You are tagging YouTube videos with a single short topic category, "
            + "for a personal watch-history report. Known categories so far: \(knownCategories.joined(separator: ", ")). "
            + "Reply with just the category name — reuse one of the known ones if it fits, invent a short new one (1-2 words) "
            + "if none fit well, or reply \"Other\" if you genuinely can't tell. No punctuation, no explanation."
        let content = "Channel: \(channelName)\nTitle: \(videoTitle ?? "(unknown)")"

        let result: Result<String, AIGatewayError>
        switch provider {
        case .openAICompatible:
            result = await callOpenAICompatible(instructions: instructions, transcript: content, settings: settings)
        case .gemini:
            result = await callGemini(instructions: instructions, transcript: content, settings: settings)
        case .claude:
            result = await callClaude(instructions: instructions, transcript: content, settings: settings)
        case .ytRunGateway:
            return nil
        }

        guard case .success(let raw) = result else { return nil }
        let category = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return category.isEmpty ? nil : category
    }

    private static func availableDirectProvider(settings: AppSettings) -> AISummaryProvider? {
        func hasKey(_ provider: AISummaryProvider) -> Bool {
            switch provider {
            case .openAICompatible: return !settings.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .gemini: return !settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .claude: return !settings.claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .ytRunGateway: return false
            }
        }
        if settings.defaultSummaryProvider != .ytRunGateway, hasKey(settings.defaultSummaryProvider) {
            return settings.defaultSummaryProvider
        }
        return [AISummaryProvider.claude, .gemini, .openAICompatible].first(where: hasKey)
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
