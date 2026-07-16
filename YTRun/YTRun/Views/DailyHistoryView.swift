//
//  DailyHistoryView.swift
//  YTRun
//

import SwiftUI
import SwiftData

struct DailyHistoryView: View {
    @Query(sort: \WatchSegment.date, order: .reverse) private var segments: [WatchSegment]
    @Query(sort: \RunRecord.date, order: .reverse) private var runs: [RunRecord]

    @Environment(\.modelContext) private var modelContext
    @StateObject private var cloudSync = CloudSyncService()

    // Every calendar day that has either watch history or a run, newest
    // first — the union is what makes a "day" worth showing in the list.
    private var days: [Date] {
        let calendar = Calendar.current
        let dayStarts = Set(segments.map { calendar.startOfDay(for: $0.date) })
            .union(runs.map { calendar.startOfDay(for: $0.date) })
        return dayStarts.sorted(by: >)
    }

    var body: some View {
        List {
            if let summary = cloudSync.lastSyncSummary {
                Section {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = cloudSync.lastSyncError {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if days.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "calendar",
                    description: Text("Days you watch YouTube or go for a run will show up here.")
                )
            } else {
                ForEach(days, id: \.self) { day in
                    let daySegments = segments(on: day)
                    let dayRuns = runs(on: day)
                    NavigationLink {
                        DailyDetailView(day: day, segments: daySegments, runs: dayRuns)
                    } label: {
                        DayRow(day: day, segments: daySegments, runs: dayRuns)
                    }
                }
            }
        }
        .navigationTitle("Daily History")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await cloudSync.sync(modelContext: modelContext) }
                } label: {
                    if cloudSync.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                }
                .disabled(cloudSync.isSyncing)
                .accessibilityLabel("Sync to Cloud")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let lastSyncAt = cloudSync.lastSyncAt {
                Text("Last synced \(lastSyncAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private func segments(on day: Date) -> [WatchSegment] {
        let calendar = Calendar.current
        return segments.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    private func runs(on day: Date) -> [RunRecord] {
        let calendar = Calendar.current
        return runs.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }
}

private struct DayRow: View {
    let day: Date
    let segments: [WatchSegment]
    let runs: [RunRecord]

    private var totalSeconds: Int { segments.reduce(0) { $0 + $1.durationSeconds } }
    private var viewSeconds: Int { segments.filter { !$0.isBackground }.reduce(0) { $0 + $1.durationSeconds } }
    private var listenSeconds: Int { segments.filter { $0.isBackground && !$0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }
    private var carSeconds: Int { segments.filter { $0.isBackground && $0.isCarAudio }.reduce(0) { $0 + $1.durationSeconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(day, style: .date)
                    .font(.headline)
                Spacer()
                if !runs.isEmpty {
                    Label("\(runs.count)", systemImage: "figure.run")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if totalSeconds > 0 {
                Text("\(totalSeconds / 60) min total · View \(viewSeconds / 60)m · Listen \(listenSeconds / 60)m\(carSeconds > 0 ? " · Car \(carSeconds / 60)m" : "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No YouTube watched")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        DailyHistoryView()
    }
    .modelContainer(for: [WatchSegment.self, RunRecord.self], inMemory: true)
}
