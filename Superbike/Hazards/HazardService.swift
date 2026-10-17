import Foundation
import Observation

enum HazardCoverage: String, Sendable {
    case waitingForLocation = "Waiting for GPS"
    case available = "Official bicycle crash records nearby"
    case outsideCoverage = "No automatic crash-data coverage here"
    case imported = "Imported crash history"
}

/// One owner on the main actor publishes map state. Network decoding, clustering
/// and disk I/O happen off the main actor. Latest-request checks prevent old areas
/// replacing the current area after out-of-order network completions.
@MainActor @Observable
final class HazardService {
    let regional = RegionalHeatmap()
    @ObservationIgnored private var mapPrepared = false
    var mapZones: [HazardZone] {
        guard regional.area != .nearby else { return zones }
        var seen = Set<UUID>()
        return (regional.zones + importedZones).filter { seen.insert($0.id).inserted }
    }
    var mapStatus: String { regional.area == .nearby ? status : regional.status }
    var mapSourceSummary: String { regional.area == .nearby ? sourceSummary : regional.sourceSummary }
    var mapIsLoading: Bool { regional.area == .nearby ? isLoading : regional.isLoading }
    private(set) var zones: [HazardZone] = []
    private(set) var detailsByID: [UUID: CrashZoneDetails] = [:]
    private(set) var status = "Waiting for GPS to load crash history"
    private(set) var sourceSummary = "Automatic history: North Carolina (including Cary) and NYC."
    private(set) var coverage: HazardCoverage = .waitingForLocation
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var latestAlert: HazardEntryAlert?
    @ObservationIgnored var onAlert: (@MainActor (HazardEntryAlert) -> Void)?
    @ObservationIgnored private let provider: any CrashDataProvider
    @ObservationIgnored private let cache: CrashFeedCache
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var requestCenter: GeoPoint?
    @ObservationIgnored private var requestedAt: Date?
    @ObservationIgnored private var snapshot: CrashFeedSnapshot?
    @ObservationIgnored private var fetchedZones: [HazardZone] = []
    @ObservationIgnored private var importedZones: [HazardZone] = []
    @ObservationIgnored private var entryEngine = HazardEntryEngine()
    @ObservationIgnored private var latestFix: Fix?
    private struct Fix {
        let point: GeoPoint
        let speed: Double
        let course: Double?
        let accuracy: Double
        let timestamp: Date
        let alertsEnabled: Bool
    }

    init(provider: any CrashDataProvider = RegionalCrashDataProvider(), cache: CrashFeedCache = CrashFeedCache()) {
        self.provider = provider; self.cache = cache
        regional.onUpdate = { [weak self] in self?.checkEntry() }
    }

    func prepareMap() {
        guard !mapPrepared else { return }; mapPrepared = true
        // Offer the complete local community even before location permission.
        // Elsewhere, keep the existing GPS-centered source selection.
        if latestFix == nil || latestFix.map({
            (35.5...36.2).contains($0.point.latitude) && (-79.1 ... -78.2).contains($0.point.longitude)
        }) == true { regional.select(.community) }
    }

    func update(location: GeoPoint, speedMPS: Double, courseDegrees: Double?,
                horizontalAccuracy: Double, timestamp: Date, alertsEnabled: Bool) {
        guard HazardGeometry.isValid(location), horizontalAccuracy.isFinite,
              (0...100).contains(horizontalAccuracy), abs(timestamp.timeIntervalSinceNow) <= 10 else { return }
        latestFix = Fix(point: location, speed: speedMPS, course: courseDegrees,
                        accuracy: horizontalAccuracy, timestamp: timestamp, alertsEnabled: alertsEnabled)
        if !provider.coversVicinity(location) {
            if coverage != .outsideCoverage && coverage != .imported {
                request?.cancel(); request = nil; requestID = UUID(); isLoading = false
                fetchedZones = []; snapshot = nil; detailsByID = [:]; lastUpdated = nil
                combineZones()
            }
            coverage = importedZones.isEmpty ? .outsideCoverage : .imported
            status = importedZones.isEmpty ? "Crash history unavailable here — unmarked roads are not necessarily safe."
                                          : "Using imported historical zones."
            sourceSummary = "Automatic history: North Carolina and NYC. No local source configured here."
        } else {
            coverage = .available
            fetchIfNeeded(near: location)
        }
        checkEntry()
    }

    func refresh() {
        if regional.area != .nearby { regional.select(regional.area, force: true); return }
        guard let fix = latestFix, provider.coversVicinity(fix.point) else { return }
        fetchIfNeeded(near: fix.point, force: true)
    }

    func resetAlerts() { entryEngine.reset(); latestAlert = nil }

    func pause() {
        request?.cancel(); request = nil; requestID = UUID(); isLoading = false
        latestFix = nil; requestedAt = nil; resetAlerts()
    }

