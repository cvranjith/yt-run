//
//  ChannelCategory.swift
//  YTRun
//

import Foundation
import SwiftData

// A topic tag (e.g. "AI", "Tech", "News", "Comedy", "Malayalam Film")
// per *channel*, not per video or per `WatchSegment` — reassigning one
// instantly applies to every past and future segment from that channel
// with no backfill needed, and it's unaffected by `WatchSegment.hide()`
// wiping `channelName` on hidden entries (those already fall back to
// "Unknown"/"Uncategorized" the same way `DailyDetailView`'s existing
// channel breakdown does). There's no separate list of known
// categories to maintain — the distinct `category` values already in
// this table (plus a small seed set on first use) are the whole
// vocabulary. See `ChannelCategoryResolver` for how entries get here.
@Model
final class ChannelCategory {
    var channelName: String
    var category: String
    var classifiedAt: Date

    init(channelName: String, category: String, classifiedAt: Date = .now) {
        self.channelName = channelName
        self.category = category
        self.classifiedAt = classifiedAt
    }
}
