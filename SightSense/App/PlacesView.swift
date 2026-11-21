import SwiftUI

/// Soundscape-style places: ask where you are, hear what's around or ahead, and set an audio
/// beacon on a nearby or searched place. Laid out for VoiceOver.
struct PlacesView: View {
    let explorer: Explorer
    let onWhereAmI: () -> Void
    let onAroundMe: () -> Void
    let onAheadOfMe: () -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if explorer.compass.isDenied {
                    Section {
                        Text("Location access is off. Turn it on in the Settings app, under Privacy, Location Services, SightSense.")
                    }
                }

                Section("Ask") {
                    Button("Where am I?") { close(then: onWhereAmI) }
                    Button("What's around me?") { close(then: onAroundMe) }
                    Button("What's ahead of me?") { close(then: onAheadOfMe) }
                }

                if let beacon = explorer.beacon {
                    Section("Beacon") {
                        Text("Guiding you to \(beacon.name), \(explorer.position(of: beacon))")
                        Button("Stop beacon", role: .destructive) { explorer.stopBeacon() }
                    }
                }

                Section {
                    TextField("Search for a place", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await explorer.search(query) } }
                    ForEach(explorer.results) { row($0) }
                } header: {
                    Text("Search")
                }

                Section {
                    let places = explorer.compass.location.map { explorer.sortedByDistance(from: $0) } ?? explorer.nearby
                    if places.isEmpty {
                        Text("No places loaded yet.")
                    }
                    ForEach(places.prefix(15)) { row($0) }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Choose a place to set an audio beacon on it: a ping that comes from its direction, brighter when you face it. Headphones work best.")
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ place: Place) -> some View {
        Button {
            explorer.setBeacon(place)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                Text([place.category, explorer.position(of: place)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Sets an audio beacon on this place.")
    }

    private func close(then action: @escaping () -> Void) {
        dismiss()
        action()
    }
}
