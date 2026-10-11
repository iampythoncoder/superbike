import SwiftUI

enum RideScreen: String, CaseIterable { case cameras = "Ride", map = "Navigate" }
enum RideSheet: String, Identifiable { case destination, library, settings; var id: String { rawValue } }

struct ContentView: View {
    @State private var ride = RideMonitor()
    @State private var screen = RideScreen.cameras
    @State private var sheet: RideSheet?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 12) {
            header
            TelemetryBar(ride: ride)
            ZStack {
                CameraDeck(ride: ride).opacity(screen == .cameras ? 1 : 0)
                    .allowsHitTesting(screen == .cameras)
                    .accessibilityHidden(screen != .cameras)
                if screen == .map { RiskMapView(ride: ride) { sheet = .destination } }
            }.clipShape(RoundedRectangle(cornerRadius: 24))
            if let banner = ride.hazardBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold()).foregroundStyle(.black).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 14))
            }
            if ride.navigation.isNavigating || ride.navigation.canStart || ride.navigation.hasArrived {
                NavigationBanner(ride: ride)
            }
            controls
            HStack(spacing: 12) {
                ForEach(RideScreen.allCases, id: \.self) { tab in
                    Button { screen = tab } label: {
                        Label(tab.rawValue, systemImage: tab == .cameras ? "video.fill" : "map.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.foregroundStyle(screen == tab ? .black : .white)
                    .background(screen == tab ? Color.white : Color.white.opacity(0.08), in: Capsule())
                }
                Button { sheet = .library; ride.refreshLibrary() } label: {
                    Image(systemName: "play.rectangle.on.rectangle.fill").frame(width: 52, height: 44)
                }.accessibilityLabel("Recordings and rides")
            }.font(.subheadline.bold()).buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
        .background(Color(red: 0.025, green: 0.04, blue: 0.055).ignoresSafeArea())
        .foregroundStyle(.white)
        .task { ride.connect() }
        // Permission sheets briefly make the app inactive. Only backgrounding
        // should stop sensors/recording; permission prompts must not stop setup.
        .onChange(of: phase) { _, new in
            if new == .background { ride.setForeground(false) }
            else if new == .active { ride.setForeground(true) }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .destination: DestinationSearchView(ride: ride) { screen = .map }
            case .library: RideLibraryView(ride: ride)
            case .settings: RideSettingsView(ride: ride)
            }
        }
        .sheet(item: Binding(get: { ride.canShowSummary && sheet == nil ? ride.lastSummary : nil }, set: { ride.lastSummary = $0 })) { summary in
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 45)).foregroundStyle(.green)
                Text("Ride saved").font(.largeTitle.bold())
                Text(String(format: "%.2f mi · %.0f mph max", summary.distanceMeters / 1609.344, summary.maximumSpeedMPS * 2.236936))
                Text("\(summary.warningCount) warnings · \(Int(summary.duration / 60)) min")
                Text("Your route and camera clips stay on this iPhone. Find them in Recordings & rides.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done") { ride.lastSummary = nil }.buttonStyle(.borderedProminent)
            }.padding(24).presentationDetents([.medium])
        }
        .alert("Superbike", isPresented: Binding(get: { ride.errorMessage != nil }, set: { if !$0 { ride.errorMessage = nil } })) {
            Button("OK") { ride.errorMessage = nil }
        } message: { Text(ride.errorMessage ?? "") }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("SUPERBIKE").font(.system(.title3, design: .rounded, weight: .black)).tracking(2)
                HStack(spacing: 6) {
                    Circle().fill(ride.gpsFresh ? Color.green : .orange).frame(width: 6, height: 6)
                    Text(ride.gpsStatus).font(.caption2).lineLimit(1)
                }.foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Button { sheet = .destination; screen = .map } label: {
                Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
            }.accessibilityLabel("Search destination")
            Button { sheet = .settings } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Settings and sensor status")
        }.buttonStyle(.plain)
    }
    private var controls: some View {
        HStack(spacing: 10) {
            Button { ride.toggleRecording() } label: {
                HStack(spacing: 7) {
                    Circle().fill(ride.isRecording ? .red : .white).frame(width: 11, height: 11)
                    Text(ride.recordingBusy ? "Saving…" : ride.isRecording ? "Stop REC" : "Record")
                }.frame(maxWidth: .infinity, minHeight: 56)
            }.background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .disabled(!ride.isRiding || ride.recordingBusy)
            Button { ride.isRiding ? ride.stopRide() : ride.startRide() } label: {
                Label(ride.isRiding ? "End ride" : "Start ride", systemImage: ride.isRiding ? "stop.fill" : "bicycle")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }.foregroundStyle(.black)
                .background(ride.isRiding ? Color.orange : Color.green, in: RoundedRectangle(cornerRadius: 16))
                .disabled(!ride.isRiding && ride.recordingBusy)
        }.font(.headline).buttonStyle(.plain)
    }
}

struct CameraDeck: View {
    let ride: RideMonitor
    var body: some View {
        ZStack {
            CameraSurface(pipeline: ride.camera, side: .road)
            if ride.visionFresh { ThreatOverlay(objects: ride.threat.objects, sourceSize: ride.imageSize) }
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    Label("ROAD", systemImage: "arrow.up").font(.caption.bold()).padding(9)
                        .background(.black.opacity(0.7), in: Capsule())
                    Spacer()
                    if ride.rearAvailable {
                        ZStack(alignment: .bottom) {
                            CameraSurface(pipeline: ride.camera, side: .rear)
                            if ride.rearVisionFresh { ThreatOverlay(objects: ride.rearThreat.objects, sourceSize: ride.rearImageSize, labels: false) }
                            Text(ride.rearVisionFresh ? "BEHIND · \(ride.rearThreat.level.shortTitle)" : "BEHIND · CONNECTING")
                                .font(.system(size: 9, weight: .heavy)).padding(5).frame(maxWidth: .infinity)
                                .background(.black.opacity(0.75))
                        }.frame(width: 120, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ride.rearVisionFresh ? ride.rearThreat.level.color : .gray, lineWidth: 2))
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Label(ride.visionFresh ? ride.threat.level.title : "VISION UNAVAILABLE", systemImage: ride.visionFresh ? ride.threat.level.symbol : "camera.fill")
                        .font(.headline).foregroundStyle(ride.visionFresh ? ride.threat.level.color : .white)
                    Text(ride.visionStatus).font(.caption).foregroundStyle(.white.opacity(0.9))
                    if !ride.rearAvailable { Text(ride.cameraMessage).font(.caption2).foregroundStyle(.orange) }
                    if ride.rearVisionFresh && ride.rearThreat.level != .clear {
                        Label("\(ride.rearThreat.level.shortTitle) BEHIND", systemImage: "arrow.down")
                            .font(.headline).foregroundStyle(ride.rearThreat.level.color)
                    }
                    if !ride.isRiding { Text("Camera preview • start a ride for alerts & recording").font(.caption2) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            }.padding(12)
        }.background(.black)
    }
}
