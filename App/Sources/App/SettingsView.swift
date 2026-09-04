import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var backupManager: BackupManager
    @EnvironmentObject var recorder: AudioRecorder
    @State private var isLoadingShows = false
    @State private var showsError: String?
    @State private var showFolderPicker = false
    @State private var clearedMessage: String?
    @State private var isLoadingCraftDocs = false
    @State private var craftError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case transistorKey, baserowToken, baserowTableId, craftURL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Transistor API Key", text: $settings.transistorAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        .focused($focusedField, equals: .transistorKey)
                    Button {
                        Task { await refreshShows() }
                    } label: {
                        HStack {
                            Text("Load Shows")
                            if isLoadingShows { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(settings.transistorAPIKey.isEmpty)
                    if !settings.cachedShows.isEmpty {
                        Text("\(settings.cachedShows.count) show(s) loaded")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    if let showsError {
                        Text(showsError).font(.caption).foregroundStyle(Theme.danger)
                    }
                } header: {
                    Text("Transistor.fm")
                } footer: {
                    Text("Find your API key at dashboard.transistor.fm under Account > API.")
                }

                Section {
                    TextField("Baserow Token", text: $settings.baserowToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        .focused($focusedField, equals: .baserowToken)
                    TextField("Baserow Table ID", text: $settings.baserowTableId)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        .focused($focusedField, equals: .baserowTableId)
                    Toggle("Auto-sync episodes to Baserow", isOn: $settings.autoSyncBaserow)
                } header: {
                    Text("Baserow Sync")
                } footer: {
                    Text("Relay writes each episode's details + audio file to this Baserow table when you publish. Expected fields: Title, Show, Summary, Description, Explicit, Season, Episode Number, Status, Recorded At, Duration Seconds, Transistor Episode ID, Audio File.")
                }

                Section {
                    HStack {
                        Text("Local Audio Storage")
                        Spacer()
                        Text(storageSizeString)
                            .foregroundStyle(Theme.muted)
                    }
                    Button {
                        let count = store.clearUploadedAudio()
                        clearedMessage = count == 0
                            ? "No published episodes have a local copy to clear."
                            : "Cleared local audio for \(count) published episode\(count == 1 ? "" : "s")."
                    } label: {
                        Text("Clear Local Audio for Published Episodes")
                    }
                    if let clearedMessage {
                        Text(clearedMessage).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Toggle("Delete local copy after successful upload", isOn: $settings.autoDeleteAfterUpload)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Trimming and combining create extra local files, and nothing deletes them automatically unless you enable this. Clearing only removes the local audio file for episodes already published to Transistor — it doesn't touch anything remote, and your Library history stays intact either way.")
                }

                Section {
                    Toggle("Back up new recordings", isOn: $settings.iCloudBackupEnabled)
                    HStack {
                        Text("Backup Folder")
                        Spacer()
                        Text(backupManager.folderName ?? "Not Set")
                            .foregroundStyle(Theme.muted)
                    }
                    Button("Choose Folder…") { showFolderPicker = true }
                    if backupManager.folderName != nil {
                        Button("Remove Folder", role: .destructive) { backupManager.clearFolder() }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Choose any folder — including one in iCloud Drive — and Relay copies each new recording there as soon as it's captured, independent of Transistor or Baserow.")
                }

                Section {
                    TextField("Craft API URL", text: $settings.craftAPIURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.none)
                        .focused($focusedField, equals: .craftURL)
                    Button {
                        Task { await refreshCraftFolders() }
                    } label: {
                        HStack {
                            Text("Load Folders")
                            if isLoadingCraftDocs { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(settings.craftAPIURL.isEmpty)
                    if !settings.cachedCraftFolders.isEmpty {
                        Picker("Target Folder", selection: $settings.craftFolderId) {
                            Text("None").tag("")
                            ForEach(CraftFolder.flatten(settings.cachedCraftFolders), id: \.folder.id) { entry in
                                Text(String(repeating: "  ", count: entry.depth) + entry.folder.name)
                                    .tag(entry.folder.id)
                            }
                        }
                        .onChange(of: settings.craftFolderId) { _, newId in
                            settings.craftFolderTitle = CraftFolder.flatten(settings.cachedCraftFolders)
                                .first { $0.folder.id == newId }?.folder.name ?? ""
                        }
                    }
                    if let craftError {
                        Text(craftError)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                    }
                    Stepper(
                        "Summarize if longer than \(settings.summarizeThresholdMinutes) min",
                        value: $settings.summarizeThresholdMinutes,
                        in: 1...60
                    )
                } header: {
                    Text("Craft")
                } footer: {
                    Text("Create an \"All Documents\" API connection in Craft (Connections tab) and paste its URL here. Relay creates a new document in the folder you pick — e.g. your Voicenotes folder — each time you transcribe or summarize a recording. Recordings shorter than the threshold above get the full transcript; longer ones get a summary instead (on supported devices — otherwise the full transcript is used regardless).")
                }

                Section("Microphone") {
                    HStack {
                        Text("Current Input")
                        Spacer()
                        Text(recorder.currentInputName)
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(recorder.availableInputs(), id: \.uid) { input in
                        Button {
                            recorder.selectInput(input)
                        } label: {
                            HStack {
                                Text(input.portName)
                                    .foregroundStyle(Theme.fg)
                                Spacer()
                                if input.portName == recorder.currentInputName {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    Text("Relay prefers a connected USB-C mic or wireless receiver over the built-in microphone automatically.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .onAppear { recorder.configureSessionPreferringExternalMic() }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                backupManager.setFolder(url)
            }
        }
    }

    private var storageSizeString: String {
        ByteCountFormatter.string(fromByteCount: store.totalStorageBytes(), countStyle: .file)
    }

    private func refreshShows() async {
        isLoadingShows = true
        showsError = nil
        defer { isLoadingShows = false }
        do {
            let api = TransistorAPI(apiKey: settings.transistorAPIKey)
            settings.cachedShows = try await api.listShows()
        } catch {
            showsError = error.localizedDescription
        }
    }

    private func refreshCraftFolders() async {
        guard let url = URL(string: settings.craftAPIURL) else {
            craftError = "That Craft API URL doesn't look valid."
            return
        }
        isLoadingCraftDocs = true
        craftError = nil
        defer { isLoadingCraftDocs = false }
        do {
            let api = CraftAPI(baseURL: url)
            settings.cachedCraftFolders = try await api.listFolders()
        } catch {
            craftError = error.localizedDescription
        }
    }
}
