import Foundation

struct HazardDataset: Codable, Sendable {
    let zones: [HazardZone]
    let corridors: [HazardCorridor]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 5_000_000 else { throw ImportError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dataset = try decoder.decode(Self.self, from: data)
        guard dataset.zones.count <= 500, dataset.corridors.count <= 100,
              Set(dataset.zones.map(\.id)).count == dataset.zones.count,
              Set(dataset.corridors.map(\.id)).count == dataset.corridors.count else { throw ImportError.invalid }
        for zone in dataset.zones {
            guard valid(zone.center), zone.radiusMeters.isFinite, (5...2000).contains(zone.radiusMeters),
                  zone.severity != .clear, !zone.source.trimmingCharacters(in: .whitespaces).isEmpty,
                  zone.observedAt <= Date() else { throw ImportError.invalid }
        }
        for corridor in dataset.corridors {
            guard (2...500).contains(corridor.points.count), corridor.points.allSatisfy(valid),
                  corridor.severity != .clear, !corridor.source.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw ImportError.invalid }
        }
        return dataset
    }
    private static func valid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite && abs(point.latitude) <= 90 && abs(point.longitude) <= 180
    }
    enum ImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "Invalid hazard dataset. Check coordinates, dates, sources, IDs and size limits." }
    }
}
actor HazardRepository {
    func load(_ url: URL) throws -> HazardDataset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw HazardDataset.ImportError.invalid }
        return try HazardDataset.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }
}
