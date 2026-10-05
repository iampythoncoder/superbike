import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UltralyticsYOLO

/// Capture retains this buffer until inference returns. Neither side mutates it,
/// and the capture queue admits at most one frame globally, bounding retained memory.
struct VisionFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let side: CameraSide
    let timestamp: Double
    let verticalFOV: Double
}
struct VisionOutput: Sendable {
    let side: CameraSide
    let valid: Bool
    let threat: ThreatSnapshot
    let timestamp: Double
    let imageSize: CGSize
}

actor VisionWorker {
    private var model: YOLO?
    private var loadingModel: YOLO?
    private var engines: [CameraSide: RiskEngine] = [:]
    private var generation: UUID?

    func prepare() async throws {
        guard model == nil else { return }
        let loaded: YOLO
        do { loaded = try await withCheckedThrowingContinuation { continuation in
            // Retain while loading: upstream completion captures its instance weakly.
            loadingModel = YOLO("yolo26n", task: .detect, numItemsThreshold: 30) { result in
                continuation.resume(with: result)
            }
        } } catch { loadingModel = nil; throw error }
        model = loaded
        loadingModel = nil
        loaded.setThresholds(numItems: 30, confidence: 0.5, iou: 0.5)
    }

    func process(_ frame: VisionFrame, speed: Double, motion: MotionSample, generation: UUID) -> VisionOutput? {
        guard let model else { return nil }
        if self.generation != generation { engines.removeAll(); self.generation = generation }
        // No suspension from inference through result projection: upstream's mutable
        // predictor is only accessed here, despite its @unchecked Sendable declaration.
        return autoreleasepool {
            let result = model(CIImage(cvPixelBuffer: frame.buffer))
            let detections = result.boxes.map {
                DetectionSample(label: $0.cls, confidence: Double($0.conf), rect: $0.xywhn)
            }
            var engine = engines[frame.side] ?? RiskEngine()
            if !result.inferenceSucceeded { engine.reset() }
            // Rider speed cannot imply closing speed for a camera looking backwards.
            // Rear warnings use measured optical expansion; this also avoids treating
            // the rider's stationary torso as an obstacle we are riding toward.
            let threat = engine.evaluate(detections: detections, speedMPS: frame.side == .rear ? 0 : speed,
                motion: motion, verticalFOV: frame.verticalFOV, timestamp: frame.timestamp)
            engines[frame.side] = engine
            return VisionOutput(side: frame.side, valid: result.inferenceSucceeded, threat: threat,
                timestamp: frame.timestamp, imageSize: CGSize(width: CVPixelBufferGetWidth(frame.buffer),
                                                            height: CVPixelBufferGetHeight(frame.buffer)))
        }
    }
}

enum DetectionBudget {
    static func fps(speed: Double, thermal: ProcessInfo.ThermalState, lowPower: Bool, recording: Bool) -> Double {
        if thermal == .critical { return 0 }
        var target = speed > 5 ? 20.0 : 10.0
        if thermal == .fair { target = min(target, 12) }
        if thermal == .serious { target = 5 }
        if lowPower || recording { target = min(target, 10) }
        return target
    }
}
