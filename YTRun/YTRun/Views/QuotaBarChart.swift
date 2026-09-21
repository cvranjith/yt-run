//
//  QuotaBarChart.swift
//  YTRun
//

import SwiftUI

// Two stacked bars (Earned on top, Spent below) sharing one scale, with
// small triangle markers calling out the quota, spent, and earned
// totals. Replaces a flat "Earned/Spent/Balance" number trio with a
// picture of *why* the numbers are what they are — colored capsules
// on the Spent bar in Steps 1-6 below.
//
// The Spent bar's color rule (derived with the user, from concrete
// examples): green up to whichever of quota/earned is *smaller*; amber
// only exists — and only up to `earned` — when earned is actually
// bigger than quota (you've gone over your original plan, but you've
// genuinely earned enough today to cover it); red for anything beyond
// that. If earned is the smaller of the two, there's no amber band at
// all — the moment spending passes what's been earned, it's red, even
// if that's still short of the 60-minute quota. The Earned bar mirrors
// this: whatever's earned beyond what's actually been spent shows as a
// green "profit" segment, since that's capacity still in the bank.
struct QuotaBarChart: View {
    let quotaSeconds: Int
    let spentSeconds: Int
    let earnedSeconds: Int

    private let labelWidth: CGFloat = 50
    private let barHeight: CGFloat = 22

    private var scaleMax: Double {
        Double(max(quotaSeconds, spentSeconds, earnedSeconds, 60)) * 1.12
    }

    private var greenEnd: Int { min(spentSeconds, min(quotaSeconds, earnedSeconds)) }
    private var amberEnd: Int { earnedSeconds > quotaSeconds ? min(spentSeconds, earnedSeconds) : greenEnd }
    private var coveredSeconds: Int { max(0, amberEnd - greenEnd) }
    private var owedSeconds: Int { max(0, spentSeconds - amberEnd) }
    private var profitSeconds: Int { max(0, earnedSeconds - spentSeconds) }

    var body: some View {
        GeometryReader { geo in
            let barWidth = max(1, geo.size.width - labelWidth)
            VStack(alignment: .leading, spacing: 8) {
                markerRow(barWidth: barWidth)

                barRow(title: "Earned", barWidth: barWidth) {
                    segment(seconds: min(earnedSeconds, spentSeconds), barWidth: barWidth, color: .secondary.opacity(0.3))
                    if profitSeconds > 0 {
                        segment(seconds: profitSeconds, barWidth: barWidth, color: .green, label: "+\(profitSeconds / 60)m")
                    }
                }

                barRow(title: "Spent", barWidth: barWidth) {
                    segment(seconds: greenEnd, barWidth: barWidth, color: .green)
                    if coveredSeconds > 0 {
                        segment(seconds: coveredSeconds, barWidth: barWidth, color: .orange, label: "\(coveredSeconds / 60)m")
                    }
                    if owedSeconds > 0 {
                        segment(seconds: owedSeconds, barWidth: barWidth, color: .red, label: "\(owedSeconds / 60)m")
                    }
                }
            }
        }
        .frame(height: 92)
    }

    private func markerRow(barWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            marker(seconds: quotaSeconds, barWidth: barWidth, color: .purple, name: "Plan")
            if earnedSeconds != quotaSeconds {
                marker(seconds: earnedSeconds, barWidth: barWidth, color: .blue, name: "Earned")
            }
            if spentSeconds != quotaSeconds && spentSeconds != earnedSeconds {
                marker(seconds: spentSeconds, barWidth: barWidth, color: .blue, name: "Spent")
            }
        }
        .padding(.leading, labelWidth)
        .frame(height: 30, alignment: .top)
    }

    private func marker(seconds: Int, barWidth: CGFloat, color: Color, name: String) -> some View {
        let x = barWidth * CGFloat(min(1, Double(seconds) / scaleMax))
        return VStack(spacing: 0) {
            Text("\(seconds / 60)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
        }
        .offset(x: x - 10)
        .accessibilityLabel("\(name) \(seconds / 60) minutes")
    }

    private func barRow<Content: View>(title: String, barWidth: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 0) {
                content()
            }
            .frame(width: barWidth, height: barHeight, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func segment(seconds: Int, barWidth: CGFloat, color: Color, label: String? = nil) -> some View {
        let width = barWidth * CGFloat(min(1, Double(seconds) / scaleMax))
        return Rectangle()
            .fill(color)
            .frame(width: width, height: barHeight)
            .overlay(alignment: .center) {
                if let label, width > 26 {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
    }
}

#Preview {
    VStack(spacing: 24) {
        QuotaBarChart(quotaSeconds: 3600, spentSeconds: 4800, earnedSeconds: 5400)
        QuotaBarChart(quotaSeconds: 3600, spentSeconds: 4800, earnedSeconds: 3000)
        QuotaBarChart(quotaSeconds: 3600, spentSeconds: 2400, earnedSeconds: 3300)
    }
    .padding()
}
