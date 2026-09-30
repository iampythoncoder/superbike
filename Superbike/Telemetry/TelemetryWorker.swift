import Foundation

struct LocationSample: Sendable {
    let point: GeoPoint
    let accuracy: Double
    let speed: Double
    let course: Double
    let timestamp: Double
}
struct TelemetryUpdate: Sendable {
    let point: GeoPoint
    let speed: Double
    let course: Double?
    let distance: Double
}
actor TelemetryWorker {
    private var generation: UUID?
    private var previous: LocationSample?
    private var distance = 0.0
    func ingest(_ sample: LocationSample, generation: UUID) -> TelemetryUpdate? {
        if self.generation != generation { self.generation = generation; previous = nil; distance = 0 }
        guard sample.accuracy >= 0, sample.accuracy <= 25,
              abs(Date().timeIntervalSince1970 - sample.timestamp) < 5,
              abs(sample.point.latitude) <= 90, abs(sample.point.longitude) <= 180 else { return nil }
        var course: Double?
        let speed = sample.speed >= 0 && sample.speed < 35 ? sample.speed : 0
        if sample.course >= 0 && speed > 1.5 { course = sample.course }
        if let previous {
            let dt = sample.timestamp - previous.timestamp
            guard dt > 0 else { return nil }
            let lat1 = previous.point.latitude * .pi / 180
            let lat2 = sample.point.latitude * .pi / 180
            let dLat = lat2 - lat1
            let dLon = (sample.point.longitude - previous.point.longitude) * .pi / 180
            let a = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
            let meters = 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
            if dt < 6 && meters / dt < 35 && speed > 0.8 { distance += meters }
        }
        previous = sample
        return TelemetryUpdate(point: sample.point, speed: speed, course: course, distance: distance)
    }
}
