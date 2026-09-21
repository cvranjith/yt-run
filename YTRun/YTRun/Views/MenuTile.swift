//
//  MenuTile.swift
//  YTRun
//

import SwiftUI

// A colorful icon tile used for Home screen navigation — `NavigationLink`
// with `.buttonStyle(.plain)` strips away the default blue/list styling so
// our own gradient background shows through untouched.
struct MenuTile<Destination: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    var fullWidth = false
    // A denser variant for a "dashboard" grid with many tiles on one
    // screen — same tap target, just a shorter, tighter card so more of
    // them fit without scrolling. Independent of `fullWidth` (mutually
    // exclusive in practice, but nothing enforces that — `fullWidth`
    // wins if both are set, matching the `if/else` below).
    var compact = false
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            if fullWidth {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if compact {
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                    Text(title)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 16) {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            MenuTile(title: "Watch YouTube", systemImage: "play.rectangle.fill", color: .red) {
                Text("Destination")
            }
            MenuTile(title: "Start a Run", systemImage: "figure.run", color: .orange) {
                Text("Destination")
            }
        }
        MenuTile(title: "Settings", systemImage: "gearshape.fill", color: .gray, fullWidth: true) {
            Text("Destination")
        }
    }
    .padding()
}
