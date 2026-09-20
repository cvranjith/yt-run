//
//  LockedView.swift
//  YTRun
//

import SwiftUI
import Combine

struct LockedView: View {
    // `@EnvironmentObject` reads a shared instance placed into the
    // environment further up the view hierarchy (see ContentView) instead
    // of being passed in explicitly — handy once several unrelated screens
    // all need the same shared state.
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var usageTracker: UsageTracker
    @EnvironmentObject var walkModeManager: WalkModeManager
    // The YouTube screen hides the native back button throughout (see
    // `YouTubeView`'s own custom Home button), and this view replaces
    // that screen's content entirely while locked — so without this,
    // being locked leaves no way back to Home/Settings at all except
    // force-quitting the app.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if usageTracker.isInCooldown {
                cooldownMessage
            } else if usageTracker.isDailyLimitReached(dailyLimitMinutes: settings.dailyLimitMinutes) {
                Text("You've used today's YouTube allowance.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            // A run either ends an active cooldown early, or tops up the
            // daily allowance — never both from the same run. See
            // `UsageTracker.completeRun`.
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Home")

                NavigationLink("Start a Run") {
                    RunView()
                }
                .buttonStyle(.borderedProminent)
            }

            // Hidden unless explicitly turned on in Settings (same
            // friction-by-design reasoning as "Simulate Run" below, just
            // for a real feature rather than a testing bypass) — a live
            // gate, not a reward: tapping this unlocks the YouTube
            // screen immediately, for as long as `walkModeManager`'s
            // periodic checks keep finding you moving. Nothing banked,
            // nothing saved — see that class's own comments.
            if settings.enableWalkOption {
                Button("Walk (listen while moving)") {
                    walkModeManager.start()
                }
                .buttonStyle(.bordered)
            }

            // Hidden unless explicitly turned on in Settings — this
            // bypasses the actual run (no GPS/distance/duration check at
            // all), which defeats the entire point of the app if it's
            // always sitting right here as an easy way out. Requiring a
            // trip to Settings first adds enough friction that it's a
            // deliberate choice, not a one-tap bypass, while still being
            // available for legitimately testing the reward flow.
            //
            // Auto-disables itself the moment it's used (turning the
            // Settings toggle back off), so that friction is per-use, not
            // just per-session — using it again means going back to
            // Settings and turning it on again, rather than it just
            // sitting here armed indefinitely once switched on.
            if settings.enableSimulateRun {
                Button(simulateRunLabel) {
                    usageTracker.completeRun(minutes: settings.minutesPerRun)
                    settings.enableSimulateRun = false
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Nothing else on this screen is actively "playing," so without
        // this timer an expired cooldown would never get noticed — the
        // screen would stay stuck showing Locked even after the wait is
        // over.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            usageTracker.refreshBingeState(bingeResetAfterMinutes: settings.bingeResetAfterMinutes)
        }
    }

    private var simulateRunLabel: String {
        usageTracker.isInCooldown ? "Simulate Run (ends cooldown)" : "Simulate Run (+\(settings.minutesPerRun) min)"
    }

    @ViewBuilder
    private var cooldownMessage: some View {
        Text("Binge limit reached (\(settings.bingeLimitMinutes) min). Taking a forced break.")
            .font(.headline)
            .multilineTextAlignment(.center)

        if let cooldownEndsAt = usageTracker.cooldownEndsAt {
            Text("You can watch again at \(cooldownEndsAt, style: .time)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(cooldownEndsAt, style: .relative)
                .font(.title2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    LockedView()
        .environmentObject(AppSettings())
        .environmentObject(UsageTracker())
        .environmentObject(WalkModeManager())
}
