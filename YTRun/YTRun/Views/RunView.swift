//
//  RunView.swift
//  YTRun
//

import SwiftUI
import CoreLocation
import SwiftData

struct RunView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker
    // Owned at the root (`ContentView`), not here — so a run in progress
    // survives navigating back to Home and pushing this screen again.
    // Without that, tapping "Start a Run" a second time created a brand
    // new tracker (and a second, orphaned Live Activity) instead of
    // showing the run that was already underway.
    @EnvironmentObject var runTracker: RunTracker
    @Environment(\.dismiss) private var dismiss

    // The SwiftData context this view saves finished runs into — supplied
    // automatically via `.modelContainer` back in `YTRunApp`.
    @Environment(\.modelContext) private var modelContext

    // Everything needed to save a `RunRecord`, captured the moment the run
    // finishes. Saving itself is deferred until "Save" is tapped on the
    // result screen, so the user can name the run first — but the reward
    // (see `finishRun`) is granted immediately, not deferred, so closing
    // the app before naming can't lose it.
    private struct PendingRun {
        let finishedAt: Date
        let distanceMeters: Double
        let durationSeconds: Int
        let route: [CLLocationCoordinate2D]
        let estimatedCalories: Double
        let qualified: Bool
        // What the reward actually did — nil if the run didn't qualify.
        // Only a `.grantedDailyMinutes` outcome has anything to undo on
        // Discard; see `UsageTracker.completeRun`.
        let rewardOutcome: RunRewardOutcome?
    }

    @State private var pendingRun: PendingRun?
    @State private var runName: String = ""

    // Set once a run finishes, so the screen can show a result instead of
    // immediately dismissing.
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            if runTracker.isTracking {
                trackingView
            } else if let resultMessage {
                resultView(resultMessage)
            } else {
                startView
            }
        }
        .padding()
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var startView: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Run at least \(qualifyingDistanceText) or \(settings.qualifyingDurationMinutes) min to earn +\(settings.minutesPerRun) min of viewing time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if runTracker.authorizationStatus == .denied || runTracker.authorizationStatus == .restricted {
                Text("Location access is off. Enable it in Settings → Privacy → Location Services → YTRun to track a run.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Start Run") {
                runTracker.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var trackingView: some View {
        VStack(spacing: 16) {
            Text(formattedDuration)
                .font(.system(size: 52, weight: .bold, design: .monospaced))
            Text(String(format: "%.2f km", runTracker.distanceKm))
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ProgressView(value: qualifyingProgress)
                    .tint(qualifyingProgress >= 1 ? .green : .accentColor)
                Text(
                    qualifyingProgress >= 1
                        ? "Qualified — finish anytime to bank +\(settings.minutesPerRun) min"
                        : "\(Int(qualifyingProgress * 100))% to qualifying (\(qualifyingDistanceText) or \(settings.qualifyingDurationMinutes) min)"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Button("Finish Run", role: .destructive) {
                finishRun()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func resultView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)

            TextField("Run name", text: $runName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)

            Button("Save") {
                savePendingRun()
                dismiss()
            }
            .buttonStyle(.borderedProminent)

            Button("Discard", role: .destructive) {
                discardPendingRun()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    // How close the in-progress run is to qualifying, as the better
    // (higher) of the two independent thresholds — matches the "meets
    // EITHER" qualifying rule, so getting close on either one shows
    // progress.
    private var qualifyingProgress: Double {
        let distanceProgress = settings.qualifyingDistanceKm > 0
            ? runTracker.distanceKm / settings.qualifyingDistanceKm
            : 0
        let durationProgress = settings.qualifyingDurationMinutes > 0
            ? Double(runTracker.elapsedSeconds) / Double(settings.qualifyingDurationMinutes * 60)
            : 0
        return min(1, max(distanceProgress, durationProgress))
    }

    private func finishRun() {
        let distanceKm = runTracker.distanceKm
        let distanceMeters = runTracker.distanceMeters
        let elapsedSeconds = runTracker.elapsedSeconds
        let route = runTracker.routeCoordinates
        runTracker.stop()

        let qualifiesByDistance = distanceKm >= settings.qualifyingDistanceKm
        let qualifiesByDuration = elapsedSeconds >= settings.qualifyingDurationMinutes * 60
        let qualifies = qualifiesByDistance || qualifiesByDuration

        // Rough calorie estimate: roughly 1 kcal burnt per kg of body
        // weight per km covered — a commonly cited approximation for
        // running. No heart-rate/incline data, so treat it as a ballpark.
        let estimatedCalories = settings.weightKg * distanceKm
        let finishedAt = Date()

        let outcome = qualifies ? usageTracker.completeRun(minutes: settings.minutesPerRun) : nil
        if qualifies, settings.enableEnergyLedger {
            modelContext.insert(LedgerEvent(date: finishedAt, seconds: settings.minutesPerRun * 60, note: "\(String(format: "%.2f km", distanceKm)) run"))
        }

        pendingRun = PendingRun(
            finishedAt: finishedAt,
            distanceMeters: distanceMeters,
            durationSeconds: elapsedSeconds,
            route: route,
            estimatedCalories: estimatedCalories,
            qualified: qualifies,
            rewardOutcome: outcome
        )
        runName = finishedAt.formatted(date: .abbreviated, time: .shortened)

        switch outcome {
        case .grantedDailyMinutes:
            resultMessage = "Nice run! \(String(format: "%.2f km", distanceKm)) in \(elapsedSeconds / 60) min.\n+\(settings.minutesPerRun) min added."
        case .clearedCooldown:
            resultMessage = "Nice run! \(String(format: "%.2f km", distanceKm)) in \(elapsedSeconds / 60) min.\nBinge cooldown cleared — no extra daily minutes needed."
        case nil:
            resultMessage = "Run \(qualifyingDistanceText) or \(settings.qualifyingDurationMinutes) min to qualify.\nThis run: \(String(format: "%.2f km", distanceKm)) in \(elapsedSeconds / 60) min — no reward this time."
        }
    }

    private func savePendingRun() {
        guard let pendingRun else { return }

        let trimmedName = runName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = RunRecord(
            name: trimmedName.isEmpty ? pendingRun.finishedAt.formatted(date: .abbreviated, time: .shortened) : trimmedName,
            date: pendingRun.finishedAt,
            distanceMeters: pendingRun.distanceMeters,
            durationSeconds: pendingRun.durationSeconds,
            estimatedCalories: pendingRun.estimatedCalories,
            qualified: pendingRun.qualified,
            routeCoordinates: pendingRun.route.map { RunCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        )
        modelContext.insert(record)
    }

    // Throws the run away instead of saving it — claws back any daily
    // bonus minutes it earned too, so a discarded run really does behave
    // as if it never happened. If the run instead cleared a cooldown,
    // there's nothing to undo (see `UsageTracker.revokeBonusMinutes`).
    private func discardPendingRun() {
        guard let pendingRun, pendingRun.rewardOutcome == .grantedDailyMinutes else { return }
        usageTracker.revokeBonusMinutes(settings.minutesPerRun)
    }

    private var qualifyingDistanceText: String {
        String(format: "%.1f km", settings.qualifyingDistanceKm)
    }

    private var formattedDuration: String {
        let minutes = runTracker.elapsedSeconds / 60
        let seconds = runTracker.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    NavigationStack {
        RunView()
    }
    .environmentObject(AppSettings())
    .environmentObject(UsageTracker())
    .environmentObject(RunTracker())
    .modelContainer(for: RunRecord.self, inMemory: true)
}
