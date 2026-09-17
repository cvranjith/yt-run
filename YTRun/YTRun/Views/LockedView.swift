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
            NavigationLink("Start a Run") {
                RunView()
            }
            .buttonStyle(.borderedProminent)

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
}
