import Foundation

@main struct RegionalCoverageChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cary = try HeatmapRegion.load(.cary, resourceDirectory: resources)
        let district = try HeatmapRegion.load(.district, resourceDirectory: resources)
        let community = try HeatmapRegion.load(.community, resourceDirectory: resources)
        let downtown = GeoPoint(latitude: 35.7877, longitude: -78.7811)
        let raleigh = GeoPoint(latitude: 35.7796, longitude: -78.6382)
        expect(cary.contains(downtown), "Official town polygon must include downtown Cary")
        expect(district.contains(raleigh), "Current NC-02 polygon must include downtown Raleigh")
        expect(cary.outlines.count > 1, "Preserve Cary's disconnected areas and municipal holes")
        expect(community.bounds.west <= cary.bounds.west && community.bounds.east >= district.bounds.east,
               "Combined coverage must enclose both jurisdictions")
        let charlotte = GeoPoint(latitude: 35.2271, longitude: -80.8431)
        expect(!community.contains(charlotte), "Do not label other NC cities as Cary or NC-02")
        for point in [downtown, raleigh, charlotte, GeoPoint(latitude: 35.981, longitude: -78.513)] {
            expect(community.contains(point) == (cary.contains(point) || district.contains(point)), "Combined coverage must be a union")
        }
        func square(_ delta: Double) -> [GeoPoint] {
            [GeoPoint(latitude: 35.8 - delta, longitude: -78.8 - delta),
             GeoPoint(latitude: 35.8 - delta, longitude: -78.8 + delta),
             GeoPoint(latitude: 35.8 + delta, longitude: -78.8 + delta),
             GeoPoint(latitude: 35.8 + delta, longitude: -78.8 - delta),
             GeoPoint(latitude: 35.8 - delta, longitude: -78.8 - delta)]
        }
        let withHole = HeatmapRegion(area: .cary, polygons: [[square(0.02), square(0.01)]],
            bounds: HeatmapBounds(west: -78.82, south: 35.78, east: -78.78, north: 35.82))
        expect(!withHole.contains(GeoPoint(latitude: 35.8, longitude: -78.8)), "Municipal holes must not be filled")
        expect(withHole.contains(GeoPoint(latitude: 35.815, longitude: -78.8)), "Land outside a hole must remain included")
        let overlap = HeatmapRegion(area: .community, polygons: [[square(0.02)], [square(0.02)]], bounds: withHole.bounds)
        expect(overlap.contains(GeoPoint(latitude: 35.8, longitude: -78.8)), "Overlapping Cary/district polygons must not cancel each other")

        if CommandLine.arguments.contains("--live") {
            let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "RegionalCoverageChecks-\(UUID().uuidString)")
            let repository = RegionalHeatmapRepository(resourceDirectory: resources, cacheDirectory: cacheURL)
            let snapshot = try await repository.fetch(community, now: Date())
            expect(!snapshot.truncated && !snapshot.incidents.isEmpty, "Regional query must return complete paginated data")
            expect(snapshot.incidents.allSatisfy { community.contains($0.point) }, "Every record must lie in Cary or NC-02")
            expect(Set(snapshot.incidents.map(\.id)).count == snapshot.incidents.count, "No duplicate crashes across pages or jurisdictions")
            let inCary = snapshot.incidents.filter { cary.contains($0.point) }.count
            let inDistrict = snapshot.incidents.filter { district.contains($0.point) }.count
            expect(inCary > 23 && inDistrict > 23, "Coverage must extend well beyond the old downtown sample")
            expect(snapshot.incidents.contains { HazardGeometry.distance(downtown, $0.point) > 15_000 }, "District coverage must reach beyond Cary")
            await repository.save(snapshot, area: .community)
            let cached = await repository.cached(.community, now: Date())
            expect(cached?.incidents.count == snapshot.incidents.count, "Wide-area data must survive offline caching")
            let otherArea = await repository.cached(.cary, now: Date())
            expect(otherArea == nil, "A combined cache cannot be mislabeled as Cary-only")
            let stale = await repository.cached(.community, now: Date().addingTimeInterval(8 * 86_400))
            expect(stale == nil, "Reject stale regional caches")
            let build = await repository.build(snapshot)
            expect(!build.zones.isEmpty && build.zones.count <= snapshot.incidents.count, "Regional crash data must produce map zones")
            print("Live complete coverage: \(snapshot.incidents.count) unique bicycle crashes, \(build.zones.count) zones; Cary: \(inCary), current NC-02: \(inDistrict) (overlap counted in each)")
            try? FileManager.default.removeItem(at: cacheURL)
        }
        print("Passed \(checks) regional boundary, coverage, cache and map checks")
    }
}
