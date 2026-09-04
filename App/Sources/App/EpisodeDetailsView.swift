import SwiftUI

struct EpisodeDetailsView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @Binding var recording: Recording
    @State private var isLoadingShows = false
    @State private var loadError: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            form
            NavigationLink {
                PublishView(recording: $recording)
            } label: {
                Text("Continue to Publish")
            }
            .buttonStyle(.primaryAction)
            .padding(16)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationTitle("Episode Details")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recording) { _, newValue in store.update(newValue) }
        .task {
            if settings.cachedShows.isEmpty { await loadShows() }
        }
    }

    private var form: some View {
        Form {
            Section("Show") {
                if settings.cachedShows.isEmpty {
                    HStack {
                        Text(isLoadingShows ? "Loading shows..." : "No shows loaded")
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Refresh") { Task { await loadShows() } }
                    }
                } else {
                    Picker("Podcast", selection: Binding(
                        get: { recording.episode.showId ?? settings.cachedShows.first?.id },
                        set: { newId in
                            recording.episode.showId = newId
                            recording.episode.showTitle = settings.cachedShows.first { $0.id == newId }?.title
                        }
                    )) {
                        ForEach(settings.cachedShows) { show in
                            Text(show.title).tag(Optional(show.id))
                        }
                    }
                }
            }

            Section("Episode") {
                TextField("Title", text: $recording.episode.title)
                    .focused($isFieldFocused)
                TextField("Short Summary (optional)", text: $recording.episode.summary)
                    .focused($isFieldFocused)
                TextField("Description / Show Notes", text: $recording.episode.description, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($isFieldFocused)
            }

            Section("Details") {
                Toggle("Explicit", isOn: $recording.episode.explicit)
                HStack {
                    Text("Season")
                    Spacer()
                    TextField("Optional", text: $recording.episode.season)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Theme.muted)
                        .focused($isFieldFocused)
                }
                HStack {
                    Text("Episode #")
                    Spacer()
                    TextField("Optional", text: $recording.episode.number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Theme.muted)
                        .focused($isFieldFocused)
                }
            }

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
    }

    private func loadShows() async {
        guard settings.hasTransistorKey else {
            loadError = "Add your Transistor API key in Settings to load shows."
            return
        }
        isLoadingShows = true
        loadError = nil
        defer { isLoadingShows = false }
        do {
            let api = TransistorAPI(apiKey: settings.transistorAPIKey)
            settings.cachedShows = try await api.listShows()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
