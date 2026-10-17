import CoreLocation
import MapKit
import Observation

enum NavigationRouteMode: String, CaseIterable, Identifiable, Sendable {
    case cycling, walking
    var id: String { rawValue }
    var title: String { self == .cycling ? "Cycling" : "Walking · dismount where required" }
    var symbol: String { self == .cycling ? "bicycle" : "figure.walk" }
    var transportType: MKDirectionsTransportType { self == .cycling ? .cycling : .walking }
}

struct NavigationDestination: Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let point: GeoPoint

    init(id: UUID = UUID(), title: String, subtitle: String = "", point: GeoPoint) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.point = point
    }
}

struct NavigationManeuver: Identifiable, Sendable {
    let id: Int
    let instruction: String
    let distanceAlong: Double
    let point: GeoPoint
    var symbol: String {
        let text = instruction.lowercased()
        if text.contains("roundabout") { return "arrow.triangle.turn.up.right.circle" }
        if text.contains("u-turn") || text.contains("u turn") { return "arrow.uturn.up" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("destination") || text.contains("arriv") { return "flag.checkered" }
        return "arrow.up"
    }
}

/// All MapKit request objects remain on MainActor; immutable coordinates are shared with views.
/// Cycling uses the FOSSGIS bicycle graph; walking uses MapKit. Never substitute
/// a car route when a provider cannot serve the requested transport mode.
@MainActor @Observable
final class NavigationCoordinator {
    private(set) var destinations: [NavigationDestination] = []
    private(set) var destination: NavigationDestination?
    private(set) var routePoints: [GeoPoint] = []
    private(set) var maneuvers: [NavigationManeuver] = []
    private(set) var mode: NavigationRouteMode = .cycling
    private(set) var isSearching = false
    private(set) var isRouting = false
    private(set) var isNavigating = false
    private(set) var hasArrived = false
    private(set) var isOffRoute = false
    private(set) var remainingMeters = 0.0
    private(set) var remainingSeconds = 0.0
    private(set) var distanceToManeuverMeters = 0.0
    private(set) var nextManeuver: NavigationManeuver?
    private(set) var status = "Search for a destination"
    private(set) var errorMessage: String?
    private(set) var routeName = ""
    private(set) var routeAdvisories: [String] = []
    var instruction: String {
        if hasArrived { return "You have arrived" }
        if isOffRoute { return isRouting ? "Recalculating route…" : "Return to the route" }
        return nextManeuver?.instruction ?? (routePoints.isEmpty ? "Choose a destination" : "Continue on the route")
    }
    var canStart: Bool { !routePoints.isEmpty && !isRouting && !isNavigating && !hasArrived }
    var estimatedArrival: Date? { routePoints.isEmpty ? nil : Date().addingTimeInterval(remainingSeconds) }

    /// The app's alert arbiter decides whether a navigation cue may interrupt another alert.
    @ObservationIgnored var onCue: (@MainActor (String) -> Bool)?
    @ObservationIgnored private let bicycleRouter: any BicycleRouting
    @ObservationIgnored private var localSearch: MKLocalSearch?
    @ObservationIgnored private var directions: MKDirections?
    @ObservationIgnored private var searchToken = UUID()
    @ObservationIgnored private var routeToken = UUID()
    @ObservationIgnored private var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var geometry = NavigationGeometry(points: [])
    @ObservationIgnored private var distanceAlong = 0.0
    @ObservationIgnored private var expectedDuration = 0.0
    @ObservationIgnored private var lastFixTimestamp = 0.0
    @ObservationIgnored private var offRouteMonitor = NavigationOffRouteMonitor()
    @ObservationIgnored private var spokenCues: Set<String> = []
    @ObservationIgnored private var latestPoint: GeoPoint?
    @ObservationIgnored private var latestAccuracy = Double.infinity
    @ObservationIgnored private var arrivalBeganAt: Double?

    init(bicycleRouter: any BicycleRouting = OSRMBicycleRouter()) {
        self.bicycleRouter = bicycleRouter
    }

