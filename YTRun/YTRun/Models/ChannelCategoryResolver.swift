//
//  ChannelCategoryResolver.swift
//  YTRun
//

import Foundation
import SwiftData

// Looks up (and, on a miss, classifies and caches) a channel's category
// — a thin helper over `ChannelCategory` and `AIGatewayClient`, not a
// full manager, since there's no state to own beyond what's already in
// SwiftData.
@MainActor
enum ChannelCategoryResolver {
    private static let seedCategories = ["AI", "Tech", "News", "Comedy", "Entertainment", "Music", "Other"]

    static func cachedCategory(channelName: String, modelContext: ModelContext) -> String? {
        let descriptor = FetchDescriptor<ChannelCategory>(
            predicate: #Predicate { $0.channelName == channelName }
        )
        return (try? modelContext.fetch(descriptor))?.first?.category
    }

    static func knownCategories(modelContext: ModelContext) -> [String] {
        let all = (try? modelContext.fetch(FetchDescriptor<ChannelCategory>())) ?? []
        let distinct = Set(all.map(\.category))
        return distinct.isEmpty ? seedCategories : Array(distinct).sorted()
    }

    // Returns `isFresh: true` only when this call is what actually
    // classified the channel for the first time — the caller uses that
    // to decide whether a "Categorized as…" toast is warranted, since a
    // plain cache hit should stay completely silent.
    static func resolve(
        channelName: String,
        videoTitle: String?,
        modelContext: ModelContext,
        aiGatewayClient: AIGatewayClient,
        settings: AppSettings
    ) async -> (category: String, isFresh: Bool)? {
        if let cached = cachedCategory(channelName: channelName, modelContext: modelContext) {
            return (cached, false)
        }
        let known = knownCategories(modelContext: modelContext)
        guard let category = await aiGatewayClient.classifyChannelCategory(
            channelName: channelName,
            videoTitle: videoTitle,
            knownCategories: known,
            settings: settings
        ) else {
            return nil
        }
        // Re-check the cache after the `await` — another concurrent
        // resolve for the same channel (e.g. a rapid video-to-video
        // channel repeat) could have already inserted one while this
        // classification was in flight.
        if let cached = cachedCategory(channelName: channelName, modelContext: modelContext) {
            return (cached, false)
        }
        modelContext.insert(ChannelCategory(channelName: channelName, category: category))
        return (category, true)
    }

    static func setCategory(_ category: String, forChannel channelName: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<ChannelCategory>(
            predicate: #Predicate { $0.channelName == channelName }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.category = category
            existing.classifiedAt = .now
        } else {
            modelContext.insert(ChannelCategory(channelName: channelName, category: category))
        }
    }
}
