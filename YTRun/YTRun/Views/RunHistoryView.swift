//
//  RunHistoryView.swift
//  YTRun
//

import SwiftUI
import SwiftData

struct RunHistoryView: View {
    // `@Query` is SwiftData's live-updating fetch — this array automatically
    // refreshes whenever a `RunRecord` is inserted/deleted anywhere in the
    // app, no manual reload needed.
    @Query(sort: \RunRecord.date, order: .reverse) private var runs: [RunRecord]

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if runs.isEmpty {
                ContentUnavailableView(
                    "No Runs Yet",
                    systemImage: "figure.run",
                    description: Text("Finish a run to see it here, with your route on a map.")
                )
            } else {
                ForEach(runs) { run in
                    NavigationLink {
                        RunDetailView(run: run)
                    } label: {
                        RunRow(run: run)
                    }
                }
                // Standard iOS swipe-to-delete — SwiftData picks up the
                // deletion automatically since `runs` is a live `@Query`.
                .onDelete(perform: deleteRuns)
            }
        }
        .navigationTitle("Run History")
    }

    private func deleteRuns(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(runs[index])
        }
    }
}

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.name)
                    .font(.headline)
                Spacer()
                if run.qualified {
                    Label("Qualified", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
            Text(run.date, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(
                    format: "%.2f km · %d:%02d · %.0f kcal",
                    run.distanceMeters / 1000,
                    run.durationSeconds / 60,
                    run.durationSeconds % 60,
                    run.estimatedCalories
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        RunHistoryView()
    }
    .modelContainer(for: RunRecord.self, inMemory: true)
}
