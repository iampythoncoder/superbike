import SwiftUI

extension RiskLevel {
    var color: Color { switch self { case .clear: .green; case .caution: .yellow; case .danger: .red } }
    var symbol: String { switch self { case .clear: "viewfinder"; case .caution: "exclamationmark.triangle.fill"; case .danger: "exclamationmark.octagon.fill" } }
}
struct ContentView: View {
    @State private var ride = RideMonitor()
    @StateObject private var recorder = DashcamRecorder()
    @State private var showMap = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                CameraSurface(pipeline: ride.camera)
                if ride.visionFresh {
                    ThreatOverlay(objects: ride.threat.objects, sourceSize: ride.imageSize)
                }
            }.ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.8), .clear, .black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUPERBIKE").font(.system(.title2, design: .rounded, weight: .black)).tracking(2)
                        Label(ride.isRiding ? (ride.visionFresh ? "VISION LIVE" : "VISION UNAVAILABLE") : "READY TO RIDE",
                              systemImage: ride.visionFresh ? "circle.fill" : "circle")
                            .font(.caption2.bold()).foregroundStyle(ride.visionFresh ? .green : .white)
                    }
                    Spacer()
                    Button { showMap = true } label: {
                        Image(systemName: "map.fill").font(.title2).frame(width: 56, height: 56)
                    }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("Open risk map")
                }
                TelemetryBar(ride: ride)
                HStack {
                    Text(ride.gpsStatus)
                    Spacer()
                    Text(String(format: "%.2f MI", ride.distanceMeters / 1609.344))
                }.font(.caption.monospacedDigit().bold()).foregroundStyle(.white.opacity(0.85))
                Spacer()
                statusCard
                HStack(spacing: 12) {
                    Button { recorder.toggle() } label: {
                        Label(recorder.isRecording ? "Stop REC" : "Record", systemImage: "record.circle")
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }.background(recorder.isRecording ? Color.red : Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                    .disabled(!ride.isRiding || recorder.isBusy)
                    Button {
                        if ride.isRiding { recorder.stop(); ride.stopRide() }
                        else { ride.startRide() }
                    } label: {
                        Label(ride.isRiding ? "End ride" : "Start ride", systemImage: ride.isRiding ? "stop.fill" : "bicycle")
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }.foregroundStyle(.black)
                    .background(ride.isRiding ? Color.orange : Color.green, in: RoundedRectangle(cornerRadius: 18))
                }.font(.headline).buttonStyle(.plain)
            }.padding(16)
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ride.threat.level)
        .onChange(of: phase) { _, value in
            ride.setForeground(value == .active)
            if value == .background { recorder.stop() }
        }
        .onChange(of: recorder.isRecording) { _, value in ride.setRecording(value) }
        .onChange(of: ride.targetFPS) { _, value in if value == 0 { recorder.stop() } }
        .fullScreenCover(isPresented: $showMap) { RiskMapView(ride: ride) }
        .sheet(isPresented: $recorder.isShowingPreview) {
            if let controller = recorder.previewController { ReplayPreview(controller: controller).ignoresSafeArea() }
        }
        .sheet(item: Binding(get: {
            recorder.isBusy || recorder.isShowingPreview ? nil : ride.lastSummary
        }, set: { ride.lastSummary = $0 })) { summary in
            VStack(spacing: 20) {
                Image(systemName: "bicycle").font(.largeTitle).foregroundStyle(.green)
                Text("Ride complete").font(.largeTitle.bold())
                Text(String(format: "%.2f miles • %.0f mph max", summary.distanceMeters / 1609.344, summary.maximumSpeedMPS * 2.236936))
                Text("\(summary.warningCount) alerts • ride score \(summary.safetyScore)/100")
                Text("Ride score reflects detected events, not a validated measure of safety.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Done") { ride.lastSummary = nil }.buttonStyle(.borderedProminent)
            }.padding(28).presentationDetents([.medium])
        }
        .alert("Recording", isPresented: Binding(get: { recorder.errorMessage != nil }, set: { if !$0 { recorder.errorMessage = nil } })) {
            Button("OK") { recorder.errorMessage = nil }
        } message: { Text(recorder.errorMessage ?? "") }
    }
    private var statusCard: some View {
        let color = ride.visionFresh ? ride.threat.level.color : .white
        return HStack(spacing: 14) {
            Image(systemName: ride.visionFresh ? ride.threat.level.symbol : "camera.fill")
                .font(.system(size: 28, weight: .bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(ride.visionFresh ? ride.threat.level.title : (ride.isRiding ? "WAITING FOR VISION" : "YOUR RIDE. IN FOCUS."))
                    .font(.headline).foregroundStyle(color)
                Text(ride.visionStatus).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
            if let ttc = ride.threat.timeToCollision, ride.threat.level != .clear {
                VStack { Text(String(format: "%.1fs", ttc)).font(.title2.bold().monospacedDigit()); Text("TTC EST.").font(.caption2.bold()) }
            }
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(color, lineWidth: 2))
    }
}

struct TelemetryBar: View {
    let ride: RideMonitor
    var body: some View {
        HStack(spacing: 0) {
            metric(ride.gpsFresh ? String(format: "%.0f", ride.speedMPH) : "—", "MPH")
            metric(String(format: "%02d:%02d", Int(ride.elapsed) / 60, Int(ride.elapsed) % 60), "TIME")
            metric(ride.motionFresh ? "\(ride.stability)" : "—", "STABILITY")
            metric(ride.isRiding ? "\(ride.safetyScore)" : "—", "RIDE SCORE")
        }.padding(.vertical, 14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.35)))
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.title2, design: .rounded, weight: .heavy)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.85))
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}

struct ThreatOverlay: View {
    let objects: [TrackedThreat]
    let sourceSize: CGSize
    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            let width = sourceSize.width * scale
            let height = sourceSize.height * scale
            let dx = (geometry.size.width - width) / 2
            let dy = (geometry.size.height - height) / 2
            ForEach(objects) { object in
                let box = CGRect(x: object.rect.minX * width + dx, y: object.rect.minY * height + dy,
                                 width: object.rect.width * width, height: object.rect.height * height)
                RoundedRectangle(cornerRadius: 8).stroke(object.level.color, lineWidth: object.level == .danger ? 4 : 2)
                    .background(object.level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                Text(object.label.uppercased() + (object.estimatedDistance.map { String(format: " ~%.0fm", $0) } ?? ""))
                    .font(.caption2.bold().monospacedDigit()).foregroundStyle(.black)
                    .padding(5).background(object.level.color, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: min(max(box.midX, 65), geometry.size.width - 65), y: max(20, box.minY - 12))
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
