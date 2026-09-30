import Foundation
import CoreGraphics

enum RiskLevel: Int, Comparable, Sendable, Codable {
    case clear, caution, danger
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var title: String { switch self { case .clear: "NO CONFLICT DETECTED"; case .caution: "CAUTION"; case .danger: "COLLISION RISK" } }
}
struct DetectionSample: Sendable {
    let label: String
    let confidence: Double
    /// Normalized, top-left origin in the upright, uncropped source image.
    let rect: CGRect
}
struct MotionSample: Sendable {
    var accelerationG = 0.0
    var rotationRate = 0.0
    var roll = 0.0
    var timestamp = 0.0
}
struct TrackedThreat: Identifiable, Sendable {
    let id: Int
    let label: String
    let rect: CGRect
    let level: RiskLevel
    let score: Double
    let timeToCollision: Double?
    let estimatedDistance: Double?
}
struct ThreatSnapshot: Sendable {
    var level: RiskLevel = .clear
    var label = ""
    var score = 0.0
    var timeToCollision: Double?
    var objects: [TrackedThreat] = []
    static let clear = ThreatSnapshot()
}
struct GeoPoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}
struct HazardZone: Identifiable, Codable, Sendable {
    let id: UUID
    let center: GeoPoint
    let radiusMeters: Double
    let severity: RiskLevel
    let source: String
    let observedAt: Date
}
struct HazardCorridor: Identifiable, Codable, Sendable {
    let id: UUID
    let points: [GeoPoint]
    let severity: RiskLevel
    let source: String
}
struct RideSummary: Identifiable, Sendable {
    let id = UUID()
    let duration: Double
    let distanceMeters: Double
    let maximumSpeedMPS: Double
    let warningCount: Int
    let safetyScore: Int
}
