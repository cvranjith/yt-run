//
//  RunActivityAttributes.swift
//  YTRun
//

import ActivityKit
import Foundation

// The data contract for the Lock Screen / Dynamic Island Live Activity
// shown while a run is in progress. This file must belong to BOTH the
// main app target (which starts/updates the activity from `RunTracker`)
// and the `RunActivity` widget extension target (which renders it) —
// they run as separate processes, so ActivityKit needs this exact type
// available to both sides to serialize/decode state across that boundary.
//
// NOTE: after creating this file, its Xcode File Inspector → Target
// Membership must have BOTH "YTRun" and "RunActivity" checked.
struct RunActivityAttributes: ActivityAttributes {
    // Fixed for the lifetime of the activity.
    var startedAt: Date

    // Updates live as the run progresses.
    public struct ContentState: Codable, Hashable {
        var distanceMeters: Double
        var elapsedSeconds: Int
    }
}
