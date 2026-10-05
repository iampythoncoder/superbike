@preconcurrency import AVFoundation
import SwiftUI

/// These are directions on a handlebar mount, not Apple's device positions.
enum CameraSide: String, CaseIterable, Codable, Sendable { case road, rear }

struct CameraCapabilities: Sendable {
    var rearAvailable = false
    var message = "Preparing cameras"
}

struct CaptureSettings: Sendable {
    var active = false
    /// Total inference budget, shared fairly between cameras.
    var fps = 10.0
    var speed = 0.0
    var motion = MotionSample()
    var generation = UUID()
    var recordingRequested = false
}

/// Session, connections, recorder and scheduler are confined to `queue`. The only
/// unchecked boundaries retain immutable capture frames or weak preview references.
/// UI callbacks always cross explicitly to MainActor. The model lives in its actor.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session: AVCaptureSession
    private let queue = DispatchQueue(label: "superbike.capture", qos: .userInitiated)
    private let worker = VisionWorker()
    private var settings = CaptureSettings()
    private var configured = false
    private var busy = false
    private var lastGlobalInference = 0.0
    private var lastSideInference: [CameraSide: Double] = [:]
    private var lastSideFrame: [CameraSide: Double] = [:]
    private var inputs: [CameraSide: AVCaptureDeviceInput] = [:]
    private var outputs: [CameraSide: AVCaptureVideoDataOutput] = [:]
    private var fieldsOfView: [CameraSide: Double] = [:]
    private var preparationStarted = false
    private var modelReady = false
    private var authorizationRequested = false
    private var interrupted = false
    private var lastStatus = ""
    private var lastCapabilities: CameraCapabilities?
    private var desiredHardwareFPS = 24
    private var previews: [ObjectIdentifier: PreviewBinding] = [:]
    private let output: @MainActor @Sendable (VisionOutput, UUID) -> Void
    private let status: @MainActor @Sendable (String) -> Void
    private let capabilities: @MainActor @Sendable (CameraCapabilities) -> Void
    private let recordingStatus: @MainActor @Sendable (CameraRecordingStatus) -> Void
    private lazy var recorder = CameraVideoRecorder(queue: queue) { [weak self] state in
        guard let self else { return }
        Task { @MainActor [recordingStatus = self.recordingStatus] in recordingStatus(state) }
    }

    private final class PreviewBinding: @unchecked Sendable {
        weak var layer: AVCaptureVideoPreviewLayer?
        let side: CameraSide
        var connection: AVCaptureConnection?
        init(layer: AVCaptureVideoPreviewLayer, side: CameraSide) { self.layer = layer; self.side = side }
    }
    private enum SetupError: LocalizedError {
        case unavailable, unsupported, connection, format
        var errorDescription: String? {
            switch self {
            case .unavailable: "Camera hardware is unavailable. Use a physical iPhone."
            case .unsupported: "This device cannot capture the requested cameras together."
            case .connection: "The camera stream could not be connected."
            case .format: "No supported camera capture format was found."
            }
        }
    }

    init(output: @escaping @MainActor @Sendable (VisionOutput, UUID) -> Void,
         status: @escaping @MainActor @Sendable (String) -> Void,
         capabilities: @escaping @MainActor @Sendable (CameraCapabilities) -> Void = { _ in },
         recordingStatus: @escaping @MainActor @Sendable (CameraRecordingStatus) -> Void = { _ in }) {
        session = AVCaptureMultiCamSession.isMultiCamSupported ? AVCaptureMultiCamSession() : AVCaptureSession()
        self.output = output; self.status = status; self.capabilities = capabilities
        self.recordingStatus = recordingStatus
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(_ settings: CaptureSettings) {
        queue.async { [self] in
            self.settings = settings
            if settings.active {
                startIfAuthorized()
                adjustHardwareBudget()
            } else {
                recorder.setRequested(false, sides: Set(outputs.keys))
                if session.isRunning { session.stopRunning() }
            }
            if configured && !interrupted {
                recorder.setRequested(settings.active && settings.recordingRequested, sides: Set(outputs.keys))
            }
        }
    }
    func stop() {
        queue.async { [self] in
            settings.active = false; settings.recordingRequested = false
            recorder.setRequested(false, sides: Set(outputs.keys))
            if session.isRunning { session.stopRunning() }
        }
    }
    private func report(_ message: String) {
        guard message != lastStatus else { return }
        lastStatus = message
        Task { @MainActor [status] in status(message) }
    }
    private func reportCapabilities(_ value: CameraCapabilities) {
        guard value.rearAvailable != lastCapabilities?.rearAvailable || value.message != lastCapabilities?.message else { return }
        lastCapabilities = value
        Task { @MainActor [capabilities] in capabilities(value) }
    }
    private func startIfAuthorized() {
        guard !interrupted else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            guard !authorizationRequested else { return }
            authorizationRequested = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.authorizationRequested = false
                    if self.settings.active { self.startIfAuthorized() }
                }
            }
        default:
            report("Camera access denied. Enable Camera in Settings.")
            reportCapabilities(CameraCapabilities(message: "Camera permission required"))
        }
    }
    private func configureAndStart() {
        do {
            if !configured { try configure() }
            prepareModel()
            if !session.isRunning { session.startRunning() }
            recorder.setRequested(settings.recordingRequested, sides: Set(outputs.keys))
        } catch {
            report(error.localizedDescription)
            reportCapabilities(CameraCapabilities(message: error.localizedDescription))
        }
    }
    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !(session is AVCaptureMultiCamSession) { session.sessionPreset = .inputPriority }
        // Remove a partially configured graph before retrying after a setup failure.
        for connection in session.connections { session.removeConnection(connection) }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        inputs.removeAll(); outputs.removeAll(); fieldsOfView.removeAll()
        for binding in previews.values { binding.connection = nil }
        try addCamera(.road, position: .back)
        var rearMessage = "Rear camera requires a MultiCam-capable iPhone"
        if session is AVCaptureMultiCamSession {
            do {
                try addCamera(.rear, position: .front)
                if let multi = session as? AVCaptureMultiCamSession, multi.hardwareCost > 1 {
                    removeCamera(.rear)
                    rearMessage = "Road only: dual-camera hardware budget exceeded"
                } else { rearMessage = "Road + selfie cameras connected" }
            } catch {
                removeCamera(.rear)
                rearMessage = "Road only: \(error.localizedDescription)"
            }
        }
        for binding in previews.values { connectPreview(binding) }
        configured = true
        reportCapabilities(CameraCapabilities(rearAvailable: outputs[.rear] != nil, message: rearMessage))
    }
    private func addCamera(_ side: CameraSide, position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        else { throw SetupError.unavailable }
        let multi = session is AVCaptureMultiCamSession
        let formats = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return (!multi || $0.isMultiCamSupported) && size.width <= 1920 && size.width >= 640 &&
                size.height <= 1080 && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 24 && $0.minFrameRate <= 24 }
        }
        let format = formats.min { a, b in
            let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let y = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(x.width) - 1280) + abs(Int(x.height) - 720) < abs(Int(y.width) - 1280) + abs(Int(y.height) - 720)
        }
        guard let format else { throw SetupError.format }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.unsupported }
        session.addInputWithNoConnections(input); inputs[side] = input
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw SetupError.connection }
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(video) else { throw SetupError.unsupported }
        session.addOutputWithNoConnections(video); outputs[side] = video
        let connection = AVCaptureConnection(inputPorts: [port], output: video)
        guard session.canAddConnection(connection) else { throw SetupError.connection }
        session.addConnection(connection)
        configureGeometry(connection)
        video.setSampleBufferDelegate(self, queue: queue)
        // Physical buffers are rotated portrait. Native horizontal field of view
        // becomes the vertical field of view for the upright inference image.
        fieldsOfView[side] = Double(device.activeFormat.videoFieldOfView) * .pi / 180
    }
    private func removeCamera(_ side: CameraSide) {
        if let output = outputs.removeValue(forKey: side) {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        if let input = inputs.removeValue(forKey: side) { session.removeInput(input) }
        fieldsOfView[side] = nil
    }
    private func configureGeometry(_ connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
    }
    private func prepareModel() {
        guard !preparationStarted else { return }
        preparationStarted = true
        report("Loading on-device vision…")
        Task { [weak self, worker] in
            do {
                try await worker.prepare()
                guard let self else { return }
                self.queue.async { self.modelReady = true; self.report("On-device vision ready") }
            } catch {
                guard let self else { return }
                self.queue.async { self.report("Vision unavailable: \(error.localizedDescription)") }
            }
        }
    }
    private func adjustHardwareBudget() {
        let severe = ProcessInfo.processInfo.thermalState == .serious ||
            inputs.values.contains { $0.device.systemPressureState.level == .serious || $0.device.systemPressureState.level == .critical }
        let fps = severe ? 15 : 24
        guard fps != desiredHardwareFPS else { return }
        desiredHardwareFPS = fps
        for input in inputs.values {
            let device = input.device
            guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) else { continue }
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.unlockForConfiguration()
            } catch { report("Unable to reduce camera frame rate") }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard settings.active, let side = outputs.first(where: { $0.value === output })?.key else { return }
        recorder.append(sampleBuffer, side: side)
        let now = ProcessInfo.processInfo.systemUptime
        lastSideFrame[side] = now
        let fps = min(settings.fps, ProcessInfo.processInfo.thermalState == .serious ? 5 : 20)
        guard modelReady, !busy, fps > 0, now - lastGlobalInference >= 1 / fps else { return }
        // No queue of pending inference frames; prefer the camera least recently
        // analysed, but don't let a disconnected/stalled feed starve the other one.
        let recentSides = outputs.keys.filter { now - (lastSideFrame[$0] ?? 0) < 0.5 }
        let preferred = recentSides.min { (lastSideInference[$0] ?? 0) < (lastSideInference[$1] ?? 0) }
        guard preferred == nil || preferred == side, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true; lastGlobalInference = now; lastSideInference[side] = now
        let snapshot = settings
        let frame = VisionFrame(buffer: buffer, side: side, timestamp: now, verticalFOV: fieldsOfView[side] ?? 1.1)
        Task { [weak self, worker] in
            let result = await worker.process(frame, speed: snapshot.speed, motion: snapshot.motion, generation: snapshot.generation)
            guard let self else { return }
            if let result { await self.output(result, snapshot.generation) }
            self.queue.async { self.busy = false }
        }
    }

    @MainActor func attach(_ layer: AVCaptureVideoPreviewLayer, side: CameraSide) {
        let id = ObjectIdentifier(layer)
        let binding = PreviewBinding(layer: layer, side: side)
        queue.async { [self, binding] in
            if let old = previews[id] { disconnectPreview(old) }
            previews[id] = binding
            if configured {
                session.beginConfiguration(); connectPreview(binding); session.commitConfiguration()
            }
        }
    }
    @MainActor func detach(_ layer: AVCaptureVideoPreviewLayer) {
        let id = ObjectIdentifier(layer)
        queue.async { [self] in
            guard let binding = previews.removeValue(forKey: id) else { return }
            session.beginConfiguration(); disconnectPreview(binding); session.commitConfiguration()
        }
    }
    private func connectPreview(_ binding: PreviewBinding) {
        guard let layer = binding.layer, let input = inputs[binding.side],
              let port = input.ports.first(where: { $0.mediaType == .video }), binding.connection == nil else { return }
        layer.setSessionWithNoConnection(session)
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else { return }
        session.addConnection(connection); configureGeometry(connection)
        binding.connection = connection
    }
    private func disconnectPreview(_ binding: PreviewBinding) {
        if let connection = binding.connection, session.connections.contains(connection) { session.removeConnection(connection) }
        binding.connection = nil; binding.layer?.session = nil
    }
    @objc private func sessionError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let message = error?.localizedDescription ?? "Camera session failed"
        let reset = error?.code == .mediaServicesWereReset
        queue.async { [self] in
            recorder.interrupt(message)
            report(message)
            if reset && settings.active { interrupted = false; configureAndStart() }
        }
    }
    @objc private func sessionInterrupted(_ notification: Notification) {
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let message = reason == AVCaptureSession.InterruptionReason.videoDeviceNotAvailableDueToSystemPressure.rawValue
            ? "Camera paused: device under thermal pressure" : "Camera interrupted. Keep Superbike open to resume."
        queue.async { [self] in interrupted = true; recorder.interrupt(message); report(message) }
    }
    @objc private func interruptionEnded() {
        queue.async { [self] in
            interrupted = false
            if settings.active { configureAndStart(); report("Camera resumed") }
        }
    }
}

final class CameraPreview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
struct CameraSurface: UIViewRepresentable {
    let pipeline: CameraPipeline
    var side: CameraSide = .road
    final class Coordinator {
        let pipeline: CameraPipeline
        var side: CameraSide
        init(pipeline: CameraPipeline, side: CameraSide) { self.pipeline = pipeline; self.side = side }
    }
    func makeCoordinator() -> Coordinator { Coordinator(pipeline: pipeline, side: side) }
    func makeUIView(context: Context) -> CameraPreview {
        let view = CameraPreview()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        pipeline.attach(view.previewLayer, side: side)
        return view
    }
    func updateUIView(_ uiView: CameraPreview, context: Context) {
        guard context.coordinator.side != side else { return }
        context.coordinator.side = side
        pipeline.attach(uiView.previewLayer, side: side)
    }
    static func dismantleUIView(_ uiView: CameraPreview, coordinator: Coordinator) {
        coordinator.pipeline.detach(uiView.previewLayer)
    }
}
