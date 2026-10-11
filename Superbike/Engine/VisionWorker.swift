import CoreGraphics
import Foundation
import UltralyticsYOLO

/// CGImage is immutable here; camera creates an owned image before crossing isolation.
struct VisionFrame: @unchecked Sendable {
    let image: CGImage
    let timestamp: Double
    let verticalFOV: Double
}
struct VisionOutput: Sendable {
    let valid: Bool
    let threat: ThreatSnapshot
    let timestamp: Double
    let imageSize: CGSize
}

actor VisionWorker {
    private var model: YOLO?
    private var loadingModel: YOLO?
    private var engine = RiskEngine()
    private var generation: UUID?

    func prepare() async throws {
        guard model == nil else { return }
        let loaded: YOLO = try await withCheckedThrowingContinuation { continuation in
            // Retain while loading: upstream completion captures its instance weakly.
            loadingModel = YOLO("yolo26n", task: .detect, numItemsThreshold: 30) { result in
                continuation.resume(with: result)
            }
        }
        model = loaded
        loadingModel = nil
        loaded.setThresholds(numItems: 30, confidence: 0.5, iou: 0.5)
    }

    func process(_ frame: VisionFrame, speed: Double, motion: MotionSample, generation: UUID) -> VisionOutput? {
        guard let model else { return nil }
        if self.generation != generation { engine.reset(); self.generation = generation }
        // No suspension from inference through result projection: upstream's mutable
        // predictor is only accessed here, despite its @unchecked Sendable declaration.
        return autoreleasepool {
            let result = model(frame.image)
            let detections = result.boxes.map {
                DetectionSample(label: $0.cls, confidence: Double($0.conf), rect: $0.xywhn)
            }
            if !result.inferenceSucceeded { engine.reset() }
            let threat = engine.evaluate(detections: detections, speedMPS: speed,
                motion: motion, verticalFOV: frame.verticalFOV, timestamp: frame.timestamp)
            return VisionOutput(valid: result.inferenceSucceeded, threat: threat, timestamp: frame.timestamp,
                                imageSize: CGSize(width: frame.image.width, height: frame.image.height))
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
