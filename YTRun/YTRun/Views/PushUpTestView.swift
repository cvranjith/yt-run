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
                // This view never actually rotates to a landscape
                // layout (the app is portrait-only), so the preview
                // has to reshape itself explicitly: swap width/height
                // to match the phone's real orientation, then rotate
                // that correctly-shaped block back to upright and
                // center it within the still-portrait screen —
                // otherwise a landscape capture just spins in place
                // inside a fixed tall/narrow frame, which is what
                // looked broken before. Still purely cosmetic;
                // PushUpCounter's own orientation handling is what
                // actually keeps detection correct, independent of
                // this.
                GeometryReader { geo in
                    CameraPreviewView(previewLayer: counter.previewLayer)
                        .frame(
                            width: isLandscape ? geo.size.height : geo.size.width,
                            height: isLandscape ? geo.size.width : geo.size.height
                        )
                        .rotationEffect(.degrees(previewRotationDegrees))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .ignoresSafeArea()
            }

            VStack {
                if let debug = counter.debugInfo {
                    debugPanel(debug)
                        .padding(.top, 8)
                }
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
                    Text("Orientation: \(orientationLabel)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 16) {
                        Button("Reset") { counter.reset() }
                            .buttonStyle(.bordered)
                        Button("Flip Camera") { counter.flipCamera() }
                            .buttonStyle(.bordered)
                        Button("Fix Orientation") { counter.cycleManualOrientation() }
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

    // Debug panel for the "why didn't that count" question — shows
    // exactly what Vision saw on the last processed frame: which side
    // it's tracking, the current rep-counting phase, and each of the
    // three joints' confidence (red below the threshold PushUpCounter
    // actually uses to decide whether to trust the frame at all), plus
    // a shape diagram. The diagram is plotted in Vision's own raw
    // coordinate space, not mapped onto the camera preview — see
    // `PoseDebugInfo`'s own comment for why.
    private func debugPanel(_ debug: PoseDebugInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Side: \(debug.usingRightSide ? "Right" : "Left")")
                Text("Phase: \(counter.phaseLabel)")
                confidenceRow("Shoulder", debug.shoulderConfidence)
                confidenceRow("Elbow", debug.elbowConfidence)
                confidenceRow("Wrist", debug.wristConfidence)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)

            poseShapeDiagram(debug)
        }
        .padding(10)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func confidenceRow(_ name: String, _ confidence: Float) -> some View {
        Text("\(name): \(String(format: "%.2f", confidence))")
            .foregroundStyle(confidence >= PushUpCounter.minimumJointConfidence ? Color.green : Color.red)
    }

    private func poseShapeDiagram(_ debug: PoseDebugInfo) -> some View {
        Canvas { context, size in
            // Vision's normalized space has (0,0) at bottom-left; flip Y
            // for SwiftUI's top-left-origin drawing.
            func plot(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
            }
            let shoulder = plot(debug.shoulder)
            let elbow = plot(debug.elbow)
            let wrist = plot(debug.wrist)

            var path = Path()
            path.move(to: shoulder)
            path.addLine(to: elbow)
            path.addLine(to: wrist)
            context.stroke(path, with: .color(.white), lineWidth: 2)

            for (point, confidence) in [
                (shoulder, debug.shoulderConfidence),
                (elbow, debug.elbowConfidence),
                (wrist, debug.wristConfidence),
            ] {
                let color: Color = confidence >= PushUpCounter.minimumJointConfidence ? .green : .red
                let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(color))
            }
        }
        .frame(width: 90, height: 90)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isLandscape: Bool {
        counter.deviceOrientation == .landscapeLeft || counter.deviceOrientation == .landscapeRight
    }

    // If this ends up rotating the wrong way in practice, the fix is
    // just flipping the sign on the two landscape cases — this is a
    // best-guess pairing with PushUpCounter's own rotation table, not
    // independently verified on-device. "Fix Orientation" below exists
    // precisely because that table needed correcting once already.
    private var previewRotationDegrees: Double {
        switch counter.deviceOrientation {
        case .portrait: return 0
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return -90
        case .landscapeRight: return 90
        default: return 0
        }
    }

    private var orientationLabel: String {
        guard let override = counter.manualOrientationOverride else { return "Auto" }
        switch override {
        case .up: return "Manual: Up"
        case .down: return "Manual: Down"
        case .left: return "Manual: Left"
        case .right: return "Manual: Right"
        default: return "Manual"
        }
    }
}

#Preview {
    NavigationStack {
        PushUpTestView()
    }
}
