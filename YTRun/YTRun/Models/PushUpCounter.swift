//
//  PushUpCounter.swift
//  YTRun
//

import Foundation
import Combine
import AVFoundation
import Vision

// Counts push-up reps entirely on-device via Vision's body pose
// tracking — no AI/LLM call, no video ever leaving the device, no
// per-use cost. The whole thing is a deterministic state machine on
// top of one number: the angle at the elbow (shoulder-elbow-wrist),
// which cycles roughly 180° (arm straight, "up") down to under 100°
// (arm bent, "down") and back for every real rep. Whichever arm side
// Vision is more confident about each frame is used — a single-camera
// side-profile view of a push-up naturally only shows one arm clearly
// anyway.
//
// Defaults to the front camera in portrait — confirmed by hand to
// track reliably, and it matches how the phone would actually be
// propped in practice (facing you, roughly at floor/chest height).
// A pure side-profile view (landscape, phone to the side) should be
// *more* geometrically precise in principle — the elbow's bend then
// happens mostly within the camera's 2D plane rather than partly
// toward/away from the lens, which 2D-only tracking can't see — but
// isn't the more practical setup, and testing showed front-on tracks
// well enough anyway.
@MainActor
final class PushUpCounter: NSObject, ObservableObject {
    @Published private(set) var repCount = 0
    @Published private(set) var currentAngle: Double?
    @Published private(set) var isBodyVisible = false
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined

    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    // Vision inference is real CPU work — kept off the main actor
    // entirely (see the `nonisolated` delegate method below) so it
    // never competes with the UI/preview rendering.
    private let processingQueue = DispatchQueue(label: "com.ranjith.ytrun.pushupcounter.processing")
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private var isConfigured = false
    // Mirrors `currentCameraPosition` for the nonisolated capture
    // callback to read — written and read only from `processingQueue`
    // (set inside `flipCamera`'s queued block, right alongside the
    // actual camera swap), so there's no real race despite the
    // annotation just being about crossing the main-actor boundary.
    // The front and back cameras are mounted rotated the same way but
    // facing opposite directions, so in portrait the front camera's
    // raw buffer needs the *mirrored* orientation variant to be
    // interpreted correctly, unlike the back camera's plain `.right`.
    nonisolated(unsafe) private var visionOrientation: CGImagePropertyOrientation = .leftMirrored

    private enum Phase {
        case up, down
    }
    private var phase: Phase = .up
    private var recentAngles: [Double] = []

