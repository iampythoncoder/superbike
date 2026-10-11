import CoreLocation
import CoreMotion
import Observation
import UIKit

@MainActor @Observable
final class RideMonitor: NSObject {
    private(set) var isRiding = false
    private(set) var speedMPS = 0.0
    private(set) var speedAvailable = false
    private(set) var maximumSpeedMPS = 0.0
    private(set) var distanceMeters = 0.0
    private(set) var elapsed = 0.0
    private(set) var threat = ThreatSnapshot.clear
    private(set) var rearThreat = ThreatSnapshot.clear
    private(set) var stability = 100
    private(set) var warningCount = 0
    private(set) var dangerCount = 0
    private(set) var hardMotionCount = 0
    private(set) var location: GeoPoint?
    private(set) var course: Double?
    private(set) var horizontalAccuracy = 0.0
    private(set) var route: [GeoPoint] = []
    private(set) var imageSize = CGSize(width: 720, height: 1280)
    private(set) var rearImageSize = CGSize(width: 720, height: 1280)
    private(set) var visionStatus = "Connecting cameras…"
    private(set) var cameraMessage = "Checking dual camera support"
    private(set) var rearAvailable = false
    private(set) var gpsStatus = "Acquiring your location…"
    private(set) var locationDenied = false
    private(set) var reducedAccuracy = false
    private(set) var visionFresh = false
    private(set) var rearVisionFresh = false
    private(set) var gpsFresh = false
    private(set) var motionFresh = false
    private(set) var targetFPS = 10.0
    private(set) var recordingRequested = false
    private(set) var recordingState: CameraRecordingStatus?
    private(set) var clips: [RecordedClip] = []
    private(set) var savedRides: [SavedRide] = []
    private(set) var hazardBanner: String?
    private(set) var bannerExpires = 0.0
    var errorMessage: String?
    var lastSummary: RideSummary?
    var autoRecord = true
    var voiceEnabled = true { didSet { alerts.voiceEnabled = voiceEnabled } }
    var hapticsEnabled = true { didSet { alerts.hapticsEnabled = hapticsEnabled } }
    let navigation = NavigationCoordinator()
    let hazards = HazardService()
    var importedZones: [HazardZone] = []
    var corridors: [HazardCorridor] = []
    var zones: [HazardZone] { hazards.zones }
    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let motionQueue: OperationQueue = {
        let q = OperationQueue(); q.name = "superbike.motion"; q.maxConcurrentOperationCount = 1; return q
    }()
    @ObservationIgnored private let telemetry = TelemetryWorker()
    @ObservationIgnored private let archive = RideArchive()
    @ObservationIgnored private let alerts = AlertCoordinator()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var telemetryEpoch = 0
    @ObservationIgnored private var motion = MotionSample()
    @ObservationIgnored private var mountRoll: Double?
    @ObservationIgnored private var lastVision = 0.0
    @ObservationIgnored private var lastRearVision = 0.0
    @ObservationIgnored private var lastGPS = 0.0
    @ObservationIgnored private var latestFixTime = 0.0
    @ObservationIgnored private var startTime = 0.0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var lastHardMotion = 0.0
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var connected = false
    @ObservationIgnored lazy var camera = CameraPipeline(output: { [weak self] result, generation in
        self?.consume(result, generation: generation)
    }, status: { [weak self] status in self?.visionStatus = status }, capabilities: { [weak self] capabilities in
        self?.rearAvailable = capabilities.rearAvailable
        self?.cameraMessage = capabilities.message
    }, recordingStatus: { [weak self] status in
        guard let self else { return }
        self.recordingState = status
        if !status.clips.isEmpty { self.refreshLibrary() }
        if status.phase == .failed { self.recordingRequested = false; self.errorMessage = status.message }
    })

    override init() {
        super.init()
        locations.delegate = self
        locations.activityType = .fitness
        locations.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locations.distanceFilter = kCLDistanceFilterNone
        locations.pausesLocationUpdatesAutomatically = false
        navigation.onCue = { [weak self] message in self?.alerts.navigation(message) }
        hazards.onAlert = { [weak self] alert in
            guard let self, self.isRiding else { return }
            self.hazardBanner = alert.message
            self.bannerExpires = ProcessInfo.processInfo.systemUptime + 12
            self.alerts.hazard(alert.message)
        }
    }
    var speedMPH: Double { speedMPS * 2.236936 }
    var safetyScore: Int { max(0, 100 - warningCount * 2 - dangerCount * 5 - hardMotionCount * 3) }
    var isRecording: Bool { recordingState?.phase == .recording }
    var recordingBusy: Bool { recordingState?.phase == .starting || recordingState?.phase == .finishing }
    var canShowSummary: Bool { !recordingBusy && !recordingRequested && !isRecording }

