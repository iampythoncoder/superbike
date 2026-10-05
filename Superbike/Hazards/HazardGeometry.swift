import Foundation

/// Pure geometry shared by historical-zone clustering and entry detection.
enum HazardGeometry {
    static let earthRadius = 6_371_000.0

    static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite &&
        (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
    }

    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(sqrt(min(1, max(0, h))))
    }

    static func destination(from point: GeoPoint, bearingDegrees: Double, meters: Double) -> GeoPoint {
        let angular = meters / earthRadius, bearing = bearingDegrees * .pi / 180
        let latitude = point.latitude * .pi / 180, longitude = point.longitude * .pi / 180
        let targetLat = asin(sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(bearing))
        let targetLon = longitude + atan2(sin(bearing) * sin(angular) * cos(latitude),
                                          cos(angular) - sin(latitude) * sin(targetLat))
        return GeoPoint(latitude: targetLat * 180 / .pi,
                        longitude: (targetLon * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// Short local segment only (look-ahead is capped at 120 m). Longitude uses the
    /// local latitude scale; no fragile latitude/longitude degree-distance comparisons.
    static func distance(from point: GeoPoint, toSegment start: GeoPoint, end: GeoPoint) -> Double {
        let longitudeScale = cos(start.latitude * .pi / 180)
        func local(_ p: GeoPoint) -> (x: Double, y: Double) {
            let longitudeDelta = atan2(sin((p.longitude - start.longitude) * .pi / 180),
                                       cos((p.longitude - start.longitude) * .pi / 180))
            return (longitudeDelta * longitudeScale * earthRadius,
                    (p.latitude - start.latitude) * .pi / 180 * earthRadius)
        }
        let p = local(point), e = local(end), lengthSquared = e.x * e.x + e.y * e.y
        guard lengthSquared > 0.01 else { return distance(point, start) }
        let t = max(0, min(1, (p.x * e.x + p.y * e.y) / lengthSquared))
        return hypot(p.x - t * e.x, p.y - t * e.y)
    }
}

struct HazardEntryAlert: Identifiable, Sendable {
    let id = UUID()
    let zoneID: UUID
    let title: String
    let message: String
    let level: RiskLevel
    let approaching: Bool
}

/// Hysteresis prevents noisy GPS fixes from repeatedly entering the same zone.
/// This is an advisory based on historical records, never a live collision alarm.
struct HazardEntryEngine: Sendable {
    private var occupied: Set<UUID> = []
    private var lastAlert: [UUID: Date] = [:]
    private var lastGlobalAlert: Date?
    var perZoneCooldown: TimeInterval = 300
    var globalCooldown: TimeInterval = 25

    mutating func reset() {
        occupied.removeAll(); lastAlert.removeAll(); lastGlobalAlert = nil
    }

    mutating func evaluate(zones: [HazardZone], location: GeoPoint, speedMPS: Double,
                           courseDegrees: Double?, horizontalAccuracy: Double,
                           timestamp: Date, now: Date = Date()) -> HazardEntryAlert? {
        guard HazardGeometry.isValid(location), horizontalAccuracy.isFinite,
              (0...35).contains(horizontalAccuracy), abs(now.timeIntervalSince(timestamp)) <= 8,
              speedMPS.isFinite, speedMPS >= 0 else { return nil }
        let speed = min(25, speedMPS)
        let course = courseDegrees.flatMap { $0.isFinite && (0..<360).contains($0) ? $0 : nil }
        let ahead: GeoPoint?
        if let course, speed >= 1.5 {
            ahead = HazardGeometry.destination(from: location, bearingDegrees: course,
                                                meters: min(120, max(12, speed * 5)))
        } else { ahead = nil }

        let zoneIDs = Set(zones.map(\.id))
        occupied.formIntersection(zoneIDs)
        lastAlert = lastAlert.filter { zoneIDs.contains($0.key) || now.timeIntervalSince($0.value) < perZoneCooldown }
        var candidates: [(zone: HazardZone, distance: Double, approaching: Bool)] = []
        for zone in zones where zone.severity == .danger {
            let distance = HazardGeometry.distance(location, zone.center)
            let expandedExitRadius = zone.radiusMeters + max(35, horizontalAccuracy * 2) + speed * 6
            if occupied.contains(zone.id), distance > expandedExitRadius { occupied.remove(zone.id) }
            guard !occupied.contains(zone.id) else { continue }
            let inside = distance <= zone.radiusMeters
            let approaching = ahead.map {
                HazardGeometry.distance(from: zone.center, toSegment: location, end: $0) <= zone.radiusMeters &&
                HazardGeometry.distance($0, zone.center) < distance
            } ?? false
            guard inside || approaching else { continue }
            guard lastAlert[zone.id].map({ now.timeIntervalSince($0) >= perZoneCooldown }) ?? true else { continue }
            candidates.append((zone, distance, !inside))
        }
        // Do not mark zones as entered during another warning's cooldown: a later
        // accepted fix can still warn if the rider is still approaching/inside.
        guard lastGlobalAlert.map({ now.timeIntervalSince($0) >= globalCooldown }) ?? true,
              let next = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        occupied.insert(next.zone.id); lastAlert[next.zone.id] = now; lastGlobalAlert = now
        return HazardEntryAlert(zoneID: next.zone.id,
            title: next.approaching ? "CRASH HISTORY AHEAD" : "HIGH CRASH HISTORY AREA",
            message: next.approaching ? "Approaching an area with recorded serious or repeated bicycle crashes. Stay alert."
                                      : "You are in an area with recorded serious or repeated bicycle crashes. Stay alert.",
            level: .caution, approaching: next.approaching)
    }
}
