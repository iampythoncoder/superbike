import CoreLocation
import CoreMotion
import Observation
import UIKit

@MainActor @Observable
final class RideMonitor: NSObject {
    private(set) var isRiding = false
    private(set) var speedMPS = 0.0
    private(set) var maximumSpeedMPS = 0.0
    private(set) var distanceMeters = 0.0
    private(set) var elapsed = 0.0
    private(set) var threat = ThreatSnapshot.clear
    private(set) var stability = 100
    private(set) var warningCount = 0
    private(set) var dangerCount = 0
    private(set) var hardMotionCount = 0
    private(set) var location: GeoPoint?
    private(set) var course: Double?
    private(set) var route: [GeoPoint] = []
    private(set) var imageSize = CGSize(width: 720, height: 1280)
    private(set) var visionStatus = "Start a ride to activate vision"
    private(set) var gpsStatus = "GPS inactive"
    private(set) var visionFresh = false
    private(set) var gpsFresh = false
    private(set) var motionFresh = false
    private(set) var targetFPS = 10.0
    var lastSummary: RideSummary?
    // Imported incident data must include provenance. Never invent public hazards.
    var zones: [HazardZone] = []
    var corridors: [HazardCorridor] = []
    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let motionQueue: OperationQueue = {
        let q = OperationQueue(); q.name = "superbike.motion"; q.maxConcurrentOperationCount = 1; return q
    }()
    @ObservationIgnored private let telemetry = TelemetryWorker()
    @ObservationIgnored private let alerts = AlertCoordinator()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var motion = MotionSample()
    @ObservationIgnored private var mountRoll: Double?
    @ObservationIgnored private var lastVision = 0.0
    @ObservationIgnored private var lastGPS = 0.0
    @ObservationIgnored private var startTime = 0.0
    @ObservationIgnored private var lastHardMotion = 0.0
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored lazy var camera = CameraPipeline(output: { [weak self] result, generation in
        self?.consume(result, generation: generation)
    }, status: { [weak self] status in self?.visionStatus = status })

