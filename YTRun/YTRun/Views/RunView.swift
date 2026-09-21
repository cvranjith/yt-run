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
        let rewardSeconds: Int
        // Non-nil only when the run finished while locked out — the
        // reward went straight to `UsageTracker` instead of the ledger.
        // See `UsageTracker.isLockedOut`.
        let rewardOutcome: RunRewardOutcome?
        // Held directly (not re-queried) so Discard can delete exactly
        // the event this run inserted, when the reward went to the
        // Energy Ledger instead (`rewardOutcome == nil`).
        let ledgerEvent: LedgerEvent?
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

            Text("Every minute you run earns \(settings.secondsCreditPerRunMinute)s of viewing time — extends today's allowance right now if you're locked out, or banks to your Energy Ledger otherwise.")
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

            Text("Currently worth +\(currentRewardSeconds)s")
                .font(.footnote)
                .foregroundStyle(.secondary)

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

    private var currentRewardSeconds: Int {
        Int(Double(runTracker.elapsedSeconds) * Double(settings.secondsCreditPerRunMinute) / 60.0)
    }

    private func finishRun() {
        let distanceKm = runTracker.distanceKm
        let distanceMeters = runTracker.distanceMeters
        let elapsedSeconds = runTracker.elapsedSeconds
        let route = runTracker.routeCoordinates
        runTracker.stop()

        let rewardSeconds = Int(Double(elapsedSeconds) * Double(settings.secondsCreditPerRunMinute) / 60.0)

        // Rough calorie estimate: roughly 1 kcal burnt per kg of body
        // weight per km covered — a commonly cited approximation for
        // running. No heart-rate/incline data, so treat it as a ballpark.
        let estimatedCalories = settings.weightKg * distanceKm
        let finishedAt = Date()
        let distanceText = String(format: "%.2f km", distanceKm)

        let outcome: RunRewardOutcome?
        var ledgerEvent: LedgerEvent?
        if usageTracker.isLockedOut(dailyLimitMinutes: settings.dailyLimitMinutes) {
            outcome = usageTracker.completeExerciseReward(seconds: rewardSeconds)
        } else {
            outcome = nil
            let event = LedgerEvent(date: finishedAt, seconds: rewardSeconds, note: "\(distanceText) run")
            modelContext.insert(event)
            ledgerEvent = event
        }

        pendingRun = PendingRun(
            finishedAt: finishedAt,
            distanceMeters: distanceMeters,
            durationSeconds: elapsedSeconds,
            route: route,
            estimatedCalories: estimatedCalories,
            rewardSeconds: rewardSeconds,
            rewardOutcome: outcome,
            ledgerEvent: ledgerEvent
        )
        runName = finishedAt.formatted(date: .abbreviated, time: .shortened)

        let minutesText = "\(elapsedSeconds / 60) min"
        switch outcome {
        case .grantedDailyMinutes:
            resultMessage = "Nice run! \(distanceText) in \(minutesText).\n+\(rewardSeconds)s added to today's allowance."
        case .clearedCooldown:
            resultMessage = "Nice run! \(distanceText) in \(minutesText).\nBinge cooldown cleared — no extra daily minutes needed."
        case nil:
            resultMessage = "Nice run! \(distanceText) in \(minutesText).\n+\(rewardSeconds)s banked to your Energy Ledger."
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
            qualified: true,
            routeCoordinates: pendingRun.route.map { RunCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        )
        modelContext.insert(record)
    }

    // Throws the run away instead of saving it — undoes whichever side
    // the reward actually went to, so a discarded run really does behave
    // as if it never happened: claws back daily bonus seconds if it
    // extended today's allowance, or deletes the `LedgerEvent` if it
    // banked to the ledger instead. If it cleared a cooldown, there's
    // nothing to undo (see `UsageTracker.revokeBonusSeconds`).
    private func discardPendingRun() {
        guard let pendingRun else { return }
        if pendingRun.rewardOutcome == .grantedDailyMinutes {
            usageTracker.revokeBonusSeconds(pendingRun.rewardSeconds)
        } else if let ledgerEvent = pendingRun.ledgerEvent {
            modelContext.delete(ledgerEvent)
        }
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
    .modelContainer(for: [RunRecord.self, LedgerEvent.self], inMemory: true)
}
