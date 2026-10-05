import Foundation

/// Value-only route math. Coordinates stay in WGS84 and distances are meters.
struct NavigationGeometry: Sendable {
    struct Match: Sendable {
        let distanceAlong: Double
        let distanceFromRoute: Double
        let segmentIndex: Int
    }

    let points: [GeoPoint]
    let cumulative: [Double]
    var distance: Double { cumulative.last ?? 0 }

    init(points: [GeoPoint]) {
        self.points = points.filter(Self.isValid)
        var cumulative = [Double]()
        cumulative.reserveCapacity(self.points.count)
        for index in self.points.indices {
            if index == 0 { cumulative.append(0) }
            else { cumulative.append(cumulative[index - 1] + Self.distance(self.points[index - 1], self.points[index])) }
        }
        self.cumulative = cumulative
    }

    /// Constraining the along-route window avoids jumping ahead when a route crosses itself.
    func match(_ point: GeoPoint, from minimum: Double = 0, through maximum: Double? = nil) -> Match? {
        guard points.count > 1, Self.isValid(point) else { return nil }
        let lower = max(0, minimum), upper = min(distance, maximum ?? distance)
        guard lower <= upper else { return nil }
        var best: Match?
        for index in 0..<(points.count - 1) {
            let start = cumulative[index], end = cumulative[index + 1]
            guard end >= lower, start <= upper else { continue }
            let length = end - start
            guard length > 0.01 else { continue }
            let a = Self.localXY(points[index], relativeTo: point)
            let b = Self.localXY(points[index + 1], relativeTo: point)
            let dx = b.x - a.x, dy = b.y - a.y
            let squaredLength = dx * dx + dy * dy
            guard squaredLength > 0 else { continue }
            let minimumT = max(0, (lower - start) / length)
            let maximumT = min(1, (upper - start) / length)
            let t = min(maximumT, max(minimumT, -(a.x * dx + a.y * dy) / squaredLength))
            let deviation = hypot(a.x + t * dx, a.y + t * dy)
            if best == nil || deviation < best!.distanceFromRoute {
                best = Match(distanceAlong: start + t * length, distanceFromRoute: deviation, segmentIndex: index)
            }
        }
        return best
    }

    static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite &&
        (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
    }

    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = Double.pi / 180
        let dLatitude = (b.latitude - a.latitude) * r
        let dLongitude = wrappedLongitude(b.longitude - a.longitude) * r
        let h = pow(sin(dLatitude / 2), 2) + cos(a.latitude * r) * cos(b.latitude * r) * pow(sin(dLongitude / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(max(0, min(1, h))), sqrt(max(0, 1 - min(1, h))))
    }

    private static func localXY(_ point: GeoPoint, relativeTo origin: GeoPoint) -> (x: Double, y: Double) {
        let scale = Double.pi / 180 * 6_371_000
        return (wrappedLongitude(point.longitude - origin.longitude) * scale * cos(origin.latitude * .pi / 180),
                (point.latitude - origin.latitude) * scale)
    }

    private static func wrappedLongitude(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

/// Requires sustained deviation before rerouting, and caps requests during GPS noise.
struct NavigationOffRouteMonitor: Sendable {
    private(set) var isOffRoute = false
    private var beganAt: Double?
    private var lastReroute = -Double.infinity

    mutating func clearEvidence() {
        beganAt = nil; isOffRoute = false
    }

    mutating func update(deviation: Double, accuracy: Double, timestamp: Double) -> Bool {
        guard deviation.isFinite, accuracy.isFinite, timestamp.isFinite, (0...65).contains(accuracy) else {
            clearEvidence(); return false
        }
        let threshold = max(35, min(70, accuracy * 1.7))
        if deviation > threshold {
            if beganAt == nil { beganAt = timestamp }
            isOffRoute = timestamp - (beganAt ?? timestamp) >= 3
            if timestamp - (beganAt ?? timestamp) >= 8 && timestamp - lastReroute >= 20 {
                lastReroute = timestamp
                return true
            }
        } else {
            beganAt = nil
            isOffRoute = false
        }
        return false
    }
}