    func search(query: String, near point: GeoPoint?) async {
        localSearch?.cancel()
        let token = UUID(); searchToken = token
        destinations = []; errorMessage = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { isSearching = false; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let point, NavigationGeometry.isValid(point) {
            request.region = MKCoordinateRegion(center: point.navigationCoordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        let search = MKLocalSearch(request: request)
        localSearch = search; isSearching = true
        await withTaskCancellationHandler {
            do {
                let result = try await search.start()
                guard searchToken == token, !Task.isCancelled else { return }
                destinations = result.mapItems.compactMap { item in
                    let coordinate = item.placemark.coordinate
                    let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    guard NavigationGeometry.isValid(point) else { return nil }
                    let address = [item.placemark.thoroughfare, item.placemark.locality, item.placemark.administrativeArea]
                        .compactMap { $0 }.joined(separator: ", ")
                    return NavigationDestination(title: item.name ?? "Destination", subtitle: address, point: point)
                }
                if destinations.isEmpty { errorMessage = "No matching places. Try an address or a nearby landmark." }
            } catch {
                guard searchToken == token, !Task.isCancelled else { return }
                errorMessage = "Search unavailable. Check your internet connection and try again."
            }
            if searchToken == token { isSearching = false; localSearch = nil }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSearch(token: token) }
        }
    }

    func cancelSearch() {
        localSearch?.cancel(); localSearch = nil; searchToken = UUID(); isSearching = false
    }

    func preview(destination: NavigationDestination, from point: GeoPoint?, mode: NavigationRouteMode = .cycling) async {
        guard !isNavigating else { errorMessage = "End the current navigation before choosing another destination."; return }
        guard let point, NavigationGeometry.isValid(point) else {
            errorMessage = "Waiting for your GPS position. Enable Precise Location, then try again."
            return
        }
        await calculate(destination: destination, from: point, mode: mode, continuing: false)
    }

    func start() {
        guard canStart else { return }
        isNavigating = true; hasArrived = false; status = "Navigating · \(mode.title)"
        spokenCues = []; lastFixTimestamp = 0; arrivalBeganAt = nil
        _ = onCue?("Navigation started to \(destination?.title ?? "your destination"). \(nextManeuver?.instruction ?? "Follow the highlighted route.")")
    }

    /// End a trip and discard its route. A new search can start immediately.
    func stop() {
        routeToken = UUID(); directions?.cancel(); directions = nil
        rerouteTask?.cancel(); rerouteTask = nil
        isRouting = false; isNavigating = false; hasArrived = false; isOffRoute = false
        routePoints = []; maneuvers = []; destination = nil; nextManeuver = nil
        remainingMeters = 0; remainingSeconds = 0; distanceToManeuverMeters = 0
        geometry = NavigationGeometry(points: []); distanceAlong = 0
        offRouteMonitor = NavigationOffRouteMonitor(); spokenCues = []; arrivalBeganAt = nil
        routeName = ""; routeAdvisories = []; errorMessage = nil; status = "Search for a destination"
    }

    /// Call for accepted GPS fixes, including before navigation so recalculate has a current origin.
    func updateLocation(point: GeoPoint, speed: Double, accuracy: Double, timestamp: Double = Date().timeIntervalSince1970) {
        guard NavigationGeometry.isValid(point), accuracy.isFinite, (0...65).contains(accuracy),
              timestamp.isFinite, timestamp > lastFixTimestamp else { return }
        latestPoint = point; latestAccuracy = accuracy
        guard isNavigating, !hasArrived, geometry.distance > 0 else { return }
        if lastFixTimestamp > 0, timestamp - lastFixTimestamp > 8 { offRouteMonitor.clearEvidence() }
        let dt = lastFixTimestamp > 0 ? min(15, timestamp - lastFixTimestamp) : 1
        lastFixTimestamp = timestamp
        let speed = speed.isFinite ? max(0, speed) : 0
        let forwardWindow = max(140, speed * dt * 3 + accuracy * 2)
        guard let match = geometry.match(point, from: max(0, distanceAlong - 45), through: distanceAlong + forwardWindow) else { return }
        let shouldReroute = offRouteMonitor.update(deviation: match.distanceFromRoute, accuracy: accuracy, timestamp: timestamp)
        isOffRoute = offRouteMonitor.isOffRoute
        if match.distanceFromRoute <= max(35, accuracy * 1.7) {
            distanceAlong = max(distanceAlong, match.distanceAlong)
        }
        remainingMeters = max(0, geometry.distance - distanceAlong)
        let expectedSpeed = geometry.distance / max(1, expectedDuration)
        // A stationary rider retains the provider ETA; moving ETA follows current progress and speed.
        let estimateSpeed = speed > 1 ? max(1, expectedSpeed * 0.4 + speed * 0.6) : max(1, expectedSpeed)
        remainingSeconds = remainingMeters / estimateSpeed
        updateManeuver(speed: speed)

        if let endpoint = geometry.points.last,
           remainingMeters < 45, NavigationGeometry.distance(point, endpoint) < 25, accuracy <= 35 {
            if arrivalBeganAt == nil { arrivalBeganAt = timestamp }
            if timestamp - (arrivalBeganAt ?? timestamp) >= 2 {
                hasArrived = true; isNavigating = false; isOffRoute = false
                remainingMeters = 0; remainingSeconds = 0; distanceToManeuverMeters = 0
                status = "Arrived at \(destination?.title ?? "destination")"
                _ = onCue?("You have arrived at \(destination?.title ?? "your destination").")
                return
            }
        } else { arrivalBeganAt = nil }

        if shouldReroute, !isRouting, let destination {
            _ = onCue?("You are off the route. Recalculating.")
            rerouteTask?.cancel()
            rerouteTask = Task { [weak self] in
                guard let self else { return }
                await self.calculate(destination: destination, from: point, mode: self.mode, continuing: true)
            }
        } else if !isRouting {
            status = isOffRoute ? "Off route · checking GPS" : "Navigating · \(mode.title)"
        }
    }

    func recalculate() async {
        guard let destination, let point = latestPoint, latestAccuracy <= 65 else {
            errorMessage = "A precise GPS position is needed to recalculate the route."
            return
        }
        await calculate(destination: destination, from: point, mode: mode, continuing: isNavigating)
    }

    private func calculate(destination: NavigationDestination, from origin: GeoPoint, mode: NavigationRouteMode, continuing: Bool) async {
        directions?.cancel()
        let token = UUID(); routeToken = token
        isRouting = true; errorMessage = nil; status = continuing ? "Recalculating route…" : "Finding \(mode.title.lowercased()) route…"
        if !continuing {
            routePoints = []; maneuvers = []; nextManeuver = nil; hasArrived = false
            remainingMeters = 0; remainingSeconds = 0; distanceToManeuverMeters = 0
            routeName = ""; routeAdvisories = []
        }
        self.destination = destination; self.mode = mode
        if mode == .cycling {
            do {
                let plan = try await bicycleRouter.route(from: origin, to: destination.point)
                guard routeToken == token else { return }
                try Task.checkCancellation()
                applyBicycleRoute(plan, destination: destination, continuing: continuing)
            } catch {
                guard routeToken == token else { return }
                if Task.isCancelled { isRouting = false; status = "Route request cancelled"; return }
                errorMessage = (error as? BicycleRoutingError)?.errorDescription
                    ?? "Bicycle directions could not load. Check your connection and retry."
                status = continuing ? "Route update failed · previous route retained" : "No bicycle route available"
            }
            if routeToken == token { isRouting = false }
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.navigationCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.point.navigationCoordinate))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        self.directions = directions
        await withTaskCancellationHandler {
            do {
                let response = try await directions.calculate()
                guard routeToken == token, !Task.isCancelled else { return }
                guard let route = response.routes.first(where: { $0.transportType.contains(mode.transportType) }) else {
                    throw response.routes.isEmpty ? NavigationFailure.noMatchingRoute : NavigationFailure.wrongTransportType
                }
                let points = Self.points(from: route.polyline)
                let geometry = NavigationGeometry(points: points)
                guard geometry.distance > 1, points.count > 1 else { throw NavigationFailure.noMatchingRoute }
                var maneuvers: [NavigationManeuver] = []
                var minimum = 0.0
                for step in route.steps where !step.instructions.isEmpty {
                    guard let point = Self.points(from: step.polyline).first,
                          let match = geometry.match(point, from: max(0, minimum - 5)) else { continue }
                    minimum = max(minimum, match.distanceAlong)
                    maneuvers.append(NavigationManeuver(id: maneuvers.count, instruction: step.instructions,
                        distanceAlong: minimum, point: point))
                }
                if let last = points.last {
                    maneuvers.append(NavigationManeuver(id: maneuvers.count, instruction: "Arrive at \(destination.title)",
                        distanceAlong: geometry.distance, point: last))
                }
                self.geometry = geometry; self.routePoints = points; self.maneuvers = maneuvers
                routeName = route.name; routeAdvisories = route.advisoryNotices
                expectedDuration = max(1, route.expectedTravelTime)
                distanceAlong = 0; remainingMeters = geometry.distance; remainingSeconds = expectedDuration
                offRouteMonitor = NavigationOffRouteMonitor(); isOffRoute = false
                arrivalBeganAt = nil; spokenCues = []; lastFixTimestamp = 0
                updateManeuver(speed: 0, announce: false)
                status = continuing ? "Navigating · \(mode.title)" : "\(mode.title) route ready"
                if continuing { _ = onCue?("Route updated. \(instruction)") }
            } catch {
                guard routeToken == token, !Task.isCancelled else { return }
                if case NavigationFailure.wrongTransportType = error {
                    errorMessage = "Apple returned a different transport type instead of \(mode.rawValue). That route was blocked. Try another destination or explicitly choose Walking."
                } else {
                    errorMessage = mode == .cycling
                        ? "A cycling route is unavailable here, or the connection failed. Try another destination or explicitly choose Walking."
                        : "A walking route is unavailable. Check your internet connection or try another destination."
                }
                status = continuing ? "Route update failed · previous route retained" : "No route available"
            }
            if routeToken == token { isRouting = false; self.directions = nil }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRoute(token: token) }
        }
    }

