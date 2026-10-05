import SwiftUI
import MapKit
import UniformTypeIdentifiers

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
struct RiskMapView: View {
    let ride: RideMonitor
    let search: () -> Void
    @State private var position: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var heatmap = true
    @State private var following = true
    @State private var importing = false
    @State private var importError: String?
    @State private var repository = HazardRepository()
    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            if heatmap {
                ForEach(ride.zones) { zone in
                    MapCircle(center: zone.center.coordinate, radius: zone.radiusMeters)
                        .foregroundStyle(zone.severity == .danger ? Color.red.opacity(0.24) : Color.orange.opacity(0.22))
                        .stroke(zone.severity == .danger ? .red : .orange, lineWidth: 2)
                }
                ForEach(ride.corridors) { corridor in
                    MapPolyline(coordinates: corridor.points.map(\.coordinate)).stroke(.orange.opacity(0.4), lineWidth: 15)
                }
            }
            if ride.route.count > 1 { MapPolyline(coordinates: ride.route.map(\.coordinate)).stroke(.green, lineWidth: 3) }
            if ride.navigation.routePoints.count > 1 {
                MapPolyline(coordinates: ride.navigation.routePoints.map(\.coordinate)).stroke(.white, lineWidth: 10)
                MapPolyline(coordinates: ride.navigation.routePoints.map(\.coordinate)).stroke(.blue, lineWidth: 6)
            }
            if let destination = ride.navigation.destination {
                Marker(destination.title, systemImage: "flag.checkered", coordinate: destination.point.coordinate).tint(.blue)
            }
            if let location = ride.location, let course = ride.course, ride.speedMPS > 1 {
                Annotation("Travel direction", coordinate: location.coordinate) {
                    Image(systemName: "location.north.fill").font(.system(size: 28)).foregroundStyle(.blue)
                        .rotationEffect(.degrees(course)).shadow(color: .white, radius: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .light)
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { _ in if position.positionedByUser { following = false } }
        .onChange(of: ride.location) { _, _ in recenter() }
        .onChange(of: ride.navigation.routePoints.count) { _, count in
            if count > 1 && !ride.navigation.isNavigating { following = false; position = .automatic }
        }
        .onChange(of: ride.navigation.isNavigating) { _, active in if active { following = true; recenter() } }
        .overlay(alignment: .top) {
            HStack {
                Button(action: search) { Label("Where to?", systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                Button { heatmap.toggle() } label: { Image(systemName: "flame.fill").frame(width: 48, height: 48) }
                    .foregroundStyle(heatmap ? .orange : .white)
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Toggle crash zones")
            }.font(.subheadline.bold()).padding(10)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                HStack {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
                        .disabled(ride.isRiding).accessibilityLabel("Import crash data")
                    Spacer()
                    Button { following = true; recenter() } label: { Image(systemName: "location.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Follow my location")
                }.background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top, spacing: 7) {
                    if ride.hazards.isLoading { ProgressView().tint(.white) }
                    else { Image(systemName: "exclamationmark.triangle") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ride.hazards.status).font(.caption.bold()).lineLimit(3)
                        Text(ride.hazards.sourceSummary).font(.system(size: 9)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button { ride.hazards.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 36) }
                        .accessibilityLabel("Refresh crash history")
                }.padding(10).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            }.padding(10)
        }
        .foregroundStyle(.white)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task {
                do { let dataset = try await repository.load(result.get()); ride.importHazards(dataset) }
                catch { importError = error.localizedDescription }
            }
        }
        .alert("Hazard data", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }
    private func recenter() {
        guard following, let location = ride.location else { return }
        position = .camera(MapCamera(centerCoordinate: location.coordinate, distance: max(400, ride.speedMPS * 50), heading: 0, pitch: 0))
    }
}
