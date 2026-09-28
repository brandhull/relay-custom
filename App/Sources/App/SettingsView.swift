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
        // Plain Form on macOS, not wrapped in NavigationStack — Settings has
        // no NavigationLink pushes of its own to justify one. formContent
        // wraps the Form in its own ScrollView on macOS (see below) because
        // Form's own internal scrolling didn't engage once it was given a
        // fixed height from RelayApp's tab-switching container — it just
        // rendered a fixed, non-scrollable middle slice of its content
        // instead (confirmed with real, non-simulated scroll input, not
        // just accessibility actions).
        #if os(iOS)
        NavigationStack {
            formContent
        }
        .onAppear { recorder.configureSessionPreferringExternalMic() }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                backupManager.setFolder(url)
            }
        }
        #else
        formContent
            .onAppear { recorder.configureSessionPreferringExternalMic() }
        #endif
    }

    private var formContent: some View {
        #if os(macOS)
        // A definite width (not just maxWidth: .infinity) is load-bearing —
        // Section footer/header Text never wrapped and just ran off the
        // window edge otherwise. Form's own row layout on macOS doesn't
        // propose a bounded width to its children the way iOS's grouped
        // Form does, so long footer strings had nothing to wrap against
        // until given one explicitly here.
        ScrollView {
            settingsForm
                .frame(width: 400)
                .padding(.vertical, 8)
        }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
                Section {
                    SecureField("Transistor API Key", text: $settings.transistorAPIKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textContentType(.none)
                        #endif
                        .focused($focusedField, equals: .transistorKey)
                    HStack {
                        Button {
                            Task { await refreshShows() }
                        } label: {
                            HStack {
                                Text("Load Shows")
                                if isLoadingShows { ProgressView() }
                            }
                        }
                        .disabled(settings.transistorAPIKey.isEmpty)
                        if !settings.cachedShows.isEmpty {
                            Spacer()
                            Text(settings.cachedShows.map(\.title).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textContentType(.none)
                        #endif
                        .focused($focusedField, equals: .baserowToken)
                    TextField("Baserow Table ID", text: $settings.baserowTableId)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        #endif
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
                    Button("Choose Folder…") {
                        #if os(iOS)
                        showFolderPicker = true
                        #else
                        backupManager.pickFolder()
                        #endif
                    }
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
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textContentType(.none)
                        #endif
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
                    Toggle("Clean up punctuation", isOn: $settings.cleanupPunctuationEnabled)
                } header: {
                    Text("Craft")
                } footer: {
                    Text("Create an \"All Documents\" API connection in Craft (Connections tab) and paste its URL here. Relay creates a new document in the folder you pick — e.g. your Voicenotes folder — each time you transcribe or summarize a recording. Recordings shorter than the threshold above get the full transcript; longer ones get a summary instead (on supported devices — otherwise the full transcript is used regardless). Clean up punctuation runs full transcripts through an extra on-device pass that fixes sentence breaks without changing wording — off by default since it adds a small chance of the model tweaking a word despite instructions not to.")
                }

                Section("Microphone") {
                    HStack {
                        Text("Current Input")
                        Spacer()
                        Text(recorder.currentInputName)
                            .foregroundStyle(Theme.muted)
                    }
                    #if os(iOS)
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
                    #else
                    Button("System Default") {
                        recorder.selectedInputDeviceUID = nil
                        recorder.refreshCurrentInputName()
                    }
                    ForEach(AudioInputDeviceLister.availableInputDevices()) { device in
                        Button {
                            recorder.selectedInputDeviceUID = device.uid
                            recorder.refreshCurrentInputName()
                        } label: {
                            HStack {
                                Text(device.name).foregroundStyle(Theme.fg)
                                Spacer()
                                if device.uid == recorder.selectedInputDeviceUID {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    #endif
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                }
            }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        #if os(iOS)
        .navigationTitle("Settings")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        #endif
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
