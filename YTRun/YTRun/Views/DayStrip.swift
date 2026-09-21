//
//  DayStrip.swift
//  YTRun
//

import SwiftUI
import SwiftData
import Charts

// Five tappable day-squares — today plus the four before it — replacing
// an earlier Swift Charts bar chart whose weekday-axis labels never
// quite lined up with the bars underneath. Each square owns its label
// directly above it, so there's no separate axis to misalign, and
// doubles as the day picker: tapping one sets `selectedDate` directly
// instead of stepping through prev/next arrows. A day with no ledger
// data at all (older than `ledgerWindowDays`, or a `CMPedometer`
// retention limit) reads as gray rather than a misleading flat zero.
struct DayStrip: View {
    @EnvironmentObject var energyLedgerManager: EnergyLedgerManager
    @EnvironmentObject var settings: AppSettings
    @Binding var selectedDate: Date

    private static let dayCount = 5

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<Self.dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days, id: \.self) { day in
                dayButton(for: day)
            }
        }
    }

    private func dayButton(for day: Date) -> some View {
        let calendar = Calendar.current
        let stats = energyLedgerManager.stats(for: day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)

        return Button {
            selectedDate = day
        } label: {
            VStack(spacing: 6) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color(for: stats))
                    .frame(height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // Saturation scales with how far the day's net is from zero (capped
    // at the daily limit, a reasonably meaningful yardstick) so "barely
    // red" and "deep in debt" read differently at a glance.
    private func color(for stats: EnergyLedgerDayStats?) -> Color {
        guard let stats else { return Color.gray.opacity(0.2) }
        let capSeconds = Double(max(settings.dailyLimitMinutes, 1) * 60)
        let intensity = min(1.0, abs(Double(stats.netSeconds)) / capSeconds)
        let base: Color = stats.netSeconds >= 0 ? .green : .red
        return base.opacity(0.25 + 0.65 * intensity)
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
