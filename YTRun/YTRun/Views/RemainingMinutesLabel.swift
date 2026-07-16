//
//  RemainingMinutesLabel.swift
//  YTRun
//

import SwiftUI

// Shared "N min remaining" readout used on both the Home screen and the
// YouTube screen's toolbar, so the color-when-critical / rounding logic
// only lives in one place.
struct RemainingMinutesLabel: View {
    let title: String
    let remainingSeconds: Int
    let limitSeconds: Int
    var compact: Bool = false

    private var minutes: Int {
        // Round up so a few leftover seconds don't display as "0 min"
        // while there's technically still time left.
        (remainingSeconds + 59) / 60
    }

    private var isCritical: Bool {
        UsageTracker.isCritical(remainingSeconds: remainingSeconds, limitSeconds: limitSeconds)
    }

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(minutes)m")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isCritical ? .red : .primary)
            }
        } else {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(minutes)")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(isCritical ? .red : .primary)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        RemainingMinutesLabel(title: "Remaining today", remainingSeconds: 300, limitSeconds: 3600)
        RemainingMinutesLabel(title: "Short break", remainingSeconds: 60, limitSeconds: 1200, compact: true)
    }
}