    // First-guess thresholds, not exposed as Settings yet — deliberately
    // wide apart (rather than both near ~130°) so ordinary jitter around
    // any one angle can't flicker back and forth across a single
    // threshold and over- or under-count. Tune these once real reps
    // have been tested against them.
    private static let downThresholdDegrees = 100.0
    private static let upThresholdDegrees = 155.0
    private static let minimumJointConfidence: Float = 0.3
    // Smooths single-frame jitter in the raw angle reading.
    private static let smoothingWindowSize = 3
    // Vision on every single camera frame (~30fps) is more than this
    // needs — a push-up rep takes at least ~1 second, so sampling at
    // roughly 10fps still tracks the motion smoothly while using a
    // third of the CPU.
    private static let frameProcessingStride = 3
    // Mutated only from `captureOutput` below, which AVFoundation
    // guarantees runs serially on `processingQueue` for a given
    // output — safe despite being touched off the main actor, and
    // needs to be checked *before* running Vision (not after) so
    // skipped frames actually skip the CPU-heavy inference too.
    nonisolated(unsafe) private var frameCounter = 0

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            configureSessionIfNeeded()
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self?.configureSessionIfNeeded()
                        self?.startSession()
                    }
                }
            }
        default:
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func stop() {
        processingQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func reset() {
        repCount = 0
        phase = .up
        recentAngles = []
    }

    func flipCamera() {
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back
        currentCameraPosition = newPosition
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.visionOrientation = newPosition == .back ? .right : .leftMirrored
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.addCameraInput()
            self.session.commitConfiguration()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        addCameraInput()
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        previewLayer.session = session
    }

    private func addCameraInput() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    private func startSession() {
        processingQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: - Rep counting

    private func processAngle(_ angle: Double) {
        switch phase {
        case .up:
            if angle < Self.downThresholdDegrees {
                phase = .down
            }
        case .down:
            if angle > Self.upThresholdDegrees {
                phase = .up
                repCount += 1
            }
        }
    }

    // Pure function, no instance state touched — marked `nonisolated`
    // so `captureOutput` (itself `nonisolated`, running on
    // `processingQueue`) can call it synchronously without hopping to
    // the main actor just to do CPU math.
    nonisolated private static func elbowAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> VNRecognizedPoint? {
            try? observation.recognizedPoint(joint)
        }
        func confidence(_ joint: VNHumanBodyPoseObservation.JointName) -> Float {
            point(joint)?.confidence ?? 0
        }

        let rightConfidence = min(confidence(.rightShoulder), confidence(.rightElbow), confidence(.rightWrist))
        let leftConfidence = min(confidence(.leftShoulder), confidence(.leftElbow), confidence(.leftWrist))
        let useRight = rightConfidence >= leftConfidence
        let minConfidence = useRight ? rightConfidence : leftConfidence
        guard minConfidence >= minimumJointConfidence else { return nil }

        let joints: (shoulder: VNHumanBodyPoseObservation.JointName, elbow: VNHumanBodyPoseObservation.JointName, wrist: VNHumanBodyPoseObservation.JointName) =
            useRight ? (.rightShoulder, .rightElbow, .rightWrist) : (.leftShoulder, .leftElbow, .leftWrist)

        guard let shoulder = point(joints.shoulder)?.location,
              let elbow = point(joints.elbow)?.location,
              let wrist = point(joints.wrist)?.location else { return nil }

        let toShoulder = CGVector(dx: shoulder.x - elbow.x, dy: shoulder.y - elbow.y)
        let toWrist = CGVector(dx: wrist.x - elbow.x, dy: wrist.y - elbow.y)
        let magShoulder = sqrt(toShoulder.dx * toShoulder.dx + toShoulder.dy * toShoulder.dy)
        let magWrist = sqrt(toWrist.dx * toWrist.dx + toWrist.dy * toWrist.dy)
        guard magShoulder > 0, magWrist > 0 else { return nil }

        let dot = toShoulder.dx * toWrist.dx + toShoulder.dy * toWrist.dy
        let cosAngle = max(-1, min(1, dot / (magShoulder * magWrist)))
        return acos(cosAngle) * 180 / .pi
    }
}

extension PushUpCounter: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Runs on `processingQueue`, not the main actor — Vision's pose
    // request is real per-frame CPU work, and only the small resulting
    // published-state update needs to hop back to the main actor
    // afterward. Same pattern RunTracker's CLLocationManagerDelegate
    // callback already uses for the same reason.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCounter += 1
        guard frameCounter % Self.frameProcessingStride == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectHumanBodyPoseRequest()
        // Getting this right mostly matters for Vision's own detection
        // reliability (its pose model expects an upright image) rather
        // than the angle math afterward — an unsigned angle from three
        // relative points stays numerically correct under any
        // consistent rotation/mirroring of the input, which is why an
        // earlier version of this worked passably even with a
        // fixed-wrong orientation for the front camera.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: visionOrientation, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first,
              let angle = Self.elbowAngle(from: observation) else {
            Task { @MainActor [weak self] in self?.isBodyVisible = false }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBodyVisible = true
            self.recentAngles.append(angle)
            if self.recentAngles.count > Self.smoothingWindowSize {
                self.recentAngles.removeFirst()
            }
            let smoothed = self.recentAngles.reduce(0, +) / Double(self.recentAngles.count)
            self.currentAngle = smoothed
            self.processAngle(smoothed)
        }
    }
}