    private func applyBicycleRoute(_ plan: BicycleRoutePlan, destination: NavigationDestination, continuing: Bool) {
        let geometry = NavigationGeometry(points: plan.points)
        var maneuvers: [NavigationManeuver] = [], minimum = 0.0
        for step in plan.steps {
            guard let match = geometry.match(step.point, from: max(0, minimum - 5)) else { continue }
            minimum = max(minimum, match.distanceAlong)
            maneuvers.append(NavigationManeuver(id: maneuvers.count, instruction: step.instruction,
                distanceAlong: minimum, point: step.point))
        }
        if let endpoint = plan.points.last {
            maneuvers.append(NavigationManeuver(id: maneuvers.count, instruction: "Arrive at \(destination.title)",
                distanceAlong: geometry.distance, point: endpoint))
        }
        self.geometry = geometry; routePoints = plan.points; self.maneuvers = maneuvers
        routeName = plan.name.isEmpty ? "Bicycle route" : plan.name; routeAdvisories = plan.advisories
        expectedDuration = max(1, plan.duration); distanceAlong = 0
        remainingMeters = geometry.distance; remainingSeconds = expectedDuration
        offRouteMonitor = NavigationOffRouteMonitor(); isOffRoute = false
        arrivalBeganAt = nil; spokenCues = []; lastFixTimestamp = 0
        updateManeuver(speed: 0, announce: false)
        status = continuing ? "Navigating · Cycling" : "Bicycle route ready · OpenStreetMap"
        if continuing { _ = onCue?("Route updated. \(instruction)") }
    }

