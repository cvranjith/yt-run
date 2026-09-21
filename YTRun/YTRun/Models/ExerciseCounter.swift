//
//  ExerciseCounter.swift
//  YTRun
//

import Foundation
import Combine
import AVFoundation
import Vision
import UIKit

// Which camera-tracked exercise a given `ExerciseCounter` is counting.
// All three share the exact same technique — Vision's body-pose
// tracking gives a set of 2D joint positions; the angle at one joint
// ("vertex"), formed by the rays to two others ("pointA"/"pointB"),
// cycles between an extended and a folded position once per rep. Only
// *which* three joints define that angle differs between exercises.
enum ExerciseKind: String, CaseIterable, Identifiable {
    case pushUps, sitUps, lunges

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushUps: return "Push-Ups"
        case .sitUps: return "Sit-Ups"
        case .lunges: return "Lunges"
        }
    }

    var systemImage: String {
        switch self {
        case .pushUps: return "figure.strengthtraining.traditional"
        case .sitUps: return "figure.core.training"
        case .lunges: return "figure.mixed.cardio"
        }
    }

    // Tags a claimed reward's `LedgerEvent` (see `ExerciseTrainingView
    // .claimReward()`) so breakdown screens can group by exercise
    // rather than lumping every reward source into one bucket.
    var ledgerSource: LedgerEventSource {
        switch self {
        case .pushUps: return .pushUps
        case .sitUps: return .sitUps
        case .lunges: return .lunges
        }
    }

    // Labels for the debug panel — matching whichever three joints
    // this exercise actually tracks.
    var pointALabel: String {
        switch self {
        case .pushUps, .sitUps: return "Shoulder"
        case .lunges: return "Hip"
        }
    }

    var vertexLabel: String {
        switch self {
        case .pushUps: return "Elbow"
        case .sitUps: return "Hip"
        case .lunges: return "Knee"
        }
    }

    var pointBLabel: String {
        switch self {
        case .pushUps: return "Wrist"
        case .sitUps, .lunges: return "Knee"
        }
    }

    // (pointA, vertex, pointB) for one side — push-ups: shoulder-elbow-
    // wrist; sit-ups: shoulder-hip-knee; lunges: hip-knee-ankle.
    func joints(useRight: Bool) -> (
        pointA: VNHumanBodyPoseObservation.JointName,
        vertex: VNHumanBodyPoseObservation.JointName,
        pointB: VNHumanBodyPoseObservation.JointName
    ) {
        switch self {
        case .pushUps:
            return useRight ? (.rightShoulder, .rightElbow, .rightWrist) : (.leftShoulder, .leftElbow, .leftWrist)
        case .sitUps:
            return useRight ? (.rightShoulder, .rightHip, .rightKnee) : (.leftShoulder, .leftHip, .leftKnee)
        case .lunges:
            return useRight ? (.rightHip, .rightKnee, .rightAnkle) : (.leftHip, .leftKnee, .leftAnkle)
        }
    }
}

// One frame's worth of what Vision actually saw, for the test screen's
// debug panel — deliberately kept in Vision's own raw normalized
// coordinate space (0...1, origin bottom-left) rather than mapped onto
// the live camera preview's own coordinates, which would need the same
// rotation/aspect-fill transform that's already been gotten wrong
// twice without a device to verify against. This stays correct by
// construction, at the cost of not being literally overlaid on your
// body in the preview.
struct PoseDebugInfo {
    let usingRightSide: Bool
    let pointA: CGPoint
    let vertex: CGPoint
    let pointB: CGPoint
    let pointAConfidence: Float
    let vertexConfidence: Float
    let pointBConfidence: Float
}

// Counts reps of a given `ExerciseKind` entirely on-device via Vision's
// body pose tracking — no AI/LLM call, no video ever leaving the
// device, no per-use cost. The whole thing is a deterministic state
// machine on top of one number: the angle at the exercise's vertex
// joint, which cycles from an extended position (~180°) to a folded one
// (under ~100°) and back for every real rep. Whichever side (left/
// right) Vision is more confident about each frame is used — a single-
// camera side-profile view naturally only shows one side clearly
// anyway.
//
// Defaults to the front camera in portrait — confirmed by hand to
// track push-ups reliably, and it matches how the phone would actually
// be propped in practice (facing you, roughly at floor/chest height).
// A pure side-profile view (landscape, phone to the side) should be
// *more* geometrically precise in principle — the tracked joint's bend
// then happens mostly within the camera's 2D plane rather than partly
// toward/away from the lens, which 2D-only tracking can't see — but
// isn't the more practical setup, and testing showed front-on tracks
// well enough anyway.
@MainActor
final class ExerciseCounter: NSObject, ObservableObject {
    nonisolated let kind: ExerciseKind

