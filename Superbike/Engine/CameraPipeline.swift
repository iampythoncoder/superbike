@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

struct CaptureSettings: Sendable {
    var active = false
    var fps = 10.0
    var speed = 0.0
    var motion = MotionSample()
    var generation = UUID()
}

/// Queue-confined AVFoundation boundary. All mutable state below is touched only
/// on `queue`; session is exposed solely for AVCaptureVideoPreviewLayer binding.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "superbike.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let worker = VisionWorker()
    private var settings = CaptureSettings()
    private var configured = false
    private var busy = false
    private var lastFrame = 0.0
    private var fov = 1.1
    private var preparationStarted = false
    private var modelReady = false
    private let output: @MainActor @Sendable (VisionOutput, UUID) -> Void
    private let status: @MainActor @Sendable (String) -> Void

    init(output: @escaping @MainActor @Sendable (VisionOutput, UUID) -> Void,
         status: @escaping @MainActor @Sendable (String) -> Void) {
        self.output = output; self.status = status
    }
    func update(_ settings: CaptureSettings) {
        queue.async { [self] in
            self.settings = settings
            if settings.active { startIfAuthorized() }
            else if session.isRunning { session.stopRunning() }
        }
    }
    func stop() {
        queue.async { [self] in settings.active = false; if session.isRunning { session.stopRunning() } }
    }
    private func report(_ message: String) { Task { @MainActor [status] in status(message) } }
    private func startIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                guard let self else { return }
                self.queue.async { if self.settings.active { self.startIfAuthorized() } }
            }
        default: report("Camera access needed in Settings")
        }
    }
    private func configureAndStart() {
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .hd1280x720
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                else { report("Rear camera unavailable"); return }
                let input = try AVCaptureDeviceInput(device: device)
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                guard session.canAddInput(input), session.canAddOutput(video) else { report("Camera setup failed"); return }
                session.addInput(input); session.addOutput(video)
                video.setSampleBufferDelegate(self, queue: queue)
                if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                    connection.preferredVideoStabilizationMode = .off
                }
                // Native horizontal FOV becomes vertical after portrait rotation.
                fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
                configured = true
            }
            if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
                fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
            }
            if !preparationStarted {
                preparationStarted = true
                report("Loading on-device vision…")
                Task { [weak self, worker] in
                    do {
                        try await worker.prepare()
                        guard let self else { return }
                        self.queue.async { self.modelReady = true; self.report("Vision ready") }
                    } catch {
                        self?.report("Vision unavailable: \(error.localizedDescription)")
                        if let self { self.queue.async { self.preparationStarted = false } }
                    }
                }
            }
            if !session.isRunning { session.startRunning() }
        } catch { report("Camera unavailable: \(error.localizedDescription)") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard settings.active, modelReady, !busy, settings.fps > 0,
              now - lastFrame >= 1 / settings.fps,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        busy = true; lastFrame = now
        let snapshot = settings
        let frame = VisionFrame(image: image, timestamp: now, verticalFOV: fov)
        Task { [weak self, worker] in
            let result = await worker.process(frame, speed: snapshot.speed, motion: snapshot.motion,
                                              generation: snapshot.generation)
            guard let self else { return }
            if let result { await self.output(result, snapshot.generation) }
            self.queue.async { self.busy = false }
        }
    }
}

final class CameraPreview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
struct CameraSurface: UIViewRepresentable {
    let pipeline: CameraPipeline
    func makeUIView(context: Context) -> CameraPreview {
        let view = CameraPreview()
        view.previewLayer.session = pipeline.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }
    func updateUIView(_ uiView: CameraPreview, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
    static func dismantleUIView(_ uiView: CameraPreview, coordinator: ()) { uiView.previewLayer.session = nil }
}
