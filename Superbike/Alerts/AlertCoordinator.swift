import AVFoundation
import UIKit

@MainActor
final class AlertCoordinator {
    private let speech = AVSpeechSynthesizer()
    private let haptic = UINotificationFeedbackGenerator()
    private var lastTime = -Double.infinity
    private var lastLevel = RiskLevel.clear
    func reset() { lastTime = -.infinity; lastLevel = .clear; speech.stopSpeaking(at: .immediate) }
    @discardableResult
    func emit(_ threat: ThreatSnapshot, now: Double) -> Bool {
        let escalated = threat.level > lastLevel
        lastLevel = threat.level
        guard threat.level != .clear, escalated || now - lastTime > (threat.level == .danger ? 3 : 6) else { return false }
        lastTime = now
        haptic.notificationOccurred(threat.level == .danger ? .error : .warning)
        if threat.level == .danger { speech.stopSpeaking(at: .immediate) }
        guard !speech.isSpeaking else { return true }
        let cue = AVSpeechUtterance(string: threat.level == .danger ? "Danger. Check ahead." : "Caution. Check ahead.")
        cue.rate = 0.52
        speech.speak(cue)
        return true
    }
}