    @Published private(set) var repCount = 0
    @Published private(set) var currentAngle: Double?
    @Published private(set) var isBodyVisible = false
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var debugInfo: PoseDebugInfo?
    // Mirrors the private `phase` enum below for display — kept as a
    // separate published string rather than making `phase` itself
    // published, since the state machine only needs to read/write it,
    // not react to its own changes.
    @Published private(set) var phaseLabel = "Up"

    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    // Vision inference is real CPU work — kept off the main actor
    // entirely (see the `nonisolated` delegate method below) so it
    // never competes with the UI/preview rendering.
    private let processingQueue = DispatchQueue(label: "com.ranjith.ytrun.exercisecounter.processing")
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private var isConfigured = false

    // Mirroring is force-disabled on the output connection (see
    // `configureMirroring`) so both cameras always deliver a plain,
    // unmirrored buffer, needing only one rotation-only orientation
    // table for either camera (see `visionOrientation` below) — an
    // earlier version guessed at a separate *mirrored* constant for the
    // front camera specifically, which turned out unreliable in
    // practice.
    //
    // Read by the nonisolated capture callback, written by the device-
    // orientation notification handler — both benign single-enum
    // writes/reads, so `nonisolated(unsafe)` here just crosses the
    // main-actor boundary type-check, not a real race.
    nonisolated(unsafe) private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    // Mirror of the same value, published for the preview to visually
    // counter-rotate by (see ExerciseTrainingView) — the SwiftUI view
    // itself doesn't rotate to landscape, so without this the on-screen
    // preview looks sideways whenever the phone is physically turned,
    // even though the *detection* is already reading the phone's real
    // orientation correctly via `currentDeviceOrientation` above.
    @Published private(set) var deviceOrientation: UIDeviceOrientation = .portrait

    private enum Phase {
        case up, down
    }
    private var phase: Phase = .up
    private var recentAngles: [Double] = []

    // First-guess thresholds, shared across all three exercise kinds
    // rather than tuned per-kind — not exposed as Settings yet.
    // Deliberately wide apart (rather than both near ~130°) so ordinary
    // jitter around any one angle can't flicker back and forth across a
    // single threshold and over- or under-count.
    private static let downThresholdDegrees = 100.0
    private static let upThresholdDegrees = 155.0
    // Not private — ExerciseTrainingView's debug panel colors
    // confidence readouts against this exact same number, rather than
    // duplicating the value and risking the two drifting apart.
    static let minimumJointConfidence: Float = 0.3
    // Smooths single-frame jitter in the raw angle reading.
    private static let smoothingWindowSize = 3
    // Vision on every single camera frame (~30fps) is more than this
    // needs — a rep takes at least ~1 second, so sampling at roughly
    // 10fps still tracks the motion smoothly while using a third of
    // the CPU.
    private static let frameProcessingStride = 3
    // Mutated only from `captureOutput` below, which AVFoundation
    // guarantees runs serially on `processingQueue` for a given
    // output — safe despite being touched off the main actor, and
    // needs to be checked *before* running Vision (not after) so
    // skipped frames actually skip the CPU-heavy inference too.
    nonisolated(unsafe) private var frameCounter = 0

