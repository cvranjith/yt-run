//
//  StairClimbView.swift
//  YTRun
//

import SwiftUI
import SwiftData

// Counts flights of stairs climbed (see StairClimbCounter) and, every
// `settings.floorsPerStairSet`, lets you claim `settings.secondsPerStairSet`
// of viewing/listening time — same banked-reward shape as
// ExerciseTrainingView's camera-tracked exercises, just a different
// unit (floors, not reps) and no camera involved at all.
struct StairClimbView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker
    @Environment(\.modelContext) private var modelContext
    @StateObject private var counter = StairClimbCounter()

    // Floors already "spent" on a claimed reward — same reasoning as
    // ExerciseTrainingView's `claimedRepCount`.
    @State private var claimedFloorCount = 0
    @State private var rewardMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.stairs")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("\(counter.floorsAscended)")
                .font(.system(size: 72, weight: .bold, design: .rounded))

            if !counter.isAvailable {
                Text("This device can't measure floors climbed (no barometer available).")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                rewardProgressView
            }

            HStack(spacing: 16) {
                Button("Reset") { resetAll() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .navigationTitle("Climb Stairs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { counter.start() }
        .onDisappear { counter.stop() }
        .alert("Climb Stairs", isPresented: Binding(
            get: { rewardMessage != nil },
            set: { if !$0 { rewardMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rewardMessage ?? "")
        }
    }

    private var unclaimedFloors: Int { max(0, counter.floorsAscended - claimedFloorCount) }
    private var floorsPerSet: Int { max(1, settings.floorsPerStairSet) }
    private var setsReadyToClaim: Int { unclaimedFloors / floorsPerSet }
    private var floorsIntoCurrentSet: Int { unclaimedFloors % floorsPerSet }

    @ViewBuilder
    private var rewardProgressView: some View {
        if setsReadyToClaim > 0 {
            Text("🎉 Ready to claim: +\(setsReadyToClaim * settings.secondsPerStairSet)s")
                .font(.headline)
                .foregroundStyle(.green)
            Button("Claim Reward") { claimReward() }
                .buttonStyle(.borderedProminent)
        } else {
            Text("\(floorsIntoCurrentSet)/\(floorsPerSet) floors for +\(settings.secondsPerStairSet)s")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(floorsIntoCurrentSet), total: Double(floorsPerSet))
                .frame(width: 160)
                .tint(.green)
        }
    }

    private func claimReward() {
        let sets = setsReadyToClaim
        guard sets > 0 else { return }
        let seconds = sets * settings.secondsPerStairSet
        claimedFloorCount += sets * floorsPerSet
        if usageTracker.isLockedOut(dailyLimitMinutes: settings.dailyLimitMinutes) {
            switch usageTracker.completeExerciseReward(seconds: seconds) {
            case .grantedDailyMinutes:
                rewardMessage = "+\(seconds) seconds added to today's allowance!"
            case .clearedCooldown:
                rewardMessage = "Cooldown cleared — no extra time needed right now."
            }
            // Zero seconds — see ExerciseTrainingView.claimReward()'s
            // identical reasoning.
            modelContext.insert(LedgerEvent(date: .now, seconds: 0, note: "\(sets * floorsPerSet) floors climbed — used to unlock directly", source: .stairs))
        } else {
            modelContext.insert(LedgerEvent(date: .now, seconds: seconds, note: "\(sets * floorsPerSet) floors climbed", source: .stairs))
            rewardMessage = "+\(seconds) seconds banked to your Energy Ledger."
        }
    }

    private func resetAll() {
        counter.reset()
        claimedFloorCount = 0
    }
}

#Preview {
    NavigationStack {
        StairClimbView()
    }
    .environmentObject(AppSettings())
    .environmentObject(UsageTracker())
}
