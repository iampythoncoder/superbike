import Foundation
import CoreGraphics

@main struct RiskEngineChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func box(_ height: Double, x: Double = 0.5, label: String = "car") -> DetectionSample {
            DetectionSample(label: label, confidence: 0.9,
                rect: CGRect(x: x - height / 2, y: 0.65 - height / 2, width: height, height: height))
        }
        var engine = RiskEngine()
        var result = ThreatSnapshot.clear
        for i in 0..<20 {
            result = engine.evaluate(detections: [box(0.18)], speedMPS: 0,
                motion: MotionSample(), verticalFOV: 1.1, timestamp: Double(i) * 0.1)
        }
        expect(result.level == .clear && result.timeToCollision == nil, "Static boxes must not produce TTC")
        let id = result.objects[0].id
        result = engine.evaluate(detections: [box(0.18)], speedMPS: 0, motion: MotionSample(), verticalFOV: 1.1, timestamp: 2)
        expect(result.objects.first?.id == id, "Stable tracks must retain ID")
        engine.reset()
        for i in 0..<18 {
            let time = Double(i) * 0.1
            result = engine.evaluate(detections: [box(0.12 / (1 - time / 3))], speedMPS: 6,
                motion: MotionSample(timestamp: time), verticalFOV: 1.1, timestamp: time)
        }
        expect(result.level == .danger, "Constant-speed approach should trigger danger")
        expect((result.timeToCollision ?? 100) < 2.5, "Approach TTC must be bounded")
        engine.reset()
        for i in 0..<18 {
            let time = Double(i) * 0.1
            result = engine.evaluate(detections: [box(0.12 / (1 - time / 3))], speedMPS: 6,
                motion: MotionSample(accelerationG: 0.9, rotationRate: 2, roll: 0.3, timestamp: time),
                verticalFOV: 1.1, timestamp: time)
        }
        expect(result.timeToCollision == nil && result.level != .danger, "Shaking camera must suppress TTC danger")
        engine.reset()
        result = engine.evaluate(detections: [box(0.18, label: "bus")], speedMPS: 0,
            motion: MotionSample(), verticalFOV: 1.1, timestamp: 1)
        let busRange = result.objects[0].estimatedDistance!
        engine.reset()
        result = engine.evaluate(detections: [box(0.18)], speedMPS: 0,
            motion: MotionSample(), verticalFOV: 1.1, timestamp: 1)
        expect(busRange > result.objects[0].estimatedDistance! * 2, "Class priors must affect range")
        result = engine.evaluate(detections: [DetectionSample(label: "car", confidence: .nan, rect: .zero)],
            speedMPS: 0, motion: MotionSample(), verticalFOV: 1.1, timestamp: 2)
        expect(result.objects.isEmpty, "Reject invalid detections")
        engine.reset()
        result = engine.evaluate(detections: [box(0.1, x: 0.35), box(0.1, x: 0.65)], speedMPS: 0,
            motion: MotionSample(), verticalFOV: 1.1, timestamp: 1)
        expect(Set(result.objects.map(\.id)).count == 2, "Separate objects require separate tracks")
        let ids = result.objects.map(\.id)
        result = engine.evaluate(detections: [box(0.1, x: 0.65), box(0.1, x: 0.35)], speedMPS: 0,
            motion: MotionSample(), verticalFOV: 1.1, timestamp: 1.1)
        expect(result.objects.map(\.id) == ids.reversed(), "Detection order must not change identities")
        result = engine.evaluate(detections: [box(0.1)], speedMPS: 0,
            motion: MotionSample(), verticalFOV: 0, timestamp: 3)
        expect(result.objects[0].estimatedDistance == nil, "Invalid FOV must suppress distance")
        let empty = try HazardDataset.decode(Data("{\"zones\":[],\"corridors\":[]}".utf8))
        expect(empty.zones.isEmpty, "Empty sourced dataset is valid")
        let invalid = """
        {"zones":[{"id":"00000000-0000-0000-0000-000000000001","center":{"latitude":100,"longitude":0},"radiusMeters":20,"severity":2,"source":"test","observedAt":"2020-01-01T00:00:00Z"}],"corridors":[]}
        """
        do { _ = try HazardDataset.decode(Data(invalid.utf8)); preconditionFailure("Invalid latitude accepted") }
        catch { checks += 1 }
        print("Passed \(checks) deterministic risk and dataset checks")
    }
}
