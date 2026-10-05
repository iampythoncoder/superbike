import SwiftUI
import UIKit

struct RideSettingsView: View {
    @Bindable var ride: RideMonitor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Alerts & recording") {
                    Toggle("Spoken alerts", isOn: $ride.voiceEnabled)
                    Toggle("Haptic alerts", isOn: $ride.hapticsEnabled)
                    Toggle("Record automatically with ride", isOn: $ride.autoRecord)
                    Button("Test sound & vibration") { ride.testAlerts() }
                }
                Section("Live sensor status") {
                    LabeledContent("GPS", value: ride.gpsStatus)
                    LabeledContent("Road vision", value: ride.visionFresh ? "Live" : "Unavailable")
                    LabeledContent("Behind vision", value: ride.rearVisionFresh ? "Live" : ride.rearAvailable ? "Waiting" : "Unavailable")
                    Text(ride.cameraMessage).font(.caption)
                    Text(ride.visionStatus).font(.caption)
                    Button("Retry GPS") { ride.requestLocation() }
                    Button("Open app permissions") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Mounting") {
                    Text("Mount upright with the back camera aimed down the road. The selfie camera faces the rider and records only the area behind that remains visible around the rider. Check its preview before riding.")
                    Text("Keep Superbike open and the screen unlocked. Backgrounding ends camera recording; the current clip is finalized.")
                }
                Section("Crash history") {
                    Text(ride.hazards.status)
                    Text(ride.hazards.sourceSummary).font(.caption)
                    Text("Automatic coverage currently covers NYC. Other regions require a sourced JSON dataset imported from the map. Alerts describe historical crash concentrations, not live reported crashes.").font(.caption)
                }
                Section("Storage & privacy") {
                    Text("Separate road and behind videos are saved in 60-second segments on this phone, without microphone audio. Recording stops below 200 MB free. Nothing uploads automatically; sharing is your choice.")
                    Text("Routes and recordings can reveal your location. Manage exported files in Files → On My iPhone → Superbike. Map searches/routes go to Apple; nearby crash queries go to the official data provider.")
                }
                Section("About this build") {
                    Text("Warnings are estimates from visible camera objects. A silent warning system is not proof that the road is safe. Ride score is an event summary, not a certified safety rating.")
                    Text("Object detection uses Ultralytics YOLO under AGPL-3.0. Superbike adds tracking, GPS, dual-camera recording, navigation and alerts.").font(.caption)
                }
            }.navigationTitle("Superbike settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
