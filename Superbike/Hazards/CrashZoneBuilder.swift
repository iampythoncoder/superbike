import Foundation

struct CrashZoneDetails: Sendable {
    let incidentCount: Int
    let cyclistInjuries: Int
    let cyclistFatalities: Int
    let firstIncident: Date
    let latestIncident: Date
    let sourceURL: String
}

struct CrashZoneBuild: Sendable {
    var zones: [HazardZone]
    var detailsByID: [UUID: CrashZoneDetails]
}

enum CrashZoneBuilder {
    /// Fixed 150 m cells avoid long chains of incidents turning entire cities into
    /// one zone. The circle encloses the *observed* incidents, with 25 m padding.
    /// "Danger" means >=3 injury/fatality crashes or >=1 cyclist death in the last
    /// 3 years; this is an explicit display threshold, not a validated probability.
    static func build(_ snapshot: CrashFeedSnapshot) -> CrashZoneBuild {
        let cellSize = 150.0
        let longitudeScale = cos(40.72 * .pi / 180)
        struct Cell: Hashable { let x: Int; let y: Int }
        let groups = Dictionary(grouping: snapshot.incidents) { incident in
            Cell(x: Int(floor(incident.point.longitude * .pi / 180 * HazardGeometry.earthRadius * longitudeScale / cellSize)),
                 y: Int(floor(incident.point.latitude * .pi / 180 * HazardGeometry.earthRadius / cellSize)))
        }
        var zones: [HazardZone] = [], details: [UUID: CrashZoneDetails] = [:]
        for (cell, incidents) in groups {
            let count = Double(incidents.count)
            let center = GeoPoint(latitude: incidents.reduce(0) { $0 + $1.point.latitude } / count,
                                  longitude: incidents.reduce(0) { $0 + $1.point.longitude } / count)
            let injured = incidents.reduce(0) { $0 + $1.cyclistsInjured }
            let killed = incidents.reduce(0) { $0 + $1.cyclistsKilled }
            let radius = max(55, (incidents.map { HazardGeometry.distance(center, $0.point) }.max() ?? 0) + 25)
            let dates = incidents.map(\.occurredAt)
            guard let first = dates.min(), let latest = dates.max() else { continue }
            let id = stableID("\(snapshot.providerID):\(cell.x):\(cell.y)")
            let severity: RiskLevel = incidents.count >= 3 || killed > 0 ? .danger : .caution
            let source = "NYPD · \(incidents.count) cyclist-injury/fatality crash\(incidents.count == 1 ? "" : "es") · \(injured) injured · \(killed) killed"
            zones.append(HazardZone(id: id, center: center, radiusMeters: radius,
                                    severity: severity, source: source, observedAt: latest))
            details[id] = CrashZoneDetails(incidentCount: incidents.count, cyclistInjuries: injured,
                cyclistFatalities: killed, firstIncident: first, latestIncident: latest, sourceURL: snapshot.sourceURL)
        }
        // Stable ordering makes refreshes predictable and reduces map annotation churn.
        zones.sort { $0.id.uuidString < $1.id.uuidString }
        return CrashZoneBuild(zones: zones, detailsByID: details)
    }

    /// Deterministic non-security identifier. UUID bit layout is set explicitly.
    private static func stableID(_ text: String) -> UUID {
        func hash(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
            bytes.reduce(seed) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        let input = Array(text.utf8)
        let a = hash(input, seed: 14_695_981_039_346_656_037)
        let b = hash(Array(input.reversed()), seed: 7_809_847_782_465_536_322)
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (56 - $0 * 8)) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: b >> (56 - $0 * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

actor CrashFeedCache {
    private let directory: URL?
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SuperbikeCrashHistory", isDirectory: true)
    }

    func load(providerID: String, near point: GeoPoint, now: Date) -> CrashFeedSnapshot? {
        guard let directory else { return nil }
        let file = directory.appendingPathComponent("crash-history-v1.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000,
              let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(CrashFeedSnapshot.self, from: data),
              snapshot.version == 1, snapshot.providerID == providerID,
              snapshot.incidents.count <= 5_000,
              now.timeIntervalSince(snapshot.fetchedAt) >= 0,
              now.timeIntervalSince(snapshot.fetchedAt) <= 7 * 86_400,
              HazardGeometry.isValid(snapshot.center), snapshot.radiusMeters.isFinite,
              (500...5_000).contains(snapshot.radiusMeters),
              HazardGeometry.distance(point, snapshot.center) < snapshot.radiusMeters * 0.5,
              snapshot.incidents.allSatisfy({
                  HazardGeometry.isValid($0.point) && $0.occurredAt <= now &&
                  $0.cyclistsInjured >= 0 && $0.cyclistsKilled >= 0 &&
                  $0.cyclistsInjured < 1_000 && $0.cyclistsKilled < 1_000
              }) else { return nil }
        return snapshot
    }

    func save(_ snapshot: CrashFeedSnapshot) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("crash-history-v1.json"), options: .atomic)
        } catch {
            // A cache failure must never turn a successful live fetch into an error.
        }
    }

    func build(_ snapshot: CrashFeedSnapshot) -> CrashZoneBuild { CrashZoneBuilder.build(snapshot) }
}
