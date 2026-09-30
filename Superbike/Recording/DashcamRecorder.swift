import ReplayKit
import SwiftUI

@MainActor
final class DashcamRecorder: NSObject, ObservableObject, RPPreviewViewControllerDelegate, RPScreenRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published var isShowingPreview = false
    @Published var errorMessage: String?
    private(set) var previewController: RPPreviewViewController?
    private var stopWhenStarted = false

    override init() {
        super.init()
        RPScreenRecorder.shared().delegate = self
    }

    nonisolated func screenRecorder(_ screenRecorder: RPScreenRecorder,
        didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRecording = false; self.isBusy = false
            self.errorMessage = error?.localizedDescription
            self.previewController = previewViewController
            self.previewController?.previewControllerDelegate = self
            self.isShowingPreview = previewViewController != nil
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isBusy, !isRecording else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            errorMessage = "Screen recording is unavailable on this device."
            return
        }
        recorder.isMicrophoneEnabled = false
        isBusy = true
        stopWhenStarted = false
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                self?.isBusy = false
                if let error {
                    self?.errorMessage = error.localizedDescription
                } else {
                    self?.isRecording = true
                    if self?.stopWhenStarted == true { self?.stop() }
                }
            }
        }
    }

    func stop() {
        if isBusy && !isRecording { stopWhenStarted = true; return }
        guard isRecording, !isBusy else { return }
        isBusy = true
        RPScreenRecorder.shared().stopRecording { [weak self] preview, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.isRecording = false
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.previewController = preview
                self.previewController?.previewControllerDelegate = self
                self.isShowingPreview = preview != nil
            }
        }
    }

    nonisolated func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        Task { @MainActor in
            isShowingPreview = false
            self.previewController = nil
        }
    }
}

struct ReplayPreview: UIViewControllerRepresentable {
    let controller: RPPreviewViewController

    func makeUIViewController(context: Context) -> RPPreviewViewController { controller }
    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}
}