    private func updateManeuver(speed: Double, announce: Bool = true) {
        // Keep the upcoming turn visible until it is passed. Advancing before the
        // maneuver would lose the immediate turn cue when a fast rider skips a GPS fix.
        guard let maneuver = maneuvers.first(where: { $0.distanceAlong >= max(8, distanceAlong - 8) }) ?? maneuvers.last else { return }
        nextManeuver = maneuver
        distanceToManeuverMeters = max(0, maneuver.distanceAlong - distanceAlong)
        guard announce, isNavigating, !isOffRoute else { return }
        let earlyDistance = max(80, min(240, speed * 18))
        let stage = distanceToManeuverMeters <= max(22, speed * 3) ? "now" : "approach"
        guard distanceToManeuverMeters <= earlyDistance else { return }
        let key = "\(maneuver.id)-\(stage)"
        guard !spokenCues.contains(key) else { return }
        let instruction = maneuver.instruction
        let accepted: Bool
        if stage == "now" { accepted = onCue?(instruction) ?? false }
        else {
            let rounded = max(10, Int((distanceToManeuverMeters / 10).rounded()) * 10)
            accepted = onCue?("In \(rounded) meters, \(instruction)") ?? false
        }
        if accepted { spokenCues.insert(key) }
    }

    private func cancelSearch(token: UUID) {
        guard searchToken == token else { return }
        cancelSearch()
    }

    private func cancelRoute(token: UUID) {
        guard routeToken == token else { return }
        directions?.cancel(); directions = nil; routeToken = UUID(); isRouting = false
    }

    private static func points(from polyline: MKPolyline) -> [GeoPoint] {
        let points = polyline.points()
        return (0..<polyline.pointCount).map {
            let coordinate = points[$0].coordinate
            return GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }
}

private enum NavigationFailure: Error { case noMatchingRoute, wrongTransportType }

private extension GeoPoint {
    var navigationCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
