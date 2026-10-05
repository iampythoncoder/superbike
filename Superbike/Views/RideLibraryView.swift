import SwiftUI
import AVKit

struct RideLibraryView: View {
    let ride: RideMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var selected: RecordedClip?
    var body: some View {
        NavigationStack {
            List {
                Section("Camera recordings") {
                    if ride.clips.isEmpty { Text("Saved road and selfie-camera clips appear here after recording stops or a segment completes.").foregroundStyle(.secondary) }
                    ForEach(ride.clips) { clip in
                        HStack {
                            Button { selected = clip } label: {
                                Label { VStack(alignment: .leading) {
                                    Text(clip.side == .road ? "Road camera" : "Behind · selfie camera").font(.headline)
                                    Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                } } icon: { Image(systemName: "play.circle.fill").font(.title2) }
                            }
                            Spacer()
                            ShareLink(item: clip.url) { Image(systemName: "square.and.arrow.up").padding(10) }
                                .accessibilityLabel("Share video")
                        }.padding(.vertical, 5)
                    }
                }
                Section("Saved rides") {
                    if ride.savedRides.isEmpty { Text("Your ride summaries and GPS tracks are stored on this iPhone.").foregroundStyle(.secondary) }
                    ForEach(ride.savedRides) { saved in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(saved.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(String(format: "%.2f mi · %d min · %d alerts", saved.distanceMeters / 1609.344, Int(saved.duration / 60), saved.warningCount))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Recordings & rides")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { ride.refreshLibrary() }
                .sheet(item: $selected) { clip in ClipPlayerView(clip: clip) }
        }
    }
}
private struct ClipPlayerView: View {
    let clip: RecordedClip
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(clip.side == .road ? "Road camera" : "Behind camera")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { player = AVPlayer(url: clip.url); player?.play() }
                .onDisappear { player?.pause(); player = nil }
        }
    }
}
