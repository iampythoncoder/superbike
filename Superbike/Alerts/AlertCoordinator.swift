import AVFoundation
import UIKit

@MainActor
final class AlertCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private let speech = AVSpeechSynthesizer()
    private let haptic = UINotificationFeedbackGenerator()
    private var lastTimes: [String: Double] = [:]
    private var lastLevels: [String: RiskLevel] = [:]
    private var priorityUntil = 0.0
    var voiceEnabled = true
    var hapticsEnabled = true
    override init() { super.init(); speech.delegate = self }
    func reset() {
        lastTimes.removeAll(); lastLevels.removeAll(); priorityUntil = 0
        speech.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    @discardableResult
    func emit(_ threat: ThreatSnapshot, side: CameraSide, now: Double) -> Bool {
        let key = side.rawValue
        let escalated = threat.level > (lastLevels[key] ?? .clear)
        lastLevels[key] = threat.level
        guard threat.level != .clear,
              escalated || now - (lastTimes[key] ?? -.infinity) > (threat.level == .danger ? 3 : 7) else { return false }
        lastTimes[key] = now
        let whereText = side == .road ? "ahead" : "behind"
        notify(threat.level == .danger ? "Danger \(whereText)." : "Caution \(whereText).",
               urgent: threat.level == .danger, now: now)
        return true
    }
    func hazard(_ text: String) { notify(text, urgent: false, now: ProcessInfo.processInfo.systemUptime) }
    @discardableResult
    func navigation(_ text: String) -> Bool {
        guard voiceEnabled else { return true }
        guard ProcessInfo.processInfo.systemUptime >= priorityUntil, !speech.isSpeaking else { return false }
        speak(text, interrupt: false)
        return true
    }
    func test() {
        if hapticsEnabled { haptic.notificationOccurred(.warning) }
        speak("Superbike alert test. Watch the road.", interrupt: true)
    }
    private func notify(_ text: String, urgent: Bool, now: Double) {
        if hapticsEnabled { haptic.notificationOccurred(urgent ? .error : .warning) }
        guard urgent || now >= priorityUntil else { return }
        priorityUntil = now + (urgent ? 3 : 2)
        speak(text, interrupt: true)
    }
    private func speak(_ text: String, interrupt: Bool) {
        guard voiceEnabled else { return }
        if interrupt { speech.stopSpeaking(at: .immediate) }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* Visual and haptic warnings remain available. */ }
        let cue = AVSpeechUtterance(string: text); cue.rate = 0.5
        speech.speak(cue)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.speech.isSpeaking == false else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
