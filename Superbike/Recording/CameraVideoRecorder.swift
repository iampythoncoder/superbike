@preconcurrency import AVFoundation
import Foundation

struct RecordedClip: Identifiable, Sendable, Hashable {
    let id: UUID
    let url: URL
    let side: CameraSide
    let createdAt: Date
    let duration: TimeInterval

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Rides", directoryHint: .isDirectory)
    }
    /// Only committed MP4s are listed. In-progress files use a different suffix.
    static func library() -> [RecordedClip] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "mp4" else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "_")
            guard parts.count == 3, let side = CameraSide(rawValue: parts[1]),
                  let id = UUID(uuidString: parts[2]) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return RecordedClip(id: id, url: url, side: side, createdAt: date, duration: 0)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct CameraRecordingStatus: Sendable {
    enum Phase: String, Sendable { case idle, starting, recording, finishing, failed }
    var phase: Phase = .idle
    var clips: [RecordedClip] = []
    var message: String?
}

/// All entry points and mutable state belong to the capture serial queue. AVAssetWriter
/// encodes asynchronously; readiness checks drop video frames instead of blocking capture.
/// Every 60 seconds we close a playable segment; files remain in Documents/Rides until
/// the rider explicitly removes them. Audio is intentionally not captured.
final class CameraVideoRecorder: @unchecked Sendable {
    private final class Segment: @unchecked Sendable {
        let id = UUID()
        let createdAt = Date()
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let side: CameraSide
        let start: CMTime
        let temporaryURL: URL
        let finalURL: URL
        var last: CMTime
        var frames = 0

        init(side: CameraSide, sample: CMSampleBuffer) throws {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw RecordingError.invalidFrame
            }
            self.side = side
            start = CMSampleBufferGetPresentationTimeStamp(sample); last = start
            let name = "\(Int(createdAt.timeIntervalSince1970))_\(side.rawValue)_\(id.uuidString)"
            temporaryURL = RecordedClip.directory.appending(path: name + ".partial")
            finalURL = RecordedClip.directory.appending(path: name + ".mp4")
            writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width, AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 48,
                    AVVideoExpectedSourceFrameRateKey: 24,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
                ]
            ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.unsupportedFormat }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStart }
            writer.startSession(atSourceTime: start)
        }
    }

    enum RecordingError: LocalizedError {
        case invalidFrame, unsupportedFormat, cannotStart, lowStorage
        var errorDescription: String? {
            switch self {
            case .invalidFrame: "Camera delivered an invalid video frame."
            case .unsupportedFormat: "This camera format cannot be recorded."
            case .cannotStart: "The video recorder could not start."
            case .lowStorage: "Recording stopped: less than 200 MB of storage remains. Saved clips are preserved."
            }
        }
    }
    private let queue: DispatchQueue
    private let changed: @Sendable (CameraRecordingStatus) -> Void
    private var segments: [CameraSide: Segment] = [:]
    private var requested = false
    private var expectedSides: Set<CameraSide> = []
    private var pendingFinishes = 0
    private var failure: String?
    private var lastDiskCheck = 0.0
    private var status = CameraRecordingStatus()

    init(queue: DispatchQueue, changed: @escaping @Sendable (CameraRecordingStatus) -> Void) {
        self.queue = queue; self.changed = changed
    }
    func setRequested(_ requested: Bool, sides: Set<CameraSide>) {
        dispatchPrecondition(condition: .onQueue(queue))
        expectedSides = sides
        guard self.requested != requested else { return }
        self.requested = requested
        if requested {
            failure = nil; lastDiskCheck = 0
            do {
                try FileManager.default.createDirectory(at: RecordedClip.directory, withIntermediateDirectories: true)
                var directory = RecordedClip.directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
                try checkStorage()
                publish(.starting, "Waiting for camera frames")
            } catch { fail(error.localizedDescription) }
        } else {
            finishAll()
        }
    }
    func append(_ sample: CMSampleBuffer, side: CameraSide) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard requested, failure == nil, CMSampleBufferDataIsReady(sample) else { return }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDiskCheck > 5 { try checkStorage(); lastDiskCheck = now }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if let segment = segments[side], CMTimeGetSeconds(timestamp - segment.start) >= 60 {
                segments[side] = nil; finish(segment)
            }
            if segments[side] == nil { segments[side] = try Segment(side: side, sample: sample) }
            guard let segment = segments[side], segment.writer.status == .writing else {
                throw segments[side]?.writer.error ?? RecordingError.cannotStart
            }
            guard timestamp >= segment.last, segment.input.isReadyForMoreMediaData else { return }
            guard segment.input.append(sample) else {
                throw segment.writer.error ?? RecordingError.cannotStart
            }
            segment.last = timestamp; segment.frames += 1
            if expectedSides.allSatisfy({ (segments[$0]?.frames ?? 0) > 0 }), status.phase != .recording {
                publish(.recording, expectedSides.count > 1 ? "Recording road + rear" : "Recording road camera")
            }
        } catch { fail(error.localizedDescription) }
    }
    func interrupt(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard requested || !segments.isEmpty else { return }
        requested = false; failure = message
        finishAll()
    }
    private func fail(_ message: String) {
        failure = message; requested = false
        finishAll()
    }
    private func checkStorage() throws {
        let values = try RecordedClip.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < 200_000_000 {
            throw RecordingError.lowStorage
        }
    }
    private func finishAll() {
        let current = Array(segments.values); segments.removeAll()
        for segment in current { finish(segment) }
        publishFinalState()
    }
    private func finish(_ segment: Segment) {
        pendingFinishes += 1
        segment.input.markAsFinished()
        segment.writer.finishWriting { [self, segment] in
            queue.async { [self, segment] in
                defer { pendingFinishes -= 1; publishFinalState() }
                guard segment.writer.status == .completed, segment.frames > 0 else {
                    failure = segment.writer.error?.localizedDescription ?? "A video segment could not be saved."
                    return
                }
                do {
                    try FileManager.default.moveItem(at: segment.temporaryURL, to: segment.finalURL)
                    let clip = RecordedClip(id: segment.id, url: segment.finalURL, side: segment.side,
                        createdAt: segment.createdAt, duration: CMTimeGetSeconds(segment.last - segment.start))
                    status.clips.insert(clip, at: 0)
                    if status.clips.count > 100 { status.clips.removeLast(status.clips.count - 100) }
                } catch { failure = error.localizedDescription }
            }
        }
    }
    private func publishFinalState() {
        if requested {
            publish(failure == nil ? .recording : .failed, failure)
        } else if pendingFinishes > 0 {
            publish(.finishing, "Saving camera clips…")
        } else {
            publish(failure == nil ? .idle : .failed, failure ?? "Camera clips saved")
        }
    }
    private func publish(_ phase: CameraRecordingStatus.Phase, _ message: String?) {
        status.phase = phase; status.message = message
        changed(status)
    }
}
