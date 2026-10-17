import Foundation

private struct FixtureRouter: BicycleRouting {
    let plan: BicycleRoutePlan
    func route(from origin: GeoPoint, to destination: GeoPoint) async throws -> BicycleRoutePlan { plan }
}
@MainActor private final class CueProbe {
    var accepted = false
    var attempts = 0
}

@main struct CaryNavigationChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let origin = GeoPoint(latitude: 35.7877, longitude: -78.7811)
        let destination = GeoPoint(latitude: 35.7849, longitude: -78.7801)
        let query = try OSRMBicycleRouter.queryURL(from: origin, to: destination)
        expect(query.host == "routing.openstreetmap.de" && query.path.contains("/routed-bike/"), "Must query bicycle graph, never car demo graph")
        expect(query.absoluteString.contains("radiuses=100;100") || query.absoluteString.contains("radiuses=100%3B100"), "Bound endpoint snapping")
        func response(mode: String = "cycling", code: String = "Ok") -> Data {
            Data("""
            {"code":"\(code)","routes":[{"distance":340,"duration":110,
            "geometry":{"type":"LineString","coordinates":[[-78.7811,35.7877],[-78.7811,35.7865],[-78.7801,35.7849]]},
            "legs":[{"summary":"Academy Street","steps":[
            {"mode":"\(mode)","name":"Academy Street","maneuver":{"location":[-78.7811,35.7877],"type":"depart"}},
            {"mode":"\(mode)","name":"Park Street","maneuver":{"location":[-78.7811,35.7865],"type":"turn","modifier":"left"}},
            {"mode":"\(mode)","name":"","maneuver":{"location":[-78.7801,35.7849],"type":"arrive"}}]}]}]}
            """.utf8)
        }
        let plan = try OSRMBicycleRouter.decode(response(), origin: origin, destination: destination)
        expect(plan.steps.count == 2 && plan.steps[1].instruction == "Turn left onto Park Street", "Real maneuver locations and directions must survive decoding")
        do { _ = try OSRMBicycleRouter.decode(response(mode: "driving"), origin: origin, destination: destination); preconditionFailure("Car route accepted") }
        catch { checks += 1 }
        do { _ = try OSRMBicycleRouter.decode(response(code: "NoRoute"), origin: origin, destination: destination); preconditionFailure("NoRoute accepted") }
        catch { checks += 1 }
        do { _ = try OSRMBicycleRouter.decode(response(), origin: GeoPoint(latitude: 35, longitude: -78), destination: destination); preconditionFailure("Distant snap accepted") }
        catch { checks += 1 }

        let navigation = NavigationCoordinator(bicycleRouter: FixtureRouter(plan: plan))
        let target = NavigationDestination(title: "Cary Regional Library", point: destination)
        await navigation.preview(destination: target, from: origin)
        expect(navigation.canStart && navigation.routePoints == plan.points, "Bicycle preview must produce a startable route")
        let probe = CueProbe()
        navigation.onCue = { _ in probe.attempts += 1; return probe.accepted }
        navigation.start()
        expect(navigation.isNavigating, "Go starts navigation")
        let now = Date().timeIntervalSince1970
        let nearTurn = GeoPoint(latitude: 35.7866, longitude: -78.7811)
        navigation.updateLocation(point: nearTurn, speed: 5, accuracy: 5, timestamp: now)
        let firstAttempts = probe.attempts
        navigation.updateLocation(point: nearTurn, speed: 5, accuracy: 5, timestamp: now + 1)
        expect(probe.attempts > firstAttempts, "Rejected speech must retry on next fix")
        probe.accepted = true
        navigation.updateLocation(point: nearTurn, speed: 5, accuracy: 5, timestamp: now + 2)
        let acceptedCount = probe.attempts
        navigation.updateLocation(point: nearTurn, speed: 5, accuracy: 5, timestamp: now + 3)
        expect(probe.attempts == acceptedCount, "Accepted turn cue must not repeat")
        // Progress in small GPS steps, then dwell at the actual destination.
        for i in 1...12 {
            let fraction = Double(i) / 12
            let point = GeoPoint(latitude: nearTurn.latitude + (destination.latitude - nearTurn.latitude) * fraction,
                                 longitude: nearTurn.longitude + (destination.longitude - nearTurn.longitude) * fraction)
            navigation.updateLocation(point: point, speed: 5, accuracy: 5, timestamp: now + 3 + Double(i) * 3)
        }
        navigation.updateLocation(point: destination, speed: 0, accuracy: 5, timestamp: now + 45)
        expect(navigation.hasArrived && !navigation.isNavigating, "Route progress must reach arrival")
        navigation.stop()
        expect(navigation.routePoints.isEmpty && !navigation.canStart, "End clears preview and trip")

        let nc = NCCrashDataProvider()
        expect(nc.coversVicinity(origin) && RegionalCrashDataProvider().coversVicinity(origin), "Default crash source must cover Cary")
        let ncQuery = try nc.queryURL(near: origin, radiusMeters: 3_000, cutoff: Date(timeIntervalSince1970: now - 100_000))
        let items = URLComponents(url: ncQuery, resolvingAgainstBaseURL: false)!.queryItems!
        expect(items.contains { $0.name == "where" && $0.value!.contains("NM_Type = 'Bicyclist'") }, "Do not label pedestrian or vehicle-only crashes as bicycle crashes")
        let dateMS = (now - 1000) * 1000
        let row = "\"CrashID\":1,\"CrashDate\":\(dateMS),\"NM_Type\":\"Bicyclist\",\"NM_NumK\":\"0\",\"NM_NumA\":\"0\",\"NM_NumB\":\"1\",\"NM_NumC\":\"0\",\"Latitude\":35.7877,\"Longitude\":-78.7811"
        let fixture = Data("{\"features\":[{\"attributes\":{\(row)}},{\"attributes\":{\(row)}},{\"attributes\":{\(row.replacingOccurrences(of: "Bicyclist", with: "Pedestrian"))}}],\"exceededTransferLimit\":true}".utf8)
        let decoded = try NCCrashDataProvider.decode(fixture, near: origin, radius: 3_000,
            cutoff: Date(timeIntervalSince1970: now - 100_000), now: Date(timeIntervalSince1970: now))
        expect(decoded.incidents.count == 1 && decoded.rejected == 2 && decoded.truncated, "Deduplicate crashes, exclude pedestrians, expose truncation")
        do {
            _ = try NCCrashDataProvider.decode(Data("{\"error\":{\"code\":400}}".utf8), near: origin, radius: 3_000, cutoff: .distantPast, now: Date())
            preconditionFailure("ArcGIS error was treated as empty safe map")
        } catch { checks += 1 }
        if CommandLine.arguments.contains("--live") {
            let live = try await nc.fetch(near: origin, radiusMeters: 3_000, now: Date())
            expect(!live.incidents.isEmpty, "Official Cary-area query must return real bicycle crashes")
            expect(live.incidents.allSatisfy { HazardGeometry.distance(origin, $0.point) <= 3_000 }, "Live crashes must be local")
            let zones = CrashZoneBuilder.build(live)
            expect(!zones.zones.isEmpty && zones.zones.allSatisfy { $0.source.contains("NCDOT") && !$0.source.contains("NYPD") }, "Cary zones must have correct provenance")
            let actual = NavigationCoordinator()
            await actual.search(query: "Cary Regional Library Cary NC", near: origin)
            expect(!actual.destinations.isEmpty, "Real MapKit destination search must work")
            await actual.preview(destination: target, from: origin)
            expect(actual.canStart && actual.routePoints.count > 2 && !actual.maneuvers.isEmpty, "Live bicycle directions must be startable with turns")
            print("Live Cary: \(live.incidents.count) bicycle crashes, \(zones.zones.count) zones; \(actual.routePoints.count) route points, \(actual.maneuvers.count) maneuvers")
        }
        print("Passed \(checks) Cary crash-feed, bicycle routing, voice retry and arrival checks")
    }
}
