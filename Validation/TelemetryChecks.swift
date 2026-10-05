import Foundation

@main struct TelemetryChecks {
    static func main() async {
        let now = 1000.0
        let origin = GeoPoint(latitude: 40.7, longitude: -74)
        var filter = TelemetryFilter()
        func sample(_ point: GeoPoint, _ time: Double, speed: Double = 0, accuracy: Double = 5) -> LocationSample {
            LocationSample(point: point, accuracy: accuracy, speed: speed, course: 90,
                timestamp: time, speedAccuracy: 0.5, courseAccuracy: 5)
        }
        let stationary = filter.ingest(sample(origin, now), now: now)!
        precondition(stationary.speedAvailable && stationary.speed == 0 && stationary.distance == 0)
        let second = filter.ingest(sample(origin, now + 1), now: now + 1)!
        precondition(second.distance == 0, "Stationary GPS must not accumulate distance")
        let east = GeoPoint(latitude: 40.7, longitude: -73.9999)
        let moving = filter.ingest(sample(east, now + 2, speed: 8), now: now + 2)!
        precondition(moving.distance > 7 && moving.distance < 10 && moving.course == 90)
        precondition(filter.ingest(sample(origin, now + 1), now: now + 2) == nil, "Reject out-of-order fixes")
        let jump = GeoPoint(latitude: 41.7, longitude: -74)
        precondition(filter.ingest(sample(jump, now + 3, speed: 8), now: now + 3) == nil)
        precondition(filter.ingest(sample(origin, now - 30), now: now) == nil)
        var invalidSpeed = sample(east, now + 3, speed: -1, accuracy: 80)
        invalidSpeed.speedAccuracy = -1
        let coarse = filter.ingest(invalidSpeed, now: now + 3)!
        precondition(!coarse.speedAvailable && !coarse.usableForRoute, "Coarse location cannot fabricate valid speed")
        let worker = TelemetryWorker()
        _ = await worker.ingest(sample(origin, now), epoch: 2, now: now)
        let old = await worker.ingest(sample(east, now + 1), epoch: 1, now: now + 1)
        precondition(old == nil, "Prior ride must not reset current ride accumulator")
        print("Passed 8 GPS telemetry checks")
    }
}
