import Foundation

struct LocationSample: Sendable {
    let point: GeoPoint
    let accuracy: Double
    let speed: Double
    let course: Double
    let timestamp: Double
    var speedAccuracy: Double = -1
    var courseAccuracy: Double = -1
}
struct TelemetryUpdate: Sendable {
    let point: GeoPoint
    let speed: Double
    let speedAvailable: Bool
    let course: Double?
    let distance: Double
    let accuracy: Double
    let timestamp: Double
    let usableForRoute: Bool
}

/// Pure filtering logic also used by deterministic tests. Location usability and
/// speed validity are separate: a coarse map fix must not fabricate a speed.
struct TelemetryFilter: Sendable {
    private var previous: LocationSample?
    private var distance = 0.0
    mutating func reset() { previous = nil; distance = 0 }
    mutating func ingest(_ sample: LocationSample, now: Double) -> TelemetryUpdate? {
        guard sample.point.latitude.isFinite, sample.point.longitude.isFinite,
              abs(sample.point.latitude) <= 90, abs(sample.point.longitude) <= 180,
              sample.accuracy.isFinite, sample.accuracy >= 0, sample.accuracy <= 200,
              sample.timestamp.isFinite, now - sample.timestamp < 10,
              sample.timestamp - now < 2 else { return nil }
        var speed: Double? = sample.speed.isFinite && (0...55).contains(sample.speed)
            && sample.speedAccuracy.isFinite && (0...8).contains(sample.speedAccuracy) ? sample.speed : nil
        var course: Double? = nil
        if let previous {
            let dt = sample.timestamp - previous.timestamp
            guard dt > 0 else { return nil }
            let meters = Self.meters(previous.point, sample.point)
            // Ignore physically implausible jumps without poisoning the last good fix.
            if dt < 10 && meters > max(80, dt * 55 + previous.accuracy + sample.accuracy) { return nil }
            if speed == nil, (1...8).contains(dt), max(previous.accuracy, sample.accuracy) <= 15,
               meters > max(3, (previous.accuracy + sample.accuracy) * 0.5), meters / dt < 35 {
                speed = meters / dt
            }
            if sample.accuracy <= 35 && previous.accuracy <= 35 && dt <= 8,
               let speed, speed > 0.7, meters < dt * 55,
               meters > min(2, (sample.accuracy + previous.accuracy) * 0.1) {
                distance += meters
            }
        }
        if let speed, speed > 1, sample.course.isFinite, (0..<360).contains(sample.course),
           sample.courseAccuracy.isFinite, (0...45).contains(sample.courseAccuracy) { course = sample.course }
        previous = sample
        return TelemetryUpdate(point: sample.point, speed: speed ?? 0, speedAvailable: speed != nil,
            course: course, distance: distance, accuracy: sample.accuracy, timestamp: sample.timestamp,
            usableForRoute: sample.accuracy <= 35)
    }
    static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}
actor TelemetryWorker {
    private var epoch = -1
    private var filter = TelemetryFilter()
    func ingest(_ sample: LocationSample, epoch: Int, now: Double = Date().timeIntervalSince1970) -> TelemetryUpdate? {
        guard epoch >= self.epoch else { return nil }
        if epoch != self.epoch { self.epoch = epoch; filter.reset() }
        return filter.ingest(sample, now: now)
    }
}
