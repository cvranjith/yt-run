//
//  WatchSegment.swift
//  YTRun
//

import Foundation
import SwiftData

// One continuous stretch of watching/listening with consistent
// characteristics (same watch-vs-listen mode, same Shorts-vs-video, same
// channel, same video). A single viewing session gets split into multiple
// segments whenever any of those change — e.g. locking the phone mid-video
// closes a "watch" segment and opens a "listen" one. Daily/weekly reports
// are built by aggregating these, grouped by day.
@Model
final class WatchSegment {
    var date: Date
    var durationSeconds: Int

    // `true` while the app was backgrounded (phone locked, or switched to
    // another app) but audio kept playing — see `WatchHistoryRecorder`.
    var isBackground: Bool

    // `true` if the audio was routed to a car connection (CarPlay, or a
    // Bluetooth device matching Settings' configured car device name)
    // *while* `isBackground` was also true. Only meaningful alongside
    // `isBackground` — Daily History reads a background segment as
    // "Car" if this is set, "Listen" otherwise.
    var isCarAudio: Bool = false

    var isShorts: Bool

    // Best-effort scrape of the channel name from the page — may be nil
    // if YouTube's page structure didn't match what we look for.
    var channelName: String?

    // The video's URL at the time this segment was recorded.
    var videoURL: String?

    // Resolved lazily (via YouTube's oEmbed endpoint) at cloud-sync time,
    // not at record time — keeps the real-time recording path free of
    // network calls. Cached here once resolved so later syncs don't
    // re-fetch it.
    var videoTitle: String?

    // `true` once the user has explicitly redacted this video from
    // history (e.g. watched something they don't want a record of). The
    // segment itself is kept — and still counts toward daily/binge
    // totals — but `videoURL`/`videoTitle`/`channelName` are wiped and
    // never re-populated. See `WatchSegment.hide(_:)`.
    var isHidden: Bool = false

    init(
        date: Date,
        durationSeconds: Int,
        isBackground: Bool,
        isCarAudio: Bool,
        isShorts: Bool,
        channelName: String?,
        videoURL: String?,
        isHidden: Bool = false
    ) {
        self.date = date
        self.durationSeconds = durationSeconds
        self.isBackground = isBackground
        self.isCarAudio = isCarAudio
        self.isShorts = isShorts
        self.channelName = channelName
        self.videoURL = videoURL
        self.videoTitle = nil
        self.isHidden = isHidden
    }

    // Permanently strips identifying info from every segment belonging to
    // one video (they were split across several stretches if the phone
    // was locked/unlocked mid-watch) — irreversible by design, since the
    // whole point is "don't keep a record of what this was." Duration and
    // view/listen/car/Shorts flags are left alone so daily totals stay
    // accurate.
    static func hide(_ group: [WatchSegment]) {
        for segment in group {
            segment.videoURL = nil
            segment.videoTitle = nil
            segment.channelName = nil
            segment.isHidden = true
        }
    }
}
