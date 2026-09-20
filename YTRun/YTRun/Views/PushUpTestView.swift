//
//  PushUpTestView.swift
//  YTRun
//

import SwiftUI
import AVFoundation

// Standalone test harness for PushUpCounter — deliberately not wired
// into the Locked screen yet. The algorithm (Vision body-pose angle
// tracking) needs validating against real reps first; this exists to
// answer "does it count reliably" before it's trusted to gate
// anything, the same way Walk mode's step-count approach was simple
// enough not to need this step first.
struct PushUpTestView: View {
    @StateObject private var counter = PushUpCounter()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if counter.authorizationStatus == .authorized {
                CameraPreviewView(previewLayer: counter.previewLayer)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("\(counter.repCount)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(counter.isBodyVisible ? "Body detected" : "No body detected")
                        .font(.subheadline)
                        .foregroundStyle(counter.isBodyVisible ? .green : .red)
                    if let angle = counter.currentAngle {
                        Text("Elbow angle: \(Int(angle))°")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    HStack(spacing: 20) {
                        Button("Reset") { counter.reset() }
                            .buttonStyle(.bordered)
                        Button("Flip Camera") { counter.flipCamera() }
                            .buttonStyle(.bordered)
                    }
                    .tint(.white)
                }
                .padding()
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
            }

            if counter.authorizationStatus == .denied || counter.authorizationStatus == .restricted {
                VStack(spacing: 12) {
                    Text("Camera access is off")
                        .font(.headline)
                    Text("Enable it in Settings → Privacy → Camera → YTRun to count push-ups.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .navigationTitle("Push-Up Test")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { counter.requestAccessAndStart() }
        .onDisappear { counter.stop() }
    }
}

#Preview {
    NavigationStack {
        PushUpTestView()
    }
}
