import Foundation

struct SavedRide: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let duration: Double
    let distanceMeters: Double
    let maximumSpeedMPS: Double
    let warningCount: Int
    let safetyScore: Int
    let route: [GeoPoint]
}
actor RideArchive {
    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Rides", isDirectory: true)
    }
    func save(_ ride: SavedRide) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ride)
        try data.write(to: folder.appendingPathComponent(ride.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func load() throws -> [SavedRide] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SavedRide.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
