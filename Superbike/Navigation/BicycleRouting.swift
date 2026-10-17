import Foundation

struct BicycleRouteStep: Sendable {
    let instruction: String
    let point: GeoPoint
}
struct BicycleRoutePlan: Sendable {
    let points: [GeoPoint]
    let steps: [BicycleRouteStep]
    let duration: Double
    let name: String
    let advisories: [String]
}
protocol BicycleRouting: Sendable {
    func route(from origin: GeoPoint, to destination: GeoPoint) async throws -> BicycleRoutePlan
}

enum BicycleRoutingError: LocalizedError {
    case noRoute, invalidResponse, unavailable(Int), tooFar
    var errorDescription: String? {
        switch self {
        case .noRoute: "No bicycle route connects these places. Try a nearby street or entrance."
        case .invalidResponse: "The bicycle routing service returned an invalid route. Please retry."
        case .unavailable(429): "The routing service is busy. Wait a moment and retry."
        case .unavailable: "Cannot reach bicycle routing. Check your connection and retry."
        case .tooFar: "Choose a destination within 150 km for bicycle navigation."
        }
    }
}

/// FOSSGIS's bicycle graph, not the car demo server. The OSRM API path calls its
/// profile 'driving' even on this separate bicycle graph; response step modes
/// are verified before a route can be used. Policy: max 1 request/sec, light use.
actor OSRMBicycleRouter: BicycleRouting {
    private var nextRequestAt = Date.distantPast
    func route(from origin: GeoPoint, to destination: GeoPoint) async throws -> BicycleRoutePlan {
        let url = try Self.queryURL(from: origin, to: destination)
        let now = Date(), scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(1.05)
        if scheduled > now { try await Task.sleep(for: .seconds(scheduled.timeIntervalSince(now))) }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Superbike-iOS/1.0 (bicycle-navigation)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw BicycleRoutingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw BicycleRoutingError.unavailable(http.statusCode) }
        guard data.count <= 4_000_000 else { throw BicycleRoutingError.invalidResponse }
        return try Self.decode(data, origin: origin, destination: destination)
    }

    static func queryURL(from origin: GeoPoint, to destination: GeoPoint) throws -> URL {
        guard NavigationGeometry.isValid(origin), NavigationGeometry.isValid(destination) else { throw BicycleRoutingError.invalidResponse }
        guard NavigationGeometry.distance(origin, destination) <= 150_000 else { throw BicycleRoutingError.tooFar }
        func coordinate(_ point: GeoPoint) -> String {
            String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), point.longitude, point.latitude)
        }
        var parts = URLComponents(string: "https://routing.openstreetmap.de/routed-bike/route/v1/driving/\(coordinate(origin));\(coordinate(destination))")!
        parts.queryItems = [URLQueryItem(name: "overview", value: "full"), URLQueryItem(name: "geometries", value: "geojson"),
                            URLQueryItem(name: "steps", value: "true"), URLQueryItem(name: "alternatives", value: "false"),
                            URLQueryItem(name: "radiuses", value: "100;100")]
        guard let url = parts.url else { throw BicycleRoutingError.invalidResponse }; return url
    }

    static func decode(_ data: Data, origin: GeoPoint, destination: GeoPoint) throws -> BicycleRoutePlan {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw BicycleRoutingError.invalidResponse }
        guard response.code == "Ok", let route = response.routes?.first else { throw BicycleRoutingError.noRoute }
        let coordinates = route.geometry.coordinates
        guard route.geometry.type == "LineString", (2...50_000).contains(coordinates.count),
              route.duration.isFinite, route.duration > 0, route.distance.isFinite, route.distance > 1 else { throw BicycleRoutingError.invalidResponse }
        func point(_ coordinate: [Double]) throws -> GeoPoint {
            guard coordinate.count >= 2 else { throw BicycleRoutingError.invalidResponse }
            let value = GeoPoint(latitude: coordinate[1], longitude: coordinate[0])
            guard NavigationGeometry.isValid(value) else { throw BicycleRoutingError.invalidResponse }; return value
        }
        let points = try coordinates.map(point)
        guard NavigationGeometry.distance(origin, points[0]) <= 150,
              NavigationGeometry.distance(destination, points[points.count - 1]) <= 150 else { throw BicycleRoutingError.noRoute }
        let rawSteps = route.legs.flatMap(\.steps)
        guard !rawSteps.isEmpty, rawSteps.count <= 5_000,
              rawSteps.allSatisfy({ ["cycling", "pushing bike", "ferry"].contains($0.mode) }) else { throw BicycleRoutingError.invalidResponse }
        let steps = try rawSteps.filter { $0.maneuver.type != "arrive" }.map { step in
            BicycleRouteStep(instruction: instruction(for: step), point: try point(step.maneuver.location))
        }
        var advisories = ["Bicycle directions · OpenStreetMap / FOSSGIS. Follow signs and access restrictions."]
        if rawSteps.contains(where: { $0.mode == "pushing bike" }) { advisories.append("Includes sections where you must dismount and walk.") }
        if rawSteps.contains(where: { $0.mode == "ferry" }) { advisories.append("Includes a ferry. Check service times.") }
        return BicycleRoutePlan(points: points, steps: steps, duration: route.duration,
            name: route.legs.map(\.summary).filter { !$0.isEmpty }.joined(separator: ", "), advisories: advisories)
    }

    private static func instruction(for step: Step) -> String {
        let road = step.name.isEmpty ? "the path" : String(step.name.prefix(150))
        let direction = step.maneuver.modifier ?? "straight"
        switch step.maneuver.type {
        case "depart": return "Head onto \(road)"
        case "roundabout", "rotary":
            return "At the roundabout, take \(step.maneuver.exit.map { "exit \($0)" } ?? "the exit") onto \(road)"
        case "exit roundabout", "exit rotary": return "Exit the roundabout onto \(road)"
        case "new name", "notification": return "Continue onto \(road)"
        case "merge": return "Merge \(direction) onto \(road)"
        case "fork": return "Keep \(direction) onto \(road)"
        case "end of road", "turn":
            return direction == "uturn" ? "Make a U-turn onto \(road)" : "Turn \(direction) onto \(road)"
        default: return direction == "straight" ? "Continue on \(road)" : "Continue \(direction) onto \(road)"
        }
    }
    private struct Response: Decodable { let code: String; let routes: [Route]? }
    private struct Route: Decodable {
        let geometry: Geometry; let duration: Double; let distance: Double; let legs: [Leg]
    }
    private struct Geometry: Decodable { let type: String; let coordinates: [[Double]] }
    private struct Leg: Decodable { let summary: String; let steps: [Step] }
    private struct Step: Decodable { let name: String; let mode: String; let maneuver: Maneuver }
    private struct Maneuver: Decodable { let location: [Double]; let type: String; let modifier: String?; let exit: Int? }
}
