//
//  DailyDetailView.swift
//  YTRun
//

import SwiftUI

struct DailyDetailView: View {
    let day: Date
    let segments: [WatchSegment]
    let runs: [RunRecord]

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
        }
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
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
}
