//
//  UsageBreakdownView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Today's watch time split two ways — by hour of day, and by video
// category (resolved per segment via the channel-name cache; see
// `ChannelCategory`/`ChannelCategoryResolver`). A plain `@Query`-based
// view rather than routed through `EnergyLedgerManager`, since this is
// watch-side data with no ledger math involved — same two aggregation
// idioms `DailyDetailView` already uses (filter+reduce for the hour
// totals, dictionary-accumulate-then-sort for the category split).
struct UsageBreakdownView: View {
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager
    @Query(sort: \WatchSegment.date) private var allSegments: [WatchSegment]
    @Query private var categories: [ChannelCategory]

    private var todaySegments: [WatchSegment] {
        allSegments.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var categoryByChannel: [String: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.channelName, $0.category) })
    }

    private var totalSeconds: Int {
        todaySegments.reduce(0) { $0 + $1.durationSeconds }
    }

    private var hourBreakdown: [(hour: Int, seconds: Int)] {
        var totals: [Int: Int] = [:]
        for segment in todaySegments {
            let hour = Calendar.current.component(.hour, from: segment.date)
            totals[hour, default: 0] += segment.durationSeconds
        }
        return totals.map { (hour: $0.key, seconds: $0.value) }.sorted { $0.hour < $1.hour }
    }

    private var categoryBreakdown: [(category: String, seconds: Int)] {
        var totals: [String: Int] = [:]
        for segment in todaySegments {
            let category = segment.channelName.flatMap { categoryByChannel[$0] } ?? "Uncategorized"
            totals[category, default: 0] += segment.durationSeconds
        }
        return totals
            .map { (category: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        List {
            Section {
                ForEach(hourBreakdown, id: \.hour) { entry in
                    HStack {
                        Text(hourLabel(entry.hour))
                        Spacer()
                        Text("\(entry.seconds / 60) min")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("By Time of Day")
            }

            Section {
                ForEach(categoryBreakdown, id: \.category) { entry in
                    HStack {
                        Text(entry.category)
                        Spacer()
                        Text("\(entry.seconds / 60) min")
                            .foregroundStyle(.secondary)
                        if totalSeconds > 0 {
                            Text("(\(Int((Double(entry.seconds) / Double(totalSeconds)) * 100))%)")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("By Category")
            } footer: {
                Text("Categories are guessed automatically per channel the first time it's watched — tap the badge while watching to correct one.")
            }

            if energyLedgerManager.todayLateNightPenaltySeconds < 0 {
                Section {
                    HStack {
                        Text("Late-night penalty")
                        Spacer()
                        Text("\(energyLedgerManager.todayLateNightPenaltySeconds / 60) min")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("An extra deduction for watching during the configured late-night hours — on top of the watched time above, not instead of it.")
                }
            }

            Section {
                HStack {
                    Text("Total watched today")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(totalSeconds / 60) min")
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Total spent (incl. penalty)")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\((totalSeconds - energyLedgerManager.todayLateNightPenaltySeconds) / 60) min")
                        .fontWeight(.semibold)
                }
            }
        }
        .navigationTitle("Usage Today")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hourLabel(_ hour: Int) -> String {
        func formatted(_ h: Int) -> String {
            let period = h < 12 ? "AM" : "PM"
            let displayHour = h % 12 == 0 ? 12 : h % 12
            return "\(displayHour) \(period)"
        }
        return "\(formatted(hour)) – \(formatted((hour + 1) % 24))"
    }
}

#Preview {
    NavigationStack {
        UsageBreakdownView()
    }
    .environmentObject(EnergyLedgerManager())
    .modelContainer(for: [WatchSegment.self, ChannelCategory.self], inMemory: true)
}