    override init() {
        super.init()
        locations.delegate = self
        locations.activityType = .fitness
        locations.desiredAccuracy = kCLLocationAccuracyBest
        locations.distanceFilter = 2
    }
    var speedMPH: Double { speedMPS * 2.236936 }
    var safetyScore: Int { max(0, 100 - warningCount * 2 - dangerCount * 5 - hardMotionCount * 3) }
    func startRide() {
        guard !isRiding else { return }
        generation = UUID(); startTime = ProcessInfo.processInfo.systemUptime
        speedMPS = 0; maximumSpeedMPS = 0; distanceMeters = 0; elapsed = 0
        warningCount = 0; dangerCount = 0; hardMotionCount = 0; stability = 100
        lastVision = 0; lastGPS = 0; lastHardMotion = 0; location = nil; course = nil
        motion = MotionSample(); mountRoll = nil; route = []; threat = .clear; visionFresh = false
        gpsFresh = false; motionFresh = false
        alerts.reset(); isRiding = true; gpsStatus = "Acquiring GPS"
        locations.requestWhenInUseAuthorization(); locations.startUpdatingLocation()
        resumeMotion()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        updateCamera()
    }
    func stopRide() {
        guard isRiding else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - startTime
        lastSummary = RideSummary(duration: elapsed, distanceMeters: distanceMeters,
            maximumSpeedMPS: maximumSpeedMPS, warningCount: warningCount, safetyScore: safetyScore)
        isRiding = false; generation = UUID(); ticker?.cancel(); ticker = nil
        locations.stopUpdatingLocation(); motionManager.stopDeviceMotionUpdates(); camera.stop()
        alerts.reset(); visionFresh = false; gpsFresh = false; motionFresh = false; threat = .clear
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active && isRiding { locations.startUpdatingLocation(); resumeMotion() }
        else { locations.stopUpdatingLocation(); motionManager.stopDeviceMotionUpdates(); alerts.reset() }
        updateCamera()
    }
    func setRecording(_ recording: Bool) { self.recording = recording; updateCamera() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - startTime
        visionFresh = foreground && now - lastVision < 1
        gpsFresh = foreground && now - lastGPS < 5
        motionFresh = foreground && now - motion.timestamp < 0.5
        if !visionFresh { threat = .clear }
        if now - lastGPS > 5 { speedMPS = 0; course = nil; gpsStatus = "GPS unavailable" }
        updateCamera()
    }
    private func updateCamera() {
        let state = ProcessInfo.processInfo
        targetFPS = DetectionBudget.fps(speed: speedMPS, thermal: state.thermalState,
            lowPower: state.isLowPowerModeEnabled, recording: recording)
        if targetFPS == 0 { visionStatus = "Vision paused • device too hot"; visionFresh = false }
        camera.update(CaptureSettings(active: isRiding && foreground && targetFPS > 0, fps: targetFPS,
                                     speed: speedMPS, motion: motion, generation: generation))
        UIApplication.shared.isIdleTimerDisabled = isRiding && foreground
    }
    private func consume(_ result: VisionOutput, generation: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isRiding, foreground, generation == self.generation, now - result.timestamp < 0.8 else { return }
        guard result.valid else {
            visionFresh = false; lastVision = 0; threat = .clear
            visionStatus = "Vision inference failed"
            return
        }
        threat = result.threat; imageSize = result.imageSize; lastVision = result.timestamp
        visionFresh = true; visionStatus = "On-device vision • \(Int(targetFPS)) FPS cap"
        if alerts.emit(threat, now: now) { warningCount += 1; if threat.level == .danger { dangerCount += 1 } }
    }
    private func resumeMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let token = generation
        motionManager.deviceMotionUpdateInterval = 0.05
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
            guard let data else { return }
            let a = data.userAcceleration; let r = data.rotationRate
            let sample = MotionSample(accelerationG: sqrt(a.x*a.x+a.y*a.y+a.z*a.z),
                rotationRate: sqrt(r.x*r.x+r.y*r.y+r.z*r.z), roll: data.attitude.roll,
                timestamp: ProcessInfo.processInfo.systemUptime)
            Task { @MainActor [weak self] in
                guard let self, self.isRiding, self.foreground, self.generation == token else { return }
                if self.mountRoll == nil { self.mountRoll = sample.roll }
                var corrected = sample
                let relativeRoll = sample.roll - (self.mountRoll ?? sample.roll)
                corrected.roll = atan2(sin(relativeRoll), cos(relativeRoll))
                self.motion = corrected
                self.stability = max(0, 100 - Int(min(100, sample.accelerationG * 35 + sample.rotationRate * 8)))
                if self.speedMPS > 2 && sample.accelerationG > 0.72 && sample.timestamp - self.lastHardMotion > 4 {
                    self.hardMotionCount += 1; self.lastHardMotion = sample.timestamp
                }
            }
        }
    }
}
extension RideMonitor: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRiding, foreground, let fix = locations.last else { return }
        let sample = LocationSample(point: GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
            accuracy: fix.horizontalAccuracy, speed: fix.speed, course: fix.course,
            timestamp: fix.timestamp.timeIntervalSince1970)
        let token = generation
        Task { [weak self, telemetry] in
            guard let result = await telemetry.ingest(sample, generation: token), let self,
                  self.isRiding, self.generation == token else { return }
            self.location = result.point; self.speedMPS = result.speed; self.course = result.course
            self.maximumSpeedMPS = max(self.maximumSpeedMPS, result.speed)
            self.distanceMeters = result.distance; self.lastGPS = ProcessInfo.processInfo.systemUptime
            self.gpsFresh = true
            self.gpsStatus = "GPS ±\(Int(sample.accuracy)) m"
            if self.route.count >= 5000 { self.route = self.route.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) }
            if result.speed > 0.8 { self.route.append(result.point) }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            gpsStatus = "Location access needed in Settings"
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { gpsStatus = "GPS unavailable" }
}
