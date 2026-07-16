//
//  RunDetailView.swift
//  YTRun
//

import SwiftUI
import MapKit
import SwiftData

struct RunDetailView: View {
    let run: RunRecord

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // `@State` here because the map's camera is view-local, transient
    // presentation state — it has no reason to live in `RunRecord` itself.
    @State private var cameraPosition: MapCameraPosition = .automatic

    @State private var isShowingRenameAlert = false
    @State private var renameText = ""
    @State private var isShowingDeleteConfirmation = false

    private var coordinates: [CLLocationCoordinate2D] {
        run.routeCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if coordinates.count > 1 {
                    Map(position: $cameraPosition) {
                        MapPolyline(coordinates: coordinates)
                            .stroke(.blue, lineWidth: 4)
                    }
                    .frame(height: 260)
                    .onAppear {
                        cameraPosition = .region(fittingRegion(for: coordinates))
                    }
                } else {
                    ContentUnavailableView(
                        "No Route Recorded",
                        systemImage: "map",
                        description: Text("This run doesn't have enough GPS points to draw a map.")
                    )
                    .frame(height: 260)
                }

                VStack(spacing: 0) {
                    statRow("Distance", String(format: "%.2f km", run.distanceMeters / 1000))
                    Divider()
                    statRow("Duration", String(format: "%d:%02d", run.durationSeconds / 60, run.durationSeconds % 60))
                    Divider()
                    statRow("Calories (est.)", String(format: "%.0f kcal", run.estimatedCalories))
                    Divider()
                    statRow("Qualified for reward", run.qualified ? "Yes" : "No")
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(run.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        renameText = run.name
                        isShowingRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete Run", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Run", isPresented: $isShowingRenameAlert) {
            TextField("Run name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // `run` is a SwiftData model (reference type), so
                    // mutating this property directly updates the stored
                    // record — no separate save call needed.
                    run.name = trimmed
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this run?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(run)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    // Computes a map region that frames the whole route with a little
    // margin, so the saved run's path fills the map nicely instead of
    // defaulting to some arbitrary zoom level.
    private func fittingRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard
            let minLat = latitudes.min(), let maxLat = latitudes.max(),
            let minLon = longitudes.min(), let maxLon = longitudes.max()
        else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // 1.4x padding around the route's bounding box, with a floor so a
        // very short/tight run doesn't zoom in absurdly close.
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

#Preview {
    NavigationStack {
        RunDetailView(
            run: RunRecord(
                name: "Evening Run",
                date: Date(),
                distanceMeters: 5200,
                durationSeconds: 1800,
                estimatedCalories: 350,
                qualified: true,
                routeCoordinates: [
                    RunCoordinate(latitude: 37.3349, longitude: -122.0090),
                    RunCoordinate(latitude: 37.3352, longitude: -122.0075),
                    RunCoordinate(latitude: 37.3360, longitude: -122.0060)
                ]
            )
        )
    }
}
