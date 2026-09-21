//
//  DailyDetailView.swift
//  YTRun
//

import SwiftUI
import SwiftData

struct DailyDetailView: View {
    let day: Date
    let segments: [WatchSegment]
    let runs: [RunRecord]

    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [ChannelCategory]
    @State private var pendingHide: VideoSummary?

    private var categoryByChannel: [String: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.channelName, $0.category) })
    }

    private var totalSeconds: Int { segments.reduce(0) { $0 + $1.durationSeconds } }
    private var viewSeconds: Int { segments.filter { !$0.isBackground }.reduce(0) { $0 + $1.durationSeconds } }
    private var listenSeconds: Int { segments.filter { $0.isBackground && !$0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }
    private var carSeconds: Int { segments.filter { $0.isBackground && $0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }
    private var shortsSeconds: Int { segments.filter { $0.isShorts }.reduce(0) { $0 + $1.durationSeconds } }
    private var videoSeconds: Int { segments.filter { !$0.isShorts }.reduce(0) { $0 + $1.durationSeconds } }

    // Sums each channel's watched seconds across the day's segments,
    // ranked by most-watched first. Segments with no detected channel are
    // grouped under "Unknown".
    private var channelBreakdown: [(name: String, seconds: Int)] {
        var totals: [String: Int] = [:]
        for segment in segments {
            totals[segment.channelName ?? "Unknown", default: 0] += segment.durationSeconds
        }
        return totals
            .map { (name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    // Segments get split whenever view/listen/car/Shorts/channel state
    // changes mid-video, so the same video can appear as several segments
    // in a row — this collapses them back into one entry per video (by
    // URL) with total watched time, for a "what did I actually watch"
    // list. Segments with no captured URL (older data, or a scrape miss)
    // are kept as their own individual rows rather than merged together,
    // since lumping unrelated videos under one "Unknown" total would be
    // misleading. Hidden (redacted) segments are the opposite — they're
    // deliberately indistinguishable from each other, so they're all
    // merged into a single "Hidden" row instead of showing several
    // identical-looking rows with no way to tell them apart anyway.
    private var videoSummaries: [VideoSummary] {
        var grouped: [String: [WatchSegment]] = [:]
        for segment in segments {
            let key: String
            if segment.isHidden {
                key = "hidden"
            } else {
                key = segment.videoURL ?? "no-url-\(ObjectIdentifier(segment).hashValue)"
            }
            grouped[key, default: []].append(segment)
        }
        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            return VideoSummary(
                id: first.isHidden ? "hidden" : (first.videoURL ?? "no-url-\(ObjectIdentifier(first).hashValue)"),
                title: first.isHidden ? "Hidden video" : first.videoTitle,
                channel: first.isHidden ? nil : first.channelName,
                isShorts: first.isHidden ? false : first.isShorts,
                totalSeconds: group.reduce(0) { $0 + $1.durationSeconds },
                lastWatched: group.map(\.date).max() ?? first.date,
                segments: group,
                isHidden: first.isHidden
            )
        }
        .sorted { $0.lastWatched > $1.lastWatched }
    }

    private struct VideoSummary: Identifiable {
        let id: String
        let title: String?
        let channel: String?
        let isShorts: Bool
        let totalSeconds: Int
        let lastWatched: Date
        let segments: [WatchSegment]
        let isHidden: Bool
    }

    var body: some View {
        List {
            Section {
                statRow("Total watched", formatMinutes(totalSeconds))
                statRow("View (screen on)", formatMinutes(viewSeconds))
                statRow("Listen (locked/background)", formatMinutes(listenSeconds))
                if carSeconds > 0 {
                    statRow("Car (locked, car audio)", formatMinutes(carSeconds))
                }
            } header: {
                Text("Totals")
            } footer: {
                Text("Car is detected via CarPlay, or a Bluetooth device name you set in Settings.")
            }

            if totalSeconds > 0 {
                Section {
                    statRow("Regular videos", formatMinutes(videoSeconds))
                    statRow("Shorts", formatMinutes(shortsSeconds))
                } header: {
                    Text("Content type")
                } footer: {
                    Text("Shorts detection is best-effort — rapid swiping between clips may not always be caught individually.")
                }

                Section {
                    CategoryPieChart(date: day)
                } header: {
                    Text("Category Mix")
                } footer: {
                    Text("Categories are guessed automatically per channel the first time it's watched — tap the badge in the YouTube screen while watching to correct one.")
                }
            }

            if !channelBreakdown.isEmpty {
                Section {
                    ForEach(channelBreakdown, id: \.name) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Text(formatMinutes(entry.seconds))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Channels")
                } footer: {
                    Text("Scraped from the page — may be missing or wrong if YouTube changes its layout.")
                }
            }

            if !runs.isEmpty {
                Section("Runs") {
                    ForEach(runs) { run in
                        NavigationLink {
                            RunDetailView(run: run)
                        } label: {
                            HStack {
                                Text(run.name)
                                Spacer()
                                Text(String(format: "%.2f km", run.distanceMeters / 1000))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !videoSummaries.isEmpty {
                Section {
                    ForEach(videoSummaries) { summary in
                        videoRow(summary)
                    }
                } header: {
                    Text("Videos")
                } footer: {
                    Text("Time shown is how long you watched, not the video's full length — YouTube doesn't expose that without a paid API. Tap a video for details.")
                }
            }
        }
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        // Titles are resolved lazily via oEmbed (no API key/quota) — only
        // worth doing when this specific day is actually being viewed,
        // rather than for all history up front.
        .task {
            await resolveMissingTitles()
        }
        .confirmationDialog(
            "Hide this video?",
            isPresented: Binding(get: { pendingHide != nil }, set: { if !$0 { pendingHide = nil } }),
            presenting: pendingHide
        ) { summary in
            Button("Hide Video", role: .destructive) {
                WatchSegment.hide(summary.segments)
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Permanently removes the title, link, and channel for this video. Watch time still counts toward your totals. This can't be undone.")
        }
    }

    private func videoRow(_ summary: VideoSummary) -> some View {
        NavigationLink {
            VideoDetailView(segments: summary.segments)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if summary.isHidden {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                    Text(summary.title ?? "Untitled video")
                        .lineLimit(2)
                        .foregroundStyle(summary.isHidden ? .secondary : .primary)
                    if summary.isShorts {
                        Text("Shorts")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.15), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
                HStack(spacing: 4) {
                    if let channel = summary.channel {
                        Text(channel)
                    }
                    Text("· Watched \(formatDuration(summary.totalSeconds))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let category = summary.channel.flatMap({ categoryByChannel[$0] }) {
                    Text(category)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !summary.isHidden {
                Button(role: .destructive) {
                    pendingHide = summary
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formatMinutes(_ seconds: Int) -> String {
        "\(seconds / 60) min"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return remaining == 0 ? "\(minutes) min" : "\(minutes)m \(remaining)s"
    }

    // Resolves title/channel for any of this day's videos missing either,
    // via YouTube's public oEmbed endpoint (no key/quota) — a missing
    // channel is usually the live in-page DOM scrape never catching up
    // during a short visit (see `YouTubeView`'s own live fallback for
    // new recordings; this catches anything recorded before that ran).
    // Mutating the segment directly updates the UI immediately —
    // SwiftData's @Model is Observable, so reading the property in
    // `body` already created the dependency.
    private func resolveMissingTitles() async {
        let missing = segments.filter { ($0.videoTitle == nil || $0.channelName == nil) && $0.videoURL != nil }
        let uniqueURLs = Set(missing.compactMap(\.videoURL))
        guard !uniqueURLs.isEmpty else { return }

        for urlString in uniqueURLs {
            guard let info = await YouTubeOEmbed.fetchInfo(for: urlString) else { continue }
            for segment in missing where segment.videoURL == urlString {
                if segment.videoTitle == nil { segment.videoTitle = info.title }
                if segment.channelName == nil { segment.channelName = info.authorName }
            }
        }
        try? modelContext.save()
    }
}

#Preview {
    NavigationStack {
        DailyDetailView(
            day: Date(),
            segments: [
                WatchSegment(date: Date(), durationSeconds: 600, isBackground: false, isCarAudio: false, isShorts: false, channelName: "Some Channel", videoURL: "https://m.youtube.com/watch?v=abc123"),
                WatchSegment(date: Date(), durationSeconds: 300, isBackground: true, isCarAudio: false, isShorts: false, channelName: "Some Channel", videoURL: "https://m.youtube.com/watch?v=abc123"),
                WatchSegment(date: Date(), durationSeconds: 240, isBackground: true, isCarAudio: true, isShorts: false, channelName: "Some Channel", videoURL: "https://m.youtube.com/watch?v=def456"),
                WatchSegment(date: Date(), durationSeconds: 180, isBackground: false, isCarAudio: false, isShorts: true, channelName: "Shorts Creator", videoURL: "https://m.youtube.com/shorts/xyz789")
            ],
            runs: []
        )
    }
    .environmentObject(YouTubeWebViewStore())
    .modelContainer(for: ChannelCategory.self, inMemory: true)
}
