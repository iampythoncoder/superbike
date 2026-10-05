import SwiftUI

extension RiskLevel {
    var color: Color { switch self { case .clear: .green; case .caution: .yellow; case .danger: .red } }
    var shortTitle: String { switch self { case .clear: "CLEAR"; case .caution: "CAUTION"; case .danger: "DANGER" } }
    var symbol: String { switch self { case .clear: "viewfinder"; case .caution: "exclamationmark.triangle.fill"; case .danger: "exclamationmark.octagon.fill" } }
}
struct TelemetryBar: View {
    let ride: RideMonitor
    var body: some View {
        HStack(spacing: 0) {
            metric(ride.gpsFresh && ride.speedAvailable ? String(format: "%.0f", ride.speedMPH) : "—", "MPH", prominent: true)
            metric(String(format: "%02d:%02d", Int(ride.elapsed) / 60, Int(ride.elapsed) % 60), "RIDE TIME")
            metric(String(format: "%.2f", ride.distanceMeters / 1609.344), "MILES")
            metric(ride.motionFresh ? "\(ride.stability)" : "—", "STABILITY")
        }.padding(.vertical, 10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14)))
    }
    private func metric(_ value: String, _ label: String, prominent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: prominent ? 34 : 23, weight: .heavy, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.65))
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}
struct ThreatOverlay: View {
    let objects: [TrackedThreat]
    let sourceSize: CGSize
    var labels = true
    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width / max(1, sourceSize.width), geometry.size.height / max(1, sourceSize.height))
            let width = sourceSize.width * scale, height = sourceSize.height * scale
            let dx = (geometry.size.width - width) / 2, dy = (geometry.size.height - height) / 2
            ForEach(objects) { object in
                let box = CGRect(x: object.rect.minX * width + dx, y: object.rect.minY * height + dy,
                                 width: object.rect.width * width, height: object.rect.height * height)
                RoundedRectangle(cornerRadius: 6).stroke(object.level.color, lineWidth: object.level == .danger ? 4 : 2)
                    .background(object.level.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                if labels {
                    Text(object.label.uppercased() + (object.timeToCollision.map { String(format: " · ~%.1fs", $0) } ?? ""))
                        .font(.caption2.bold().monospacedDigit()).foregroundStyle(.black)
                        .padding(4).background(object.level.color, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: min(max(box.midX, 60), max(60, geometry.size.width - 60)), y: max(18, box.minY - 10))
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct NavigationBanner: View {
    let ride: RideMonitor
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ride.navigation.nextManeuver?.symbol ?? "flag.checkered").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.navigation.instruction).font(.subheadline.bold()).lineLimit(2)
                Text("\(Int(ride.navigation.distanceToManeuverMeters)) m · \(Int(ride.navigation.remainingSeconds / 60)) min left")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 0)
            if ride.navigation.canStart {
                Button("Go") { if !ride.isRiding { ride.startRide() }; ride.navigation.start() }
                    .buttonStyle(.borderedProminent).tint(.green).foregroundStyle(.black)
            } else {
                Button { ride.navigation.stop() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("End navigation")
            }
        }.padding(12).background(.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }
}
