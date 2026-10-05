import Foundation

@main struct NavigationChecks {
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        let start = GeoPoint(latitude: 40, longitude: -74)
        let middle = GeoPoint(latitude: 40.001, longitude: -74)
        let end = GeoPoint(latitude: 40.002, longitude: -74)
        let route = NavigationGeometry(points: [start, middle, end])
        expect(abs(route.distance - 222.39) < 1, "WGS84 route length")
        let match = route.match(middle)!
        expect(abs(match.distanceAlong - route.distance / 2) < 0.1, "Along-route progress")
        expect(match.distanceFromRoute < 0.1, "On-route location deviation")
        let offRoute = route.match(GeoPoint(latitude: 40.001, longitude: -73.999))!
        expect(offRoute.distanceFromRoute > 80 && offRoute.distanceFromRoute < 90, "Cross-track distance in meters")
        expect(route.match(middle, from: 150, through: 160)!.distanceAlong >= 150, "Progress window clamps segment projection")
        expect(route.match(start, from: 200, through: 100) == nil, "Invalid projection window rejected")
        let crossing = NavigationGeometry(points: [start, middle, start, end])
        expect(crossing.match(start, from: 0, through: 80)!.distanceAlong < 1, "Crossing routes cannot jump forward outside the progress window")
        let dateline = NavigationGeometry.distance(GeoPoint(latitude: 0, longitude: 179.999), GeoPoint(latitude: 0, longitude: -179.999))
        expect(dateline > 200 && dateline < 225, "Antimeridian wrapping")
        expect(NavigationGeometry(points: [start]).match(start) == nil, "Single-point routes rejected")
        expect(!NavigationGeometry.isValid(GeoPoint(latitude: .nan, longitude: 0)), "Invalid GPS rejected")
        var monitor = NavigationOffRouteMonitor()
        expect(!monitor.update(deviation: 100, accuracy: 10, timestamp: 100), "One bad fix must not reroute")
        expect(!monitor.update(deviation: 100, accuracy: 10, timestamp: 104) && monitor.isOffRoute, "Sustained deviation enters off-route state")
        expect(monitor.update(deviation: 100, accuracy: 10, timestamp: 108), "Eight seconds off-route triggers reroute")
        expect(!monitor.update(deviation: 100, accuracy: 10, timestamp: 115), "Reroute requests are rate limited")
        expect(monitor.update(deviation: 100, accuracy: 10, timestamp: 129), "A later reroute can retry")
        expect(!monitor.update(deviation: 4, accuracy: 10, timestamp: 130) && !monitor.isOffRoute, "Returning to route clears off-route state")
        expect(!monitor.update(deviation: 150, accuracy: 200, timestamp: 140), "Inaccurate GPS cannot trigger reroute")
        expect(!monitor.update(deviation: 150, accuracy: 10, timestamp: 141), "A poor GPS interval resets deviation evidence")
        monitor.clearEvidence()
        expect(!monitor.update(deviation: 150, accuracy: 10, timestamp: 150), "A location gap must not count as sustained off-route time")
        print("Passed \(count) navigation geometry and off-route checks")
    }
}
