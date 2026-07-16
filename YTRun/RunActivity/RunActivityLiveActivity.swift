//
//  RunActivityLiveActivity.swift
//  RunActivity
//
//  Created by Ranjith CV on 15/7/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct RunActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            // Lock Screen / banner UI.
            HStack(spacing: 14) {
                Image(systemName: "figure.run")
                    .font(.title2)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedDuration(context.state.elapsedSeconds))
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(formattedDistance(context.state.distanceMeters))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()
            }
            .foregroundStyle(.white)
            .padding()
            .activityBackgroundTint(Color(red: 0.75, green: 0.1, blue: 0.12))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(formattedDuration(context.state.elapsedSeconds), systemImage: "clock")
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(formattedDistance(context.state.distanceMeters))
                        .bold()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("YTRun · run in progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "figure.run")
            } compactTrailing: {
                Text(formattedDuration(context.state.elapsedSeconds))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "figure.run")
            }
        }
    }
}

private func formattedDuration(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func formattedDistance(_ meters: Double) -> String {
    String(format: "%.2f km", meters / 1000)
}

extension RunActivityAttributes {
    fileprivate static var preview: RunActivityAttributes {
        RunActivityAttributes(startedAt: Date())
    }
}

extension RunActivityAttributes.ContentState {
    fileprivate static var early: RunActivityAttributes.ContentState {
        RunActivityAttributes.ContentState(distanceMeters: 450, elapsedSeconds: 180)
    }

    fileprivate static var midRun: RunActivityAttributes.ContentState {
        RunActivityAttributes.ContentState(distanceMeters: 3200, elapsedSeconds: 1080)
    }
}

#Preview("Notification", as: .content, using: RunActivityAttributes.preview) {
   RunActivityLiveActivity()
} contentStates: {
    RunActivityAttributes.ContentState.early
    RunActivityAttributes.ContentState.midRun
}
