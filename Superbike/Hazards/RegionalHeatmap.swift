import Foundation
import Observation

enum HeatmapArea: String, CaseIterable, Identifiable, Sendable {
    case nearby, cary, district, community
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nearby: "Near me · 3 km"
        case .cary: "All Cary"
        case .district: "NC-02 · Ross district"
        case .community: "Cary + NC-02"
        }
    }
}

struct HeatmapBounds: Sendable, Equatable {
    let west: Double; let south: Double; let east: Double; let north: Double
    var center: GeoPoint { GeoPoint(latitude: (south + north) / 2, longitude: (west + east) / 2) }
    func contains(_ p: GeoPoint) -> Bool {
        (west...east).contains(p.longitude) && (south...north).contains(p.latitude)
    }
}

/// Bundled Census BAS 2026 Cary limits and the CURRENT 119th Congress NC-02
/// polygon. The 120th Congress election map is intentionally not substituted.
struct HeatmapRegion: Sendable {
    let area: HeatmapArea
    let polygons: [[ [GeoPoint] ]]
    let bounds: HeatmapBounds
    var outlines: [[GeoPoint]] { polygons.flatMap { $0 } }
    static let districtSource = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Legislative/MapServer/4"
    static let carySource = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Places_CouSub_ConCity_SubMCD/MapServer/4"

    static func load(_ area: HeatmapArea, resourceDirectory: URL? = nil) throws -> HeatmapRegion {
        let names: [String]
        switch area {
        case .nearby: throw CrashDataError.unsupportedLocation
        case .cary: names = ["Cary-Boundary"]
        case .district: names = ["NC02-119-Boundary"]
        case .community: names = ["Cary-Boundary", "NC02-119-Boundary"]
        }
        var polygons: [[[GeoPoint]]] = []
        for name in names {
            guard let url = resourceDirectory?.appendingPathComponent(name + ".json")
                ?? Bundle.main.url(forResource: name, withExtension: "json") else { throw CrashDataError.invalidResponse }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw CrashDataError.tooLarge }
            let envelope = try JSONDecoder().decode(BoundaryEnvelope.self, from: data)
            guard envelope.features.count == 1, let feature = envelope.features.first,
                  feature.attributes.GEOID == (name == "Cary-Boundary" ? "3710740" : "3702"),
                  name != "NC02-119-Boundary" || feature.attributes.CDSESSN == "119" else { throw CrashDataError.invalidResponse }
            let rings = try feature.geometry.rings.map { ring in
                guard ring.count >= 4 else { throw CrashDataError.invalidResponse }
                return try ring.map { pair in
                    guard pair.count == 2 else { throw CrashDataError.invalidResponse }
                    let point = GeoPoint(latitude: pair[1], longitude: pair[0])
                    guard NCCrashDataProvider().coversVicinity(point) else { throw CrashDataError.invalidResponse }; return point
                }
            }
            polygons.append(rings)
        }
        let points = polygons.flatMap { $0 }.flatMap { $0 }
        guard !points.isEmpty else { throw CrashDataError.invalidResponse }
        return HeatmapRegion(area: area, polygons: polygons, bounds: HeatmapBounds(
            west: points.map(\.longitude).min()!, south: points.map(\.latitude).min()!,
            east: points.map(\.longitude).max()!, north: points.map(\.latitude).max()!))
    }

    func contains(_ point: GeoPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        // Even/odd parity handles municipal holes and disconnected annexations.
        // Separate polygons are OR'd so the combined view is a union, not XOR.
        return polygons.contains { rings in
            var inside = false
            for ring in rings {
                var j = ring.count - 1
                for i in ring.indices {
                    let a = ring[i], b = ring[j]
                    if (a.latitude > point.latitude) != (b.latitude > point.latitude),
                       point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                        inside.toggle()
                    }
                    j = i
                }
            }
            return inside
        }
    }
    private struct BoundaryEnvelope: Decodable { let features: [Feature] }
    private struct Feature: Decodable { let attributes: Attributes; let geometry: Geometry }
    private struct Attributes: Decodable { let GEOID: String; let CDSESSN: String? }
    private struct Geometry: Decodable { let rings: [[[Double]]] }
}