    /// Connect sensors independently of ride tracking, so route search and preview
    /// work before pressing Start. Starting a ride does not discard a valid GPS fix.
    func connect() {
        guard !connected else { return }
        connected = true
        requestLocation()
        resumeMotion()
        refreshLibrary()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        updateCamera()
    }
    func requestLocation() {
        locationDenied = false
        switch locations.authorizationStatus {
        case .notDetermined: locations.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            reducedAccuracy = locations.accuracyAuthorization == .reducedAccuracy
            locations.startUpdatingLocation()
            gpsStatus = reducedAccuracy ? "Approximate location • enable Precise Location" : "Acquiring GPS…"
        default: locationDenied = true; gpsStatus = "Allow Location in Settings"
        }
    }
    func startRide() {
        guard !isRiding else { return }
        connect()
        generation = UUID(); telemetryEpoch += 1
        startTime = ProcessInfo.processInfo.systemUptime; startedAt = Date()
        maximumSpeedMPS = speedAvailable ? speedMPS : 0; distanceMeters = 0; elapsed = 0
        warningCount = 0; dangerCount = 0; hardMotionCount = 0
        lastHardMotion = 0; mountRoll = nil; route = []; threat = .clear; rearThreat = .clear
        alerts.reset(); hazards.resetAlerts(); isRiding = true
        recordingRequested = autoRecord
        requestLocation(); updateCamera()
    }
    func stopRide() {
        guard isRiding else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let record = SavedRide(id: UUID(), startedAt: startedAt, duration: elapsed,
            distanceMeters: distanceMeters, maximumSpeedMPS: maximumSpeedMPS,
            warningCount: warningCount, safetyScore: safetyScore, route: route)
        lastSummary = RideSummary(duration: elapsed, distanceMeters: distanceMeters,
            maximumSpeedMPS: maximumSpeedMPS, warningCount: warningCount, safetyScore: safetyScore)
        isRiding = false; recordingRequested = false; generation = UUID(); telemetryEpoch += 1
        navigation.stop(); alerts.reset(); hazards.resetAlerts(); updateCamera()
        Task { [weak self, archive] in
            do { try await archive.save(record); self?.savedRides = try await archive.load() }
            catch { self?.errorMessage = "Could not save ride: \(error.localizedDescription)" }
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func toggleRecording() {
        guard isRiding, !recordingBusy else { return }
        recordingRequested.toggle(); updateCamera()
    }
    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        generation = UUID() // reject pre-suspension frames after resuming
        lastVision = 0; lastRearVision = 0
        if active { requestLocation(); resumeMotion() }
        else {
            recordingRequested = false
            locations.stopUpdatingLocation(); motionManager.stopDeviceMotionUpdates(); alerts.reset()
            hazards.pause()
            gpsFresh = false; speedAvailable = false
        }
        updateCamera()
    }
    func importHazards(_ dataset: HazardDataset) {
        importedZones = dataset.zones; corridors = dataset.corridors
        hazards.setImportedDataset(dataset)
    }
    func testAlerts() { alerts.test() }
    func refreshLibrary() {
        Task { [weak self, archive] in
            self?.clips = await Task.detached(priority: .utility) { RecordedClip.library() }.value
            do { self?.savedRides = try await archive.load() }
            catch { self?.errorMessage = "Could not read saved rides: \(error.localizedDescription)" }
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if isRiding { elapsed = now - startTime }
        visionFresh = foreground && lastVision > 0 && now - lastVision < 1.5
        rearVisionFresh = foreground && lastRearVision > 0 && now - lastRearVision < 1.5
        gpsFresh = foreground && lastGPS > 0 && now - lastGPS < 10
        motionFresh = foreground && now - motion.timestamp < 0.6
        if !visionFresh { threat = .clear }
        if !rearVisionFresh { rearThreat = .clear }
        if !gpsFresh {
            speedAvailable = false; speedMPS = 0; course = nil
            if !locationDenied { gpsStatus = reducedAccuracy ? "Enable Precise Location in Settings" : "Waiting for GPS • move outdoors" }
        }
        if now > bannerExpires { hazardBanner = nil }
        updateCamera()
    }
    private func updateCamera() {
        guard connected else { return }
        let state = ProcessInfo.processInfo
        targetFPS = DetectionBudget.fps(speed: speedMPS, thermal: state.thermalState,
            lowPower: state.isLowPowerModeEnabled, recording: recordingRequested)
        if targetFPS == 0 { visionStatus = "Camera paused • cool down phone"; recordingRequested = false }
        camera.update(CaptureSettings(active: foreground && targetFPS > 0, fps: targetFPS,
            speed: speedAvailable ? speedMPS : 0, motion: motion, generation: generation,
            recordingRequested: recordingRequested))
        UIApplication.shared.isIdleTimerDisabled = isRiding && foreground
    }
    private func consume(_ result: VisionOutput, generation: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard foreground, generation == self.generation, now - result.timestamp < 1 else { return }
        if result.side == .road {
            imageSize = result.imageSize; lastVision = result.valid ? result.timestamp : 0
            visionFresh = result.valid; threat = result.valid ? result.threat : .clear
        } else {
            rearImageSize = result.imageSize; lastRearVision = result.valid ? result.timestamp : 0
            rearVisionFresh = result.valid; rearThreat = result.valid ? result.threat : .clear
        }
        if !result.valid { visionStatus = "Vision could not analyze a frame"; return }
        if isRiding, alerts.emit(result.threat, side: result.side, now: now) {
            warningCount += 1; if result.threat.level == .danger { dangerCount += 1 }
        }
    }
    private func resumeMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
            guard let data else { return }
            let a = data.userAcceleration; let r = data.rotationRate
            let sample = MotionSample(accelerationG: sqrt(a.x*a.x+a.y*a.y+a.z*a.z),
                rotationRate: sqrt(r.x*r.x+r.y*r.y+r.z*r.z), roll: data.attitude.roll,
                timestamp: ProcessInfo.processInfo.systemUptime)
            Task { @MainActor [weak self] in
                guard let self, self.foreground else { return }
                if self.mountRoll == nil { self.mountRoll = sample.roll }
                var corrected = sample
                let relativeRoll = sample.roll - (self.mountRoll ?? sample.roll)
                corrected.roll = atan2(sin(relativeRoll), cos(relativeRoll)); self.motion = corrected
                self.stability = max(0, 100 - Int(min(100, sample.accelerationG * 35 + sample.rotationRate * 8)))
                if self.isRiding && self.speedMPS > 2 && sample.accelerationG > 0.72 && sample.timestamp - self.lastHardMotion > 4 {
                    self.hardMotionCount += 1; self.lastHardMotion = sample.timestamp
                }
            }
        }
    }
}
extension RideMonitor: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations fixes: [CLLocation]) {
        guard foreground else { return }
        let samples = fixes.suffix(10).map { fix in
            LocationSample(point: GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                accuracy: fix.horizontalAccuracy, speed: fix.speed, course: fix.course,
                timestamp: fix.timestamp.timeIntervalSince1970, speedAccuracy: fix.speedAccuracy,
                courseAccuracy: fix.courseAccuracy)
        }
        let epoch = telemetryEpoch
        Task { [weak self, telemetry] in
            for sample in samples {
                guard let result = await telemetry.ingest(sample, epoch: epoch), let self,
                      self.foreground, self.telemetryEpoch == epoch, result.timestamp > self.latestFixTime else { continue }
                self.latestFixTime = result.timestamp
                self.location = result.point; self.speedMPS = result.speed; self.speedAvailable = result.speedAvailable
                self.horizontalAccuracy = result.accuracy; self.course = result.course
                self.lastGPS = ProcessInfo.processInfo.systemUptime; self.gpsFresh = true
                self.gpsStatus = result.accuracy <= 35 ? "GPS ±\(Int(result.accuracy)) m" : "Weak GPS ±\(Int(result.accuracy)) m"
                if self.isRiding {
                    self.maximumSpeedMPS = max(self.maximumSpeedMPS, result.speed)
                    self.distanceMeters = result.distance
                    if result.usableForRoute, self.route.last.map({ TelemetryFilter.meters($0, result.point) > 2 }) ?? true {
                        if self.route.count >= 20000 { self.route = self.route.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) }
                        self.route.append(result.point)
                    }
                }
                self.navigation.updateLocation(point: result.point, speed: result.speed,
                    accuracy: result.accuracy, timestamp: result.timestamp)
                self.hazards.update(location: result.point, speedMPS: result.speed, courseDegrees: result.course,
                    horizontalAccuracy: result.accuracy, timestamp: Date(timeIntervalSince1970: result.timestamp),
                    alertsEnabled: self.isRiding)
            }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard connected else { return }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            locationDenied = true; gpsFresh = false; speedAvailable = false; gpsStatus = "Allow Location in Settings"
        } else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            locationDenied = false; if foreground { manager.startUpdatingLocation() }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { locationDenied = true; gpsStatus = "Allow Location in Settings" }
        else { gpsStatus = "Acquiring GPS • move outdoors" }
    }
}
