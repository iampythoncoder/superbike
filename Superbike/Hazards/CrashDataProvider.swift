import Foundation

struct CrashIncident: Codable, Sendable {
    let id: String
    let point: GeoPoint
    let occurredAt: Date
    let cyclistsInjured: Int
    let cyclistsKilled: Int
}

struct CrashFeedSnapshot: Codable, Sendable {
    let version: Int
    let providerID: String
    let sourceName: String
    let sourceURL: String
    let center: GeoPoint
    let radiusMeters: Double
    let fetchedAt: Date
    let historyStart: Date
    let publisherUpdatedAt: Date?
    let incidents: [CrashIncident]
    let truncated: Bool
    let rejectedRecords: Int
}

protocol CrashDataProvider: Sendable {
    var id: String { get }
    var coverageLabel: String { get }
    func coversVicinity(_ point: GeoPoint) -> Bool
    func fetch(near point: GeoPoint, radiusMeters: Double, now: Date) async throws -> CrashFeedSnapshot
}

enum CrashDataError: LocalizedError {
    case unavailable(Int), tooLarge, invalidResponse, unsupportedLocation
    var errorDescription: String? {
        switch self {
        case .unavailable(429): "Crash-data source is busy. Cached records remain available; retry shortly."
        case .unavailable: "Crash-data source could not be reached."
        case .tooLarge: "Crash-data response exceeded the safety limit."
        case .invalidResponse: "Crash-data source returned an unreadable response."
        case .unsupportedLocation: "Automatic crash history currently covers New York City only."
        }
    }
}

/// NYPD police-reported motor vehicle collisions with cyclist injuries/fatalities.
/// Official source: https://data.cityofnewyork.us/d/h9gi-nx95
/// Missing coordinates/non-reported crashes are not represented. This is historical
/// data, not road exposure-normalized risk or a real-time incident feed.
struct NYCCrashDataProvider: CrashDataProvider {
    let id = "nyc-nypd-h9gi-nx95-v1"
    let coverageLabel = "New York City · NYPD"
    private let maximumRows = 5_000

    /// Coarse discovery bounds include neighboring municipalities, so every status
    /// explicitly says NYC only. The provider never claims coverage for nearby NJ.
    func coversVicinity(_ point: GeoPoint) -> Bool {
        HazardGeometry.isValid(point) && (40.49...40.93).contains(point.latitude) &&
        (-74.27 ... -73.68).contains(point.longitude)
    }

    func fetch(near point: GeoPoint, radiusMeters: Double = 3_000, now: Date = Date()) async throws -> CrashFeedSnapshot {
        guard coversVicinity(point) else { throw CrashDataError.unsupportedLocation }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = calendar.date(byAdding: .year, value: -3, to: now) ?? now.addingTimeInterval(-94_608_000)
        let radius = min(5_000, max(500, radiusMeters))
        let url = try queryURL(near: point, radiusMeters: radius, cutoff: cutoff)
        async let publishedDate = fetchPublisherUpdate()
        let data = try await Self.read(url, maximumBytes: 4_000_000)
        let decoded = try Self.decode(data, now: now)
        try Task.checkCancellation()
        let publisherUpdatedAt = await publishedDate
        let incidents = Array(decoded.incidents.prefix(maximumRows)).filter {
            $0.occurredAt >= calendar.startOfDay(for: cutoff) &&
            HazardGeometry.distance($0.point, point) <= radius
        }
        return CrashFeedSnapshot(version: 1, providerID: id, sourceName: "NYPD cyclist-injury/fatality crashes",
            sourceURL: "https://data.cityofnewyork.us/d/h9gi-nx95", center: point, radiusMeters: radius,
            fetchedAt: now, historyStart: cutoff, publisherUpdatedAt: publisherUpdatedAt,
            incidents: incidents, truncated: decoded.rowCount > maximumRows, rejectedRecords: decoded.rejected)
    }

