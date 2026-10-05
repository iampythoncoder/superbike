import Foundation

/// Run on macOS with swiftc -swift-version 6 Models/SafetyModels.swift
/// Models/HazardDataset.swift Hazards/*.swift Validation/HazardChecks.swift -o /tmp/hazard-checks
/// Add --live to verify the real unauthenticated official API (network required).
@main struct HazardChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let now = Date()
        let origin = GeoPoint(latitude: 40.734, longitude: -73.990)
        let north = HazardGeometry.destination(from: origin, bearingDegrees: 0, meters: 100)
        expect(abs(HazardGeometry.distance(origin, north) - 100) < 0.01, "Haversine/destination must agree")
        let wrapped = HazardGeometry.destination(from: GeoPoint(latitude: 0, longitude: 179.9999), bearingDegrees: 90, meters: 100)
        expect(wrapped.longitude < 0 && wrapped.longitude >= -180, "Destination must wrap antimeridian")
        let midpoint = HazardGeometry.destination(from: origin, bearingDegrees: 0, meters: 50)
        expect(HazardGeometry.distance(from: midpoint, toSegment: origin, end: north) < 0.01, "Segment distance must include projected midpoint")

        let fixture = Data("""
        [
        {"collision_id":"a","crash_date":"2025-02-28T00:00:00.000","latitude":"40.734","longitude":"-73.990","number_of_cyclist_injured":"1","number_of_cyclist_killed":"0"},
        {"collision_id":42,"crash_date":"2025-03-01T00:00:00.000","latitude":40.735,"longitude":-73.990,"number_of_cyclist_injured":0,"number_of_cyclist_killed":1},
        {"collision_id":"a","crash_date":"2025-02-28T00:00:00.000","latitude":"40.734","longitude":"-73.990","number_of_cyclist_injured":"1","number_of_cyclist_killed":"0"},
        {"collision_id":"bad-coordinate","crash_date":"2025-02-28T00:00:00.000","latitude":"0","longitude":"0","number_of_cyclist_injured":"1","number_of_cyclist_killed":"0"},
        {"collision_id":"bad-count","crash_date":"2025-02-28T00:00:00.000","latitude":"40.734","longitude":"-73.990","number_of_cyclist_injured":"-1","number_of_cyclist_killed":"0"},
        {"collision_id":"future","crash_date":"2999-02-28T00:00:00.000","latitude":"40.734","longitude":"-73.990","number_of_cyclist_injured":"1","number_of_cyclist_killed":"0"},
        {"collision_id":"empty","crash_date":null,"latitude":null,"longitude":null}
        ]
        """.utf8)
        let decoded = try NYCCrashDataProvider.decode(fixture, now: now)
        expect(decoded.incidents.count == 2 && decoded.rejected == 5, "Normalize strings/numbers; reject duplicates, invalid, future and missing records")
        expect(decoded.incidents[1].id == "42" && decoded.incidents[1].cyclistsKilled == 1, "Numeric IDs and casualty counts must decode")
        do { _ = try NYCCrashDataProvider.decode(Data("{\"error\":\"rate limited\"}".utf8), now: now); preconditionFailure("Error envelope accepted") }
        catch { checks += 1 }
        expect(!NYCCrashDataProvider().coversVicinity(GeoPoint(latitude: 37.77, longitude: -122.42)), "Other cities must not be labeled covered")
        let query = try NYCCrashDataProvider().queryURL(near: origin, radiusMeters: 3_000, cutoff: now.addingTimeInterval(-86_400))
        let components = URLComponents(url: query, resolvingAgainstBaseURL: false)!
        expect(components.queryItems?.contains(where: { $0.name == "$limit" && $0.value == "5001" }) == true, "Query must bound row count")
        expect(components.queryItems?.contains(where: { $0.name == "$where" && $0.value!.contains("number_of_cyclist_killed > 0") }) == true, "Query must include cyclist fatalities")

        func snapshot(_ incidents: [CrashIncident], at fetched: Date = now, center: GeoPoint = origin) -> CrashFeedSnapshot {
            CrashFeedSnapshot(version: 1, providerID: "test", sourceName: "test fixture", sourceURL: "https://example.invalid/fixture",
                center: center, radiusMeters: 3_000, fetchedAt: fetched, historyStart: now.addingTimeInterval(-100_000),
                publisherUpdatedAt: now, incidents: incidents, truncated: false, rejectedRecords: 0)
        }
        let incidents = (0..<3).map { CrashIncident(id: String($0), point: origin,
            occurredAt: now.addingTimeInterval(-Double($0 + 1) * 86_400), cyclistsInjured: 1, cyclistsKilled: 0) }
        let built = CrashZoneBuilder.build(snapshot(incidents))
        expect(built.zones.count == 1 && built.zones[0].severity == .danger, "Repeated crashes must form a high-history zone")
        expect(built.detailsByID[built.zones[0].id]?.incidentCount == 3, "Actual incident count must be retained")
        expect(CrashZoneBuilder.build(snapshot(incidents.reversed())).zones[0].id == built.zones[0].id, "Zone IDs must survive provider reorder")
        expect(CrashZoneBuilder.build(snapshot([incidents[0]])).zones[0].severity == .caution, "One nonfatal record isn't a repeat-crash hotspot")
        let fatal = CrashIncident(id: "fatal", point: origin, occurredAt: now.addingTimeInterval(-86_400), cyclistsInjured: 0, cyclistsKilled: 1)
        expect(CrashZoneBuilder.build(snapshot([fatal])).zones[0].severity == .danger, "Fatal crash history must be highlighted")

        var engine = HazardEntryEngine()
        func evaluate(_ point: GeoPoint, time: Double, speed: Double = 0, course: Double? = nil,
                      accuracy: Double = 5, timestampOffset: Double = 0) -> HazardEntryAlert? {
            let date = now.addingTimeInterval(time)
            return engine.evaluate(zones: built.zones, location: point, speedMPS: speed, courseDegrees: course,
                horizontalAccuracy: accuracy, timestamp: date.addingTimeInterval(timestampOffset), now: date)
        }
        expect(evaluate(origin, time: 0, accuracy: 80) == nil, "Poor GPS must not trigger zone entry")
        expect(evaluate(origin, time: 0, timestampOffset: -20) == nil, "Stale GPS must not trigger zone entry")
        expect(evaluate(origin, time: 0) != nil, "First accurate entry must warn")
        expect(evaluate(origin, time: 40) == nil, "Remaining in a zone must not repeat warnings")
        let far = HazardGeometry.destination(from: origin, bearingDegrees: 0, meters: 500)
        expect(evaluate(far, time: 50) == nil, "Leaving a zone must not alert")
        expect(evaluate(origin, time: 60) == nil, "Rapid re-entry must respect cooldown")
        expect(evaluate(origin, time: 301) != nil, "Re-entry after cooldown must warn")
        engine.reset()
        let south = HazardGeometry.destination(from: origin, bearingDegrees: 180, meters: 90)
        expect(evaluate(south, time: 0, speed: 10, course: 180) == nil, "Moving away must not produce lookahead entry")
        expect(evaluate(south, time: 1, speed: 10, course: 0)?.approaching == true, "Speed/direction lookahead must warn before entry")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperbikeHazardChecks-\(UUID().uuidString)")
        let cache = CrashFeedCache(directory: directory)
        await cache.save(snapshot(incidents))
        let cached = await cache.load(providerID: "test", near: origin, now: now)
        expect(cached?.incidents.count == 3, "Cache must round-trip actual records")
        let stale = await cache.load(providerID: "test", near: origin, now: now.addingTimeInterval(8 * 86_400))
        expect(stale == nil, "Cache older than seven days must not be silently used")
        let distant = await cache.load(providerID: "test", near: GeoPoint(latitude: 40.80, longitude: -73.90), now: now)
        expect(distant == nil, "Cache from another area must not pass coverage check")
        // Only this test-owned, UUID-named directory is removed.
        try? FileManager.default.removeItem(at: directory)

        let service = HazardService()
        service.update(location: GeoPoint(latitude: 37.77, longitude: -122.42), speedMPS: 0,
            courseDegrees: nil, horizontalAccuracy: 5, timestamp: now, alertsEnabled: false)
        expect(service.coverage == .outsideCoverage && service.zones.isEmpty && !service.isLoading,
               "Unsupported location must explicitly show missing coverage")
        if CommandLine.arguments.contains("--live") {
            let live = try await NYCCrashDataProvider().fetch(near: origin, radiusMeters: 1_000, now: now)
            expect(!live.incidents.isEmpty, "Official live NYC endpoint should return real nearby records")
            expect(live.incidents.allSatisfy { HazardGeometry.distance(origin, $0.point) <= 1_000 }, "Live records must be inside requested radius")
            print("Live source: \(live.incidents.count) records; publisher updated \(String(describing: live.publisherUpdatedAt))")
        }
        print("Passed \(checks) hazard decoding, geometry, clustering, entry, cooldown, cache and coverage checks")
    }
}
