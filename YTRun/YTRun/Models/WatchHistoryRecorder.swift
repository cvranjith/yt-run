//
//  WatchHistoryRecorder.swift
//  YTRun
//

import Foundation
import SwiftData
import Combine

// Accumulates the currently-playing segment's duration and persists it as
// a `WatchSegment` whenever its characteristics change (watch↔listen,
// car↔non-car, Shorts↔video, channel, or video URL) or playback stops.
// Deliberately lightweight — it only needs to survive for as long as the
// YouTube screen is visible; each finished segment is immediately written
// to SwiftData, which is the actual source of truth for history.
@MainActor
final class WatchHistoryRecorder: ObservableObject {
    private var segmentStart: Date?
    private var accumulatedSeconds = 0
    private var currentIsBackground = false
    private var currentIsCarAudio = false
    private var currentIsShorts = false
    private var currentChannelName: String?
    private var currentVideoURL: String?

    // Called once per second while a video is actually playing.
    func tick(
        isBackground: Bool,
        isCarAudio: Bool,
        isShorts: Bool,
        channelName: String?,
        videoURL: String?,
        modelContext: ModelContext
    ) {
        if segmentStart == nil {
            startSegment(isBackground: isBackground, isCarAudio: isCarAudio, isShorts: isShorts, channelName: channelName, videoURL: videoURL)
        } else if isBackground != currentIsBackground
            || isCarAudio != currentIsCarAudio
            || isShorts != currentIsShorts
            || channelName != currentChannelName
            || videoURL != currentVideoURL {
            flush(modelContext: modelContext)
            startSegment(isBackground: isBackground, isCarAudio: isCarAudio, isShorts: isShorts, channelName: channelName, videoURL: videoURL)
        }
        accumulatedSeconds += 1
    }

    private func startSegment(isBackground: Bool, isCarAudio: Bool, isShorts: Bool, channelName: String?, videoURL: String?) {
        segmentStart = Date()
        accumulatedSeconds = 0
        currentIsBackground = isBackground
        currentIsCarAudio = isCarAudio
        currentIsShorts = isShorts
        currentChannelName = channelName
        currentVideoURL = videoURL
    }

    // Persists the in-progress segment, if any, and clears it. Call when
    // playback stops/pauses or the screen disappears so a partial segment
    // isn't silently dropped.
    func flush(modelContext: ModelContext) {
        defer {
            segmentStart = nil
            accumulatedSeconds = 0
        }
        guard let segmentStart, accumulatedSeconds > 0 else { return }

        let segment = WatchSegment(
            date: segmentStart,
            durationSeconds: accumulatedSeconds,
            isBackground: currentIsBackground,
            isCarAudio: currentIsCarAudio,
            isShorts: currentIsShorts,
            channelName: currentChannelName,
            videoURL: currentVideoURL
        )
        modelContext.insert(segment)
    }
}