    func queryURL(near point: GeoPoint, radiusMeters: Double, cutoff: Date) throws -> URL {
        let latitudeDelta = radiusMeters / 111_000
        let longitudeDelta = radiusMeters / (111_000 * cos(point.latitude * .pi / 180))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let predicate = """
        crash_date >= '\(formatter.string(from: cutoff))T00:00:00' AND \
        (number_of_cyclist_injured > 0 OR number_of_cyclist_killed > 0) AND \
        latitude BETWEEN \(number(point.latitude - latitudeDelta)) AND \(number(point.latitude + latitudeDelta)) AND \
        longitude BETWEEN \(number(point.longitude - longitudeDelta)) AND \(number(point.longitude + longitudeDelta))
        """
        var parts = URLComponents(string: "https://data.cityofnewyork.us/resource/h9gi-nx95.json")!
        parts.queryItems = [
            URLQueryItem(name: "$select", value: "collision_id,crash_date,latitude,longitude,number_of_cyclist_injured,number_of_cyclist_killed"),
            URLQueryItem(name: "$where", value: predicate),
            URLQueryItem(name: "$order", value: "crash_date DESC,collision_id ASC"),
            URLQueryItem(name: "$limit", value: String(maximumRows + 1))
        ]
        guard let url = parts.url else { throw CrashDataError.invalidResponse }
        return url
    }

    static func decode(_ data: Data, now: Date) throws -> (incidents: [CrashIncident], rejected: Int, rowCount: Int) {
        let rows: [CrashRow]
        do { rows = try JSONDecoder().decode([CrashRow].self, from: data) }
        catch { throw CrashDataError.invalidResponse }
        var seen: Set<String> = [], incidents: [CrashIncident] = []
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0); dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.isLenient = false
        for row in rows {
            guard let id = row.id, !id.isEmpty, let latitude = row.latitude, let longitude = row.longitude,
                  let date = row.crashDate, date.count >= 10,
                  let occurred = dateFormatter.date(from: String(date.prefix(10))), occurred <= now,
                  let injured = row.injured, let killed = row.killed,
                  (0..<1_000).contains(injured), (0..<1_000).contains(killed), injured + killed > 0 else { continue }
            let point = GeoPoint(latitude: latitude, longitude: longitude)
            guard HazardGeometry.isValid(point), NYCCrashDataProvider().coversVicinity(point),
                  seen.insert(id).inserted else { continue }
            incidents.append(CrashIncident(id: id, point: point, occurredAt: occurred,
                                            cyclistsInjured: injured, cyclistsKilled: killed))
        }
        return (incidents, rows.count - incidents.count, rows.count)
    }

    private func fetchPublisherUpdate() async -> Date? {
        guard let url = URL(string: "https://data.cityofnewyork.us/api/views/h9gi-nx95.json"),
              let data = try? await Self.read(url, maximumBytes: 1_000_000),
              let metadata = try? JSONDecoder().decode(PublisherMetadata.self, from: data),
              let seconds = metadata.rowsUpdatedAt else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func read(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A bounded server-side query avoids downloading a multi-million-row dataset.
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CrashDataError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CrashDataError.unavailable(http.statusCode) }
        guard data.count <= maximumBytes else { throw CrashDataError.tooLarge }
        return data
    }

    private struct PublisherMetadata: Decodable { let rowsUpdatedAt: Double? }

    /// Socrata serializes numeric columns as strings; fixtures/import proxies can use
    /// JSON numbers. Invalid individual values are discarded rather than crashing.
    private struct CrashRow: Decodable {
        let id: String?
        let crashDate: String?
        let latitude: Double?
        let longitude: Double?
        let injured: Int?
        let killed: Int?
        enum CodingKeys: String, CodingKey {
            case id = "collision_id", crashDate = "crash_date", latitude, longitude
            case injured = "number_of_cyclist_injured", killed = "number_of_cyclist_killed"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                if let string = try? values.decode(String.self, forKey: key) { return string }
                if let integer = try? values.decode(Int.self, forKey: key) { return String(integer) }
                if let double = try? values.decode(Double.self, forKey: key), double.isFinite { return String(double) }
                return nil
            }
            id = text(.id); crashDate = text(.crashDate)
            latitude = text(.latitude).flatMap(Double.init); longitude = text(.longitude).flatMap(Double.init)
            injured = text(.injured).flatMap(Int.init); killed = text(.killed).flatMap(Int.init)
        }
    }
}