    init(kind: ExerciseKind) {
        self.kind = kind
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
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        processingQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func reset() {
        repCount = 0
        phase = .up
        phaseLabel = "Up"
        recentAngles = []
    }

    func flipCamera() {
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back
        currentCameraPosition = newPosition
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.addCameraInput()
            self.session.commitConfiguration()
            self.configureMirroring()
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
        configureMirroring()
        beginObservingDeviceOrientation()
    }

    private func addCameraInput() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    // Forces a known, unmirrored buffer on the data-output connection
    // regardless of camera position. Must run after the output (and,
    // for a flip, the new input) is actually attached to the session,
    // since the connection doesn't exist before that.
    private func configureMirroring() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

    private func startSession() {
        processingQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: - Device orientation

    private func beginObservingDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        applyDeviceOrientation(UIDevice.current.orientation)
    }

    @objc private func deviceOrientationDidChange() {
        applyDeviceOrientation(UIDevice.current.orientation)
    }

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        // Face-up/face-down/unknown aren't real rotations to track by —
        // keep whichever last valid rotation was seen (almost certainly
        // still how the phone is actually propped) rather than resetting
        // to some default.
        guard orientation.isValidInterfaceOrientation else { return }
        currentDeviceOrientation = orientation
        deviceOrientation = orientation
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

    private struct PoseSample {
        // nil when a side was found but its confidence is below
        // threshold — the frame still isn't fed to the rep-counting
        // state machine, but `debugInfo` is populated regardless so the
        // exact moment/reason confidence drops (e.g. right at the
        // bottom of a rep) is actually visible instead of the debug
        // panel just going blank at the moment it matters most.
        let angle: Double?
        let debugInfo: PoseDebugInfo
    }

    // Pure function, no instance state touched — marked `nonisolated`
    // so `captureOutput` (itself `nonisolated`, running on
    // `processingQueue`) can call it synchronously without hopping to
    // the main actor just to do CPU math. Returns confidences/positions
    // alongside the angle now (not just the angle) so the test screen
    // can show *why* a frame was or wasn't usable.
    nonisolated private static func poseSample(from observation: VNHumanBodyPoseObservation, kind: ExerciseKind) -> PoseSample? {
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> VNRecognizedPoint? {
            try? observation.recognizedPoint(joint)
        }
        func confidence(_ joint: VNHumanBodyPoseObservation.JointName) -> Float {
            point(joint)?.confidence ?? 0
        }

        let rightJoints = kind.joints(useRight: true)
        let leftJoints = kind.joints(useRight: false)
        let rightConfidence = min(confidence(rightJoints.pointA), confidence(rightJoints.vertex), confidence(rightJoints.pointB))
        let leftConfidence = min(confidence(leftJoints.pointA), confidence(leftJoints.vertex), confidence(leftJoints.pointB))
        let useRight = rightConfidence >= leftConfidence
        let minConfidence = useRight ? rightConfidence : leftConfidence
        let joints = useRight ? rightJoints : leftJoints

        // Still nil here means Vision didn't locate this joint at all
        // (as opposed to locating it with low confidence) — genuinely
        // nothing to show or compute from.
        guard let pointAPoint = point(joints.pointA),
              let vertexPoint = point(joints.vertex),
              let pointBPoint = point(joints.pointB) else { return nil }
        let pointA = pointAPoint.location
        let vertex = vertexPoint.location
        let pointB = pointBPoint.location

        let debugInfo = PoseDebugInfo(
            usingRightSide: useRight,
            pointA: pointA,
            vertex: vertex,
            pointB: pointB,
            pointAConfidence: pointAPoint.confidence,
            vertexConfidence: vertexPoint.confidence,
            pointBConfidence: pointBPoint.confidence
        )

        guard minConfidence >= minimumJointConfidence else {
            return PoseSample(angle: nil, debugInfo: debugInfo)
        }

        let toA = CGVector(dx: pointA.x - vertex.x, dy: pointA.y - vertex.y)
        let toB = CGVector(dx: pointB.x - vertex.x, dy: pointB.y - vertex.y)
        let magA = sqrt(toA.dx * toA.dx + toA.dy * toA.dy)
        let magB = sqrt(toB.dx * toB.dx + toB.dy * toB.dy)
        guard magA > 0, magB > 0 else {
            return PoseSample(angle: nil, debugInfo: debugInfo)
        }

        let dot = toA.dx * toB.dx + toA.dy * toB.dy
        let cosAngle = max(-1, min(1, dot / (magA * magB)))
        let angle = acos(cosAngle) * 180 / .pi
        return PoseSample(angle: angle, debugInfo: debugInfo)
    }

    // Rotation-only — both cameras use the same table since mirroring
    // is force-disabled uniformly (see `configureMirroring`). This is
    // the standard mapping for a raw, unmirrored `AVCaptureVideoDataOutput`
    // buffer: the sensor is physically mounted rotated 90° relative to
    // the portrait screen, so "portrait" needs a 90° correction, and
    // each other case rotates from there.
    nonisolated private static func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }
}

extension ExerciseCounter: AVCaptureVideoDataOutputSampleBufferDelegate {
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
        // consistent rotation of the input.
        let orientation = Self.visionOrientation(for: currentDeviceOrientation)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first,
              let sample = Self.poseSample(from: observation, kind: kind) else {
            Task { @MainActor [weak self] in
                self?.isBodyVisible = false
                self?.debugInfo = nil
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBodyVisible = true
            self.debugInfo = sample.debugInfo
            // A low-confidence frame (angle == nil) is skipped for
            // counting purposes but still shown above — this is
            // exactly the case worth watching for around a missed rep.
            guard let angle = sample.angle else { return }
            self.recentAngles.append(angle)
            if self.recentAngles.count > Self.smoothingWindowSize {
                self.recentAngles.removeFirst()
            }
            let smoothed = self.recentAngles.reduce(0, +) / Double(self.recentAngles.count)
            self.currentAngle = smoothed
            self.processAngle(smoothed)
            self.phaseLabel = self.phase == .up ? "Up" : "Down"
        }
    }
}
