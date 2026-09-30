import Foundation
import CoreGraphics

/// Deterministic estimator. All inputs use the same monotonic clock.
/// Physical size priors are NOT calibrated distance measurements.
struct RiskEngine: Sendable {
    struct Configuration: Sendable {
        var cautionTTC = 4.0
        var dangerTTC = 2.0
        var minimumConfidence = 0.5
        var trackExpiry = 0.6
        var releaseDelay = 0.8
        var minimumTrackAge = 0.35
        var nominalHeights: [String: Double] = ["person": 1.7, "car": 1.5, "bus": 3.2,
            "truck": 3.0, "bicycle": 1.4, "motorcycle": 1.3]
    }
    private struct Track: Sendable {
        var id: Int
        var label: String
        var rect: CGRect
        var timestamp: Double
        var firstSeen: Double
        var expansion = 0.0
        var velocityX = 0.0
        var samples = 1
        var level = RiskLevel.clear
        var lastElevated = 0.0
    }
    var configuration = Configuration()
    private var tracks: [Track] = []
    private var nextID = 0
    mutating func reset() { tracks.removeAll(); nextID = 0 }

    mutating func evaluate(detections: [DetectionSample], speedMPS: Double,
                           motion: MotionSample, verticalFOV: Double,
                           timestamp: Double) -> ThreatSnapshot {
        tracks.removeAll { timestamp - $0.timestamp > configuration.trackExpiry }
        var used = Set<Int>()
        var output: [TrackedThreat] = []
        let moving = speedMPS.isFinite && speedMPS > 1
        let motionFresh = abs(timestamp - motion.timestamp) < 0.5
        let unstable = motionFresh && (motion.rotationRate > 0.8 || motion.accelerationG > 0.55 || abs(motion.roll) > 0.45)
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }).prefix(30) {
            let r = detection.rect
            guard let height = configuration.nominalHeights[detection.label],
                  detection.confidence.isFinite, detection.confidence >= configuration.minimumConfidence,
                  [r.minX, r.minY, r.width, r.height].allSatisfy({ $0.isFinite }),
                  r.width > 0.015, r.height > 0.025, r.minX >= 0, r.minY >= 0,
                  r.maxX <= 1.001, r.maxY <= 1.001 else { continue }
            // One-to-one class-constrained matching, with a scale gate to avoid ID swaps.
            let match = tracks.indices.filter {
                !used.contains(tracks[$0].id) && tracks[$0].label == detection.label &&
                abs(log(r.height / tracks[$0].rect.height)) < 0.45 &&
                hypot(r.midX - tracks[$0].rect.midX, r.midY - tracks[$0].rect.midY) < 0.15
            }.min { a, b in
                hypot(r.midX - tracks[a].rect.midX, r.midY - tracks[a].rect.midY) <
                hypot(r.midX - tracks[b].rect.midX, r.midY - tracks[b].rect.midY)
            }
            var track: Track
            if let match { track = tracks[match] } else {
                nextID += 1
                track = Track(id: nextID, label: detection.label, rect: r,
                              timestamp: timestamp, firstSeen: timestamp)
            }
            let dt = timestamp - track.timestamp
            if dt > 0.015 && dt < 0.5 {
                // d(log(height))/dt approximates closing speed / range.
                let alpha = 1 - exp(-dt / 0.35)
                let rate = log(r.height / track.rect.height) / dt
                track.expansion += alpha * (max(-2, min(2, rate)) - track.expansion)
                track.velocityX += alpha * ((r.midX - track.rect.midX) / dt - track.velocityX)
                track.samples += 1
            }
            let mature = track.samples >= 4 && timestamp - track.firstSeen >= configuration.minimumTrackAge
            let clipped = r.minY < 0.015 || r.maxY > 0.985 || r.minX < 0.01 || r.maxX > 0.99
            let ttc: Double? = mature && !unstable && !clipped && track.expansion > 0.06
                ? min(20, 1 / track.expansion) : nil
            // Pinhole estimate: range = nominalHeight / (2 * normalizedHeight * tan(FOV/2)).
            let range: Double? = !clipped && verticalFOV > 0.2 && verticalFOV < 2.8
                ? height / (2 * r.height * tan(verticalFOV / 2)) : nil
            let halfWidth = 0.08 + 0.24 * max(0, min(1, r.maxY))
            let path = r.maxY > 0.35 && r.maxX > 0.5 - halfWidth && r.minX < 0.5 + halfWidth
            let predictedX = r.midX + track.velocityX * 0.6
            let entering = mature && !unstable && abs(predictedX - 0.5) < halfWidth &&
                abs(predictedX - 0.5) < abs(r.midX - 0.5) - 0.025
            var level = RiskLevel.clear
            var score = 0.0
            if path || entering {
                if let ttc {
                    let margin = moving ? min(1.0, speedMPS / 12) : 0
                    if ttc < configuration.dangerTTC + margin { level = .danger; score = 0.9 }
                    else if ttc < configuration.cautionTTC + margin { level = .caution; score = 0.6 }
                }
                // A size/ego-speed prior can justify caution, never danger by itself.
                if moving, let range, range < max(4, speedMPS * 1.5), level == .clear {
                    level = .caution; score = 0.5
                }
                if moving && entering && level == .clear { level = .caution; score = 0.45 }
            }
            if level >= track.level { track.lastElevated = timestamp }
            else if timestamp - track.lastElevated < configuration.releaseDelay { level = track.level }
            track.level = level; track.rect = r; track.timestamp = timestamp
            used.insert(track.id)
            if let match { tracks[match] = track } else { tracks.append(track) }
            output.append(TrackedThreat(id: track.id, label: track.label, rect: r, level: level,
                score: max(score, level == .danger ? 0.8 : level == .caution ? 0.4 : 0),
                timeToCollision: ttc, estimatedDistance: range))
        }
        let strongest = output.max { $0.level == $1.level ? $0.score < $1.score : $0.level < $1.level }
        return ThreatSnapshot(level: strongest?.level ?? .clear, label: strongest?.label ?? "",
            score: strongest?.score ?? 0, timeToCollision: strongest?.timeToCollision, objects: output)
    }
}
