//
//  RunTracker.swift
//  YTRun
//

import Foundation
import CoreLocation
import Combine
import ActivityKit

// Tracks a single run in progress using the phone's GPS, entirely on-device
// — no third-party fitness service involved. Distance is accumulated by
// summing the straight-line distance between consecutive GPS fixes, which
// is exactly what CoreLocation-based run trackers do under the hood.
@MainActor
final class RunTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var elapsedSeconds: Int = 0

    // Every accepted GPS fix along the way, for drawing the route on a map
    // afterward (see `RunRecord`/`RunDetailView`).
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []

    // Surfaces "run has GPS but you haven't granted 'Always' access" so
    // the UI can explain why tracking might stop when the phone locks.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var startDate: Date?
    private var timer: Timer?

    // The Lock Screen / Dynamic Island Live Activity for this run, if the
    // system granted one (the user may have Live Activities disabled).
    private var liveActivity: Activity<RunActivityAttributes>?

    var distanceKm: Double { distanceMeters / 1000 }

    override init() {
        self.authorizationStatus = CLLocationManager().authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        // Mirrors the background-audio setup for YouTube playback: without
        // this, GPS updates (and therefore distance tracking) pause the
        // moment the phone locks.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        distanceMeters = 0
        elapsedSeconds = 0
        routeCoordinates = []
        lastLocation = nil
        startDate = Date()
        isTracking = true

        // Requesting "Always" (rather than "When In Use") is what allows
        // `allowsBackgroundLocationUpdates` above to actually work once the
        // phone locks. iOS handles the staged prompts (When In Use, then
        // an upgrade offer to Always) on its own.
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        startLiveActivity()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startDate = self.startDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startDate))
                await self.updateLiveActivity()
            }
        }
    }

    func stop() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        Task { await endLiveActivity() }
    }

    // MARK: Live Activity

    // Starting a Live Activity can fail (e.g. the user disabled them in
    // Settings) — that's fine, it's a nice-to-have on top of tracking,
    // never something the run itself depends on.
    private func startLiveActivity() {
        let attributes = RunActivityAttributes(startedAt: startDate ?? Date())
        let initialState = RunActivityAttributes.ContentState(distanceMeters: 0, elapsedSeconds: 0)
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil)
            )
        } catch {
            print("Live Activity failed to start: \(error)")
        }
    }

    private func updateLiveActivity() async {
        guard let liveActivity else { return }
        let state = RunActivityAttributes.ContentState(distanceMeters: distanceMeters, elapsedSeconds: elapsedSeconds)
        await liveActivity.update(.init(state: state, staleDate: nil))
    }

    private func endLiveActivity() async {
        guard let liveActivity else { return }
        let finalState = RunActivityAttributes.ContentState(distanceMeters: distanceMeters, elapsedSeconds: elapsedSeconds)
        // `.default` leaves the ended activity visible for a while (iOS
        // decides how long, often up to a few hours) showing its final
        // state — fine for "final score" style activities, but this
        // should disappear the moment the run stops, hence `.immediate`.
        await liveActivity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        self.liveActivity = nil
    }
}

extension RunTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                // Filter out low-quality fixes (large horizontalAccuracy)
                // so GPS noise doesn't inflate the distance total.
                guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 else { continue }

                if let last = self.lastLocation {
                    self.distanceMeters += location.distance(from: last)
                }
                self.lastLocation = location
                self.routeCoordinates.append(location.coordinate)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }
}
