//
//  DaySummaryView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Thin loader that hands one day's segments/runs to `DailyDetailView` —
// the same view `DailyHistoryView` pushes per row, just reusable for an
// arbitrary date (the Home dashboard's "Videos" tile, for whichever day
// is currently selected there) without needing its own query logic.
struct DaySummaryView: View {
    let date: Date

    @Query(sort: \WatchSegment.date) private var allSegments: [WatchSegment]
    @Query(sort: \RunRecord.date) private var allRuns: [RunRecord]

    var body: some View {
        let calendar = Calendar.current
        DailyDetailView(
            day: date,
            segments: allSegments.filter { calendar.isDate($0.date, inSameDayAs: date) },
            runs: allRuns.filter { calendar.isDate($0.date, inSameDayAs: date) }
        )
    }
}

#Preview {
    NavigationStack {
        DaySummaryView(date: Date())
    }
    .environmentObject(YouTubeWebViewStore())
    .modelContainer(for: [WatchSegment.self, RunRecord.self, ChannelCategory.self], inMemory: true)
}