    func setImportedDataset(_ dataset: HazardDataset) {
        importedZones = dataset.zones
        combineZones(); resetAlerts()
        if let fix = latestFix {
            update(location: fix.point, speedMPS: fix.speed, courseDegrees: fix.course,
                   horizontalAccuracy: fix.accuracy, timestamp: fix.timestamp, alertsEnabled: fix.alertsEnabled)
        } else {
            status = "\(importedZones.count) sourced zones imported · waiting for GPS"
            coverage = .imported
        }
    }

    private func combineZones() {
        var seen: Set<UUID> = []
        zones = (importedZones + fetchedZones).filter { seen.insert($0.id).inserted }
    }

    private func fetchIfNeeded(near point: GeoPoint, force: Bool = false) {
        let now = Date()
        if !force {
            if isLoading, let requestCenter, HazardGeometry.distance(point, requestCenter) < 1_500 { return }
            if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < 6 * 3_600,
               HazardGeometry.distance(point, snapshot.center) < 1_000 { return }
            if let requestedAt, now.timeIntervalSince(requestedAt) < 60,
               let requestCenter, HazardGeometry.distance(point, requestCenter) < 1_500 { return }
        }
        request?.cancel(); requestID = UUID()
        let token = requestID
        requestCenter = point; requestedAt = now; isLoading = true
        if let snapshot, HazardGeometry.distance(point, snapshot.center) > snapshot.radiusMeters {
            fetchedZones = []; detailsByID = [:]; combineZones(); self.snapshot = nil
        }
        status = "Loading official bicycle crash history nearby…"
        request = Task { [weak self, provider, cache] in
            if let cached = await cache.load(providerID: provider.cacheID(near: point), near: point, now: now) {
                let clustered = await cache.build(cached)
                if !Task.isCancelled { self?.apply(cached, build: clustered, token: token, cached: true) }
            }
            do {
                let fresh = try await provider.fetch(near: point, radiusMeters: 3_000, now: now)
                try Task.checkCancellation()
                let clustered = await cache.build(fresh)
                try Task.checkCancellation()
                guard let self, self.requestID == token else { return }
                self.apply(fresh, build: clustered, token: token, cached: false)
                self.isLoading = false; self.request = nil
                await cache.save(fresh)
            } catch {
                guard !Task.isCancelled, let self, self.requestID == token else { return }
                self.isLoading = false; self.request = nil
                let hasLocalCache = self.snapshot.map { HazardGeometry.distance(point, $0.center) < $0.radiusMeters * 0.5 } ?? false
                if hasLocalCache {
                    self.status = "Offline / source unavailable · showing cached crash history"
                } else {
                    self.fetchedZones = []; self.detailsByID = [:]; self.combineZones()
                    self.status = "Crash history unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func apply(_ snapshot: CrashFeedSnapshot, build: CrashZoneBuild, token: UUID, cached: Bool) {
        guard requestID == token else { return }
        self.snapshot = snapshot; fetchedZones = build.zones; detailsByID = build.detailsByID
        lastUpdated = snapshot.fetchedAt; combineZones()
        let count = snapshot.incidents.count
        status = count == 0 ? "No matching records in 3 km · this does not establish road safety."
                            : "\(count) recorded crashes · \(zones.count) historical zones within 3 km"
        if cached { status = "Cached · " + status }
        if snapshot.truncated { status += " · partial results (source limit)" }
        let latest = snapshot.publisherUpdatedAt.map {
            "Source updated \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? "Source update date unavailable"
        sourceSummary = "\(snapshot.sourceName) · history since \(snapshot.historyStart.formatted(date: .abbreviated, time: .omitted)) · \(latest)."
        if let newest = snapshot.incidents.map(\.occurredAt).max() {
            sourceSummary += " Newest local record: \(newest.formatted(date: .abbreviated, time: .omitted))."
        }
        if let published = snapshot.publisherUpdatedAt, Date().timeIntervalSince(published) > 30 * 86_400 {
            sourceSummary += " Publication is delayed."
        }
        if Date().timeIntervalSince(snapshot.fetchedAt) > 24 * 3_600 {
            sourceSummary += " Cache fetched \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .omitted))."
        }
        checkEntry()
    }

    private func checkEntry() {
        var seen = Set<UUID>()
        let alertZones = (regional.zones + zones).filter { seen.insert($0.id).inserted }
        guard let fix = latestFix, fix.alertsEnabled,
              let alert = entryEngine.evaluate(zones: alertZones, location: fix.point, speedMPS: fix.speed,
                  courseDegrees: fix.course, horizontalAccuracy: fix.accuracy, timestamp: fix.timestamp) else { return }
        latestAlert = alert; onAlert?(alert)
    }
}
