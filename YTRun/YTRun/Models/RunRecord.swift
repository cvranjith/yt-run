//
//  RunRecord.swift
//  YTRun
//

import Foundation
import SwiftData

// A single GPS point along a run's route. `CLLocationCoordinate2D` itself
// isn't `Codable`, so we mirror just the two numbers we need — SwiftData
// can store an array of a simple Codable struct like this directly on a
// model.
struct RunCoordinate: Codable {
    var latitude: Double
    var longitude: Double
}

// `@Model` is SwiftData's way of marking a class as persisted — think of
// it as Core Data's modern replacement. SwiftData auto-generates the
// storage/fetching machinery; we just describe the shape of the data.
// Once `.modelContainer(for: RunRecord.self)` is attached in `YTRunApp`,
// any view can read/write these via `@Query` / `@Environment(\.modelContext)`.
@Model
final class RunRecord {
    var name: String
    var date: Date
    var distanceMeters: Double
    var durationSeconds: Int
    var estimatedCalories: Double
    var qualified: Bool
    var routeCoordinates: [RunCoordinate]

    init(
        name: String,
        date: Date,
        distanceMeters: Double,
        durationSeconds: Int,
        estimatedCalories: Double,
        qualified: Bool,
        routeCoordinates: [RunCoordinate]
    ) {
        self.name = name
        self.date = date
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.estimatedCalories = estimatedCalories
        self.qualified = qualified
        self.routeCoordinates = routeCoordinates
    }
}
