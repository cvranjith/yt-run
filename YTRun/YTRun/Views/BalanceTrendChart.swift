//
//  BalanceTrendChart.swift
//  YTRun
//

import SwiftUI
import SwiftData
import Charts

// One bar per day in the Energy Ledger's rolling window, green above
// zero / red below — a red day's contribution to `balanceSeconds`
// simply ages out once it leaves the window, so there's no separate
// "carry the penalty forward" step to visualize beyond the bars
// themselves. Reads `EnergyLedgerManager.dailyNets` directly rather
// than recomputing anything.
struct BalanceTrendChart: View {
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager

    var body: some View {
        Chart(energyLedgerManager.dailyNets, id: \.day) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Minutes", entry.seconds / 60)
            )
            .foregroundStyle(entry.seconds >= 0 ? Color.green : Color.red)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 80)
    }
}

// A day's watch time split by video category (see `ChannelCategory`) —
// same dictionary-accumulate-then-sort shape as `UsageBreakdownView`'s
// `categoryBreakdown`, kept as its own small copy here rather than a
// shared abstraction, since a compact Home-screen chart and a full
// detail list have different enough display needs (colors/legend vs a
// plain list) that sharing would mean threading display options through
// one function anyway. Takes an explicit `date` (not always "today") so
// the Home dashboard's prev/next day navigation can show any day's mix.
struct CategoryPieChart: View {
    let date: Date

    @Query(sort: \WatchSegment.date) private var allSegments: [WatchSegment]
    @Query private var categories: [ChannelCategory]

    private var breakdown: [(category: String, seconds: Int)] {
        let dayOf = allSegments.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
        let categoryByChannel = Dictionary(uniqueKeysWithValues: categories.map { ($0.channelName, $0.category) })
        var totals: [String: Int] = [:]
        for segment in dayOf {
            let category = segment.channelName.flatMap { categoryByChannel[$0] } ?? "Uncategorized"
            totals[category, default: 0] += segment.durationSeconds
        }
        return totals.map { (category: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        if breakdown.isEmpty {
            Text("Nothing watched that day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            Chart(breakdown, id: \.category) { entry in
                SectorMark(angle: .value("Minutes", entry.seconds), innerRadius: .ratio(0.6))
                    .foregroundStyle(by: .value("Category", entry.category))
            }
            .frame(height: 140)
        }
    }
}
