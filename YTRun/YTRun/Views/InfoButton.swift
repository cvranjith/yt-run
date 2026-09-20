//
//  InfoButton.swift
//  YTRun
//

import SwiftUI

// A compact "ⓘ" replacement for a Settings section's inline footer
// text — the explanation is exactly as long as it was before, it just
// shows in a small popover on tap instead of always taking up
// permanent vertical space on the Settings screen.
struct InfoButton: View {
    let text: String
    @State private var isShowingInfo = false

    var body: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isShowingInfo) {
            Text(text)
                .font(.footnote)
                .padding()
                .frame(idealWidth: 300)
                .presentationCompactAdaptation(.popover)
        }
    }
}
