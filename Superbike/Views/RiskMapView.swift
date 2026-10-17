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
    @State private var showingSources = false
    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            if heatmap {
                ForEach(ride.hazards.mapZones) { zone in
                    MapCircle(center: zone.center.coordinate, radius: zone.radiusMeters)
                        .foregroundStyle(zone.severity == .danger ? Color.red.opacity(0.24) : Color.orange.opacity(0.22))
                        .stroke(zone.severity == .danger ? .red : .orange, lineWidth: 2)
                }
                ForEach(ride.corridors) { corridor in
                    MapPolyline(coordinates: corridor.points.map(\.coordinate)).stroke(.orange.opacity(0.4), lineWidth: 15)
                }
                ForEach(ride.hazards.regional.outlines.indices, id: \.self) { index in
                    MapPolyline(coordinates: ride.hazards.regional.outlines[index].map(\.coordinate))
                        .stroke(.indigo.opacity(0.55), lineWidth: 1.5)
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
        .onChange(of: ride.navigation.routePoints) { _, points in
            if points.count > 1 && !ride.navigation.isNavigating { fitRoute(points) }
        }
        .onAppear {
            ride.hazards.prepareMap()
            if ride.navigation.canStart { fitRoute(ride.navigation.routePoints) }
            else if let bounds = ride.hazards.regional.bounds { fitArea(bounds) }
            else { recenter() }
        }
        .onChange(of: ride.hazards.regional.bounds) { _, bounds in
            if let bounds, !ride.navigation.isNavigating, !ride.navigation.canStart { fitArea(bounds) }
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
                Menu {
                    ForEach(HeatmapArea.allCases) { area in
                        Button {
                            ride.hazards.regional.select(area)
                            if area == .nearby { following = true; recenter() }
                        } label: {
                            if area == ride.hazards.regional.area { Label(area.title, systemImage: "checkmark") }
                            else { Text(area.title) }
                        }
                    }
                    if let bounds = ride.hazards.regional.bounds {
                        Button("Show entire selected area") { fitArea(bounds) }
                    }
                } label: { Image(systemName: "square.3.layers.3d").frame(width: 48, height: 48) }
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Crash map area: \(ride.hazards.regional.area.title)")
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
                    if ride.hazards.mapIsLoading { ProgressView().tint(.white) }
                    else { Image(systemName: "exclamationmark.triangle") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ride.hazards.mapStatus).font(.caption.bold()).lineLimit(3)
                        Button("Sources & coverage") { showingSources = true }.font(.caption).foregroundStyle(.cyan)
                    }
                    Spacer(minLength: 0)
                    Button { ride.hazards.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 36) }
                        .accessibilityLabel("Refresh crash history")
                }.padding(10).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            }.padding(10)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showingSources) {
            NavigationStack {
                List {
                    Section("Bicycle crash history") {
                        Text(ride.hazards.mapSourceSummary)
                        Text("Area choices cover all Cary, the current NC-02 district represented by Deborah Ross, or their union. Purple outlines show Census boundaries, not the future 120th Congress election map.")
                        Text("Red: three or more recorded bicycle crashes in a cluster, or a cyclist fatality. Orange: other recorded clusters. Historical concentrations are not a measure of crash probability.")
                        Link("NCDOT official crash maps · Cary / NC", destination: URL(string: NCCrashDataProvider.source)!)
                        Link("NYPD official crash data · NYC", destination: URL(string: "https://data.cityofnewyork.us/d/h9gi-nx95")!)
                        Link("Census NC-02 boundary · 119th Congress", destination: URL(string: HeatmapRegion.districtSource)!)
                        Link("Census Cary town limits", destination: URL(string: HeatmapRegion.carySource)!)
                    }
                    Section("Bicycle directions") {
                        Text("© OpenStreetMap contributors · routing by FOSSGIS / OSRM. Coordinates are sent to the routing service when requesting or recalculating a bicycle route. Map display and place search use Apple Maps.")
                        ForEach(ride.navigation.routeAdvisories, id: \.self) { Text($0) }
                        Link("OpenStreetMap attribution", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        Link("Fix the map", destination: URL(string: "https://www.openstreetmap.org/fixthemap")!)
                    }
                }.navigationTitle("Map sources").toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSources = false } }
                }
            }.preferredColorScheme(.light).foregroundStyle(.primary)
        }
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
    private func fitRoute(_ points: [GeoPoint]) {
        guard points.count > 1 else { return }
        var rect = MKMapRect.null
        for point in points {
            let mapPoint = MKMapPoint(point.coordinate)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 1, height: 1))
        }
        let padding = max(1_200, max(rect.width, rect.height) * 0.3)
        following = false; position = .rect(rect.insetBy(dx: -padding, dy: -padding))
    }
    private func fitArea(_ bounds: HeatmapBounds) {
        following = false
        position = .region(MKCoordinateRegion(center: bounds.center.coordinate,
            span: MKCoordinateSpan(latitudeDelta: (bounds.north - bounds.south) * 1.3,
                                   longitudeDelta: (bounds.east - bounds.west) * 1.3)))
    }
}
