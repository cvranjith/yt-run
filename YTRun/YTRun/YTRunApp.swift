//
//  YTRunApp.swift
//  YTRun
//
//  Created by Ranjith CV on 15/7/26.
//

import SwiftUI
import SwiftData

@main
struct YTRunApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Attaches a SwiftData store for these models to the whole view
        // hierarchy — any view below this can read/write via `@Query` and
        // `@Environment(\.modelContext)` without being handed anything
        // explicitly.
        .modelContainer(for: [RunRecord.self, WatchSegment.self, LedgerEvent.self])
    }
}
