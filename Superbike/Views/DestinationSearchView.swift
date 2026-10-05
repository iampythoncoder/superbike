import SwiftUI

struct DestinationSearchView: View {
    let ride: RideMonitor
    let didChooseRoute: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var mode = NavigationRouteMode.cycling
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Address, place or landmark", text: $query)
                        .textInputAutocapitalization(.words).submitLabel(.search)
                        .onSubmit { Task { await ride.navigation.search(query: query, near: ride.location) } }
                    Picker("Route type", selection: $mode) {
                        Text("Cycling").tag(NavigationRouteMode.cycling)
                        Text("Walking").tag(NavigationRouteMode.walking)
                    }.pickerStyle(.segmented)
                    if mode == .walking { Text("Pedestrian route. Dismount where required; this is not a bike route.").font(.caption).foregroundStyle(.orange) }
                } footer: { Text("Search and new routes need internet. Cycling availability varies by region; driving routes are never substituted.") }
                if !ride.gpsFresh { Label(ride.gpsStatus, systemImage: "location.slash").foregroundStyle(.orange) }
                if ride.navigation.isSearching || ride.navigation.isRouting { ProgressView(ride.navigation.isRouting ? "Finding route…" : "Searching…") }
                if let error = ride.navigation.errorMessage { Text(error).foregroundStyle(.orange) }
                Section("Places") {
                    ForEach(ride.navigation.destinations) { destination in
                        Button {
                            Task {
                                await ride.navigation.preview(destination: destination, from: ride.gpsFresh ? ride.location : nil, mode: mode)
                                if ride.navigation.canStart { didChooseRoute(); dismiss() }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(destination.title).font(.headline)
                                Text(destination.subtitle).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.disabled(ride.navigation.isRouting || ride.navigation.isNavigating)
                    }
                }
                if ride.navigation.isNavigating { Button("End current navigation", role: .destructive) { ride.navigation.stop() } }
            }
            .navigationTitle("Where to?")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await ride.navigation.search(query: query, near: ride.location)
            }
            .onDisappear { ride.navigation.cancelSearch() }
        }
    }
}
