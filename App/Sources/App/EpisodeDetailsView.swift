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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: recording) { _, newValue in store.update(newValue) }
        .task {
            if settings.cachedShows.isEmpty { await loadShows() }
            applyDefaultShowIfNeeded()
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
                        get: { recording.episode.showId ?? "" },
                        set: { newId in
                            recording.episode.showId = newId.isEmpty ? nil : newId
                            recording.episode.showTitle = settings.cachedShows.first { $0.id == newId }?.title
                        }
                    )) {
                        if recording.episode.showId == nil {
                            Text("Select a show").tag("")
                        }
                        ForEach(settings.cachedShows) { show in
                            Text(show.title).tag(show.id)
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
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Theme.muted)
                        .focused($isFieldFocused)
                }
                HStack {
                    Text("Episode #")
                    Spacer()
                    TextField("Optional", text: $recording.episode.number)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
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

    /// A new episode starts with the Settings default (or the only show) so
    /// the picker's selection is what actually gets uploaded; previously the
    /// picker displayed the first show without ever storing it on the episode.
    private func applyDefaultShowIfNeeded() {
        guard recording.episode.showId == nil, let show = settings.defaultShow else { return }
        recording.episode.showId = show.id
        recording.episode.showTitle = show.title
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