actor RegionalHeatmapRepository {
    private let resourceDirectory: URL?
    private let cacheDirectory: URL
    init(resourceDirectory: URL? = nil, cacheDirectory: URL? = nil) {
        self.resourceDirectory = resourceDirectory
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory.appending(path: "SuperbikeRegionalHistory")
    }
    func region(_ area: HeatmapArea) throws -> HeatmapRegion { try HeatmapRegion.load(area, resourceDirectory: resourceDirectory) }
    func cached(_ area: HeatmapArea, now: Date) -> CrashFeedSnapshot? {
        let url = cacheDirectory.appending(path: area.rawValue + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(CrashFeedSnapshot.self, from: data),
              value.version == 1, value.providerID == NCCrashDataProvider().id, value.incidents.count <= 10_000,
              (0...7 * 86_400).contains(now.timeIntervalSince(value.fetchedAt)),
              let region = try? region(area), value.incidents.allSatisfy({
                  region.contains($0.point) && $0.occurredAt <= now && $0.occurredAt >= value.historyStart &&
                  $0.cyclistsInjured >= 0 && $0.cyclistsKilled >= 0
              }) else { return nil }
        return value
    }
    func save(_ value: CrashFeedSnapshot, area: HeatmapArea) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: cacheDirectory.appending(path: area.rawValue + ".json"), options: .atomic)
        } catch { /* The live map remains usable if caching fails. */ }
    }
    func fetch(_ region: HeatmapRegion, now: Date) async throws -> CrashFeedSnapshot {
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .year, value: -5, to: now)!
        let nc = NCCrashDataProvider(), b = region.bounds
        var incidents: [CrashIncident] = [], seen = Set<String>(), rejected = 0, truncated = false
        async let published = nc.publisherUpdate()
        // Fetch every page, rather than displaying only the first 2,000 records.
        // The geographic envelope bounds network work; exact polygons filter results.
        for page in 0..<5 {
            try Task.checkCancellation()
            var components = URLComponents(url: try nc.queryURL(near: b.center, radiusMeters: 5_000, cutoff: cutoff), resolvingAgainstBaseURL: false)!
            var items = components.queryItems!.filter { !["geometry", "orderByFields"].contains($0.name) }
            func n(_ value: Double) -> String { String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value) }
            items.append(URLQueryItem(name: "geometry", value: "\(n(b.west)),\(n(b.south)),\(n(b.east)),\(n(b.north))"))
            items.append(URLQueryItem(name: "orderByFields", value: "CrashDate DESC,CrashID ASC,FID ASC"))
            items.append(URLQueryItem(name: "resultOffset", value: String(page * 2_000)))
            components.queryItems = items
            guard let url = components.url else { throw CrashDataError.invalidResponse }
            let data = try await NYCCrashDataProvider.read(url, maximumBytes: 4_000_000)
            let decoded = try NCCrashDataProvider.decode(data, near: b.center, radius: 200_000, cutoff: cutoff, now: now)
            rejected += decoded.rejected
            for incident in decoded.incidents where region.contains(incident.point) && seen.insert(incident.id).inserted {
                incidents.append(incident)
            }
            truncated = decoded.truncated
            if !truncated { break }
        }
        return CrashFeedSnapshot(version: 1, providerID: nc.id, sourceName: "NCDOT · \(region.area.title)",
            sourceURL: NCCrashDataProvider.source, center: b.center, radiusMeters: 200_000,
            fetchedAt: now, historyStart: cutoff, publisherUpdatedAt: await published,
            incidents: incidents, truncated: truncated, rejectedRecords: rejected)
    }
    func build(_ value: CrashFeedSnapshot) -> CrashZoneBuild { CrashZoneBuilder.build(value) }
}

@MainActor @Observable final class RegionalHeatmap {
    private(set) var area: HeatmapArea = .nearby
    private(set) var zones: [HazardZone] = []
    private(set) var bounds: HeatmapBounds?
    private(set) var outlines: [[GeoPoint]] = []
    private(set) var status = "Choose an area"
    private(set) var sourceSummary = "Boundaries: Census BAS 2026 · NC-02, 119th Congress (2025–2027)."
    private(set) var isLoading = false
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?
    @ObservationIgnored private let repository: RegionalHeatmapRepository
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    init(repository: RegionalHeatmapRepository = RegionalHeatmapRepository()) { self.repository = repository }

    func select(_ area: HeatmapArea, force: Bool = false) {
        guard force || area != self.area || (zones.isEmpty && !isLoading) else { return }
        task?.cancel(); token = UUID(); let token = self.token
        self.area = area; zones = []; bounds = nil; outlines = []; isLoading = area != .nearby
        guard area != .nearby else { return }
        status = "Loading all \(area.title) bicycle crash history…"
        task = Task { [weak self, repository] in
            do {
                let region = try await repository.region(area)
                guard let self, self.token == token, !Task.isCancelled else { return }
                self.bounds = region.bounds; self.outlines = region.outlines
                let cached = await repository.cached(area, now: Date())
                if let cached, !Task.isCancelled {
                    let build = await repository.build(cached)
                    guard self.token == token, !Task.isCancelled else { return }
                    self.apply(cached, build: build, cached: true)
                    if !force && Date().timeIntervalSince(cached.fetchedAt) < 6 * 3_600 { self.isLoading = false; return }
                }
                do {
                    let fresh = try await repository.fetch(region, now: Date())
                    let build = await repository.build(fresh)
                    guard self.token == token, !Task.isCancelled else { return }
                    self.apply(fresh, build: build, cached: false); self.isLoading = false
                    await repository.save(fresh, area: area)
                } catch {
                    guard self.token == token, !Task.isCancelled else { return }
                    self.isLoading = false
                    self.status = cached == nil ? "Area history unavailable. Tap refresh to retry." : "Offline · cached \(area.title) history"
                }
            } catch {
                guard let self, self.token == token, !Task.isCancelled else { return }
                self.isLoading = false; self.status = "Area boundary unavailable. Nearby history remains available."
            }
        }
    }
    private func apply(_ snapshot: CrashFeedSnapshot, build: CrashZoneBuild, cached: Bool) {
        zones = build.zones
        status = "\(cached ? "Cached · " : "")\(area.title) · \(snapshot.incidents.count) bicycle crashes · \(zones.count) zones"
        if snapshot.truncated { status += " · partial results" }
        let updated = snapshot.publisherUpdatedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown"
        let newest = snapshot.incidents.map(\.occurredAt).max()?.formatted(date: .abbreviated, time: .omitted) ?? "none"
        sourceSummary = "NCDOT · five-year query since \(snapshot.historyStart.formatted(date: .abbreviated, time: .omitted)). Source updated: \(updated). Newest record: \(newest). Boundaries: Census BAS 2026; NC-02 is the current 119th Congress (2025–2027). Unmarked roads are not necessarily safe."
        onUpdate?()
    }
}
