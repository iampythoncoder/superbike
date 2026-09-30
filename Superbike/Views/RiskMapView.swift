import SwiftUI
import MapKit
import UniformTypeIdentifiers

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
struct RiskMapView: View {
    let ride: RideMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var heatmap = true
    @State private var route = true
    @State private var telemetry = true
    @State private var following = true
    @State private var importing = false
    @State private var importError: String?
    @State private var repository = HazardRepository()
    private var direction: [CLLocationCoordinate2D] {
        guard let origin = ride.location, let course = ride.course, ride.speedMPS > 1.5 else { return [] }
        // Three seconds of travel, bounded to remain readable; not a planned route.
        let angularDistance = min(100, max(12, ride.speedMPS * 3)) / 6_371_000
        let bearing = course * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let targetLat = asin(sin(latitude) * cos(angularDistance) + cos(latitude) * sin(angularDistance) * cos(bearing))
        let targetLon = longitude + atan2(sin(bearing) * sin(angularDistance) * cos(latitude), cos(angularDistance) - sin(latitude) * sin(targetLat))
        return [origin.coordinate, CLLocationCoordinate2D(latitude: targetLat * 180 / .pi, longitude: targetLon * 180 / .pi)]
    }
    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            if heatmap {
                ForEach(ride.zones) { zone in
                    MapCircle(center: zone.center.coordinate, radius: zone.radiusMeters)
                        .foregroundStyle(zone.severity == .danger ? Color.red.opacity(0.22) : Color.orange.opacity(0.25))
                        .stroke(zone.severity == .danger ? .red : .orange, lineWidth: 2)
                    Annotation(zone.source, coordinate: zone.center.coordinate) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.black)
                            .padding(6).background(.orange, in: Circle())
                    }.annotationTitles(.hidden)
                }
                ForEach(ride.corridors) { corridor in
                    MapPolyline(coordinates: corridor.points.map(\.coordinate))
                        .stroke(corridor.severity == .danger ? Color.red.opacity(0.3) : Color.orange.opacity(0.35), lineWidth: 20)
                    MapPolyline(coordinates: corridor.points.map(\.coordinate))
                        .stroke(corridor.severity == .danger ? .red : .orange, lineWidth: 3)
                }
            }
            if route { MapPolyline(coordinates: ride.route.map(\.coordinate)).stroke(.blue, lineWidth: 5) }
            if direction.count == 2 {
                MapPolyline(coordinates: direction).stroke(.black, lineWidth: 9)
                MapPolyline(coordinates: direction).stroke(.cyan, lineWidth: 5)
                Annotation("Direction", coordinate: direction[1]) {
                    Image(systemName: "location.north.fill").font(.title2).foregroundStyle(.cyan)
                        .shadow(color: .black, radius: 1).rotationEffect(.degrees(ride.course ?? 0))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.light)
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { _ in if position.positionedByUser { following = false } }
        .onChange(of: ride.location?.latitude) { _, _ in recenter() }
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                HStack {
                    Button { dismiss() } label: { Label("Camera", systemImage: "chevron.left").padding(16) }
                    Spacer()
                    Button { importing = true } label: {
                        Label("Import", systemImage: "square.and.arrow.down").padding(16)
                    }.disabled(ride.isRiding)
                }.background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
                if telemetry { TelemetryBar(ride: ride).environment(\.colorScheme, .dark) }
            }.foregroundStyle(.white).padding(16)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if heatmap && ride.zones.isEmpty && ride.corridors.isEmpty {
                    Text("No historical hazard data loaded. Unmarked roads are not necessarily safe.")
                        .font(.caption.bold()).padding(12).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 10) {
                    layer("Heatmap", "flame.fill", $heatmap)
                    layer("Route", "point.topleft.down.to.point.bottomright.curvepath", $route)
                    layer("Telemetry", "gauge.with.dots.needle.50percent", $telemetry)
                    Button { following = true; recenter() } label: {
                        Image(systemName: "location.fill").frame(width: 56, height: 64)
                    }.background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Follow my location")
                }
            }.foregroundStyle(.white).padding(16)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let dataset = try await repository.load(url)
                        ride.zones = dataset.zones; ride.corridors = dataset.corridors
                    } catch { importError = error.localizedDescription }
                }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Hazard data", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }
    private func recenter() {
        guard following, let location = ride.location else { return }
        position = .camera(MapCamera(centerCoordinate: location.coordinate,
            distance: max(250, ride.speedMPS * 40), heading: 0, pitch: 0))
    }
    private func layer(_ title: String, _ icon: String, _ enabled: Binding<Bool>) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            VStack(spacing: 5) { Image(systemName: icon).font(.title3); Text(title).font(.caption2.bold()) }
                .frame(maxWidth: .infinity, minHeight: 64)
        }.foregroundStyle(enabled.wrappedValue ? .black : .white)
        .background(enabled.wrappedValue ? Color.white : .black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityValue(enabled.wrappedValue ? "On" : "Off")
    }
}
