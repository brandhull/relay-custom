import SwiftUI

struct PublishView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @Binding var recording: Recording

    @State private var publishMode: PublishMode = .draft
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showShareSheet = false

    enum PublishMode: String, CaseIterable { case draft = "Save as Draft", schedule = "Schedule", now = "Publish Now" }

    var body: some View {
        VStack(spacing: 0) {
            form
            actions
        }
        .background(Theme.bg)
        .navigationTitle("Publish")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [recording.fileURL, shareSummary()])
        }
    }

    private var form: some View {
        Form {
            Section("Review") {
                LabeledContent("Show", value: recording.episode.showTitle ?? "Not selected")
                LabeledContent("Title", value: recording.episode.title.isEmpty ? "Untitled" : recording.episode.title)
                LabeledContent("Length", value: timeString(recording.duration))
            }

            Section("Publishing") {
                Picker("Mode", selection: $publishMode) {
                    ForEach(PublishMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Also Save To") {
                Toggle("Sync to Baserow", isOn: $settings.autoSyncBaserow)
                if !settings.hasBaserowConfig {
                    Text("Add your Baserow token + table ID in Settings to enable this.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Toggle("Transcribe to Craft", isOn: $settings.autoSendToCraft)
                if !settings.hasCraftConfig {
                    Text("Add your Craft API URL and folder in Settings to enable this.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }

            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await uploadToTransistor() }
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) }
                    Text("Upload to Transistor")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(isEnabled: !isWorking && settings.hasTransistorKey))
            .disabled(isWorking || !settings.hasTransistorKey)

            Button {
                showShareSheet = true
            } label: {
                Label("Share Episode", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.tintedAction)
            .disabled(recording.audioRemovedLocally)
        }
        .padding(16)
        .background(Theme.bg)
    }

    private func shareSummary() -> String {
        "\(recording.episode.title)\n\(recording.episode.summary)"
    }

    private func uploadToTransistor() async {
        guard settings.hasTransistorKey else {
            errorMessage = "Add your Transistor API key in Settings first."
            return
        }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        defer { isWorking = false }

        do {
            let api = TransistorAPI(apiKey: settings.transistorAPIKey)
            statusMessage = "Requesting upload URL..."
            let upload = try await api.authorizeUpload(fileName: recording.fileURL.lastPathComponent)

            statusMessage = "Uploading audio..."
            try await api.uploadAudio(fileURL: recording.fileURL, to: upload)
            recording.episode.transistorAudioURL = upload.audioURL

            statusMessage = "Creating episode..."
            let episodeId: String
            if let existingId = recording.episode.transistorEpisodeId {
                try await api.updateEpisode(id: existingId, draft: recording.episode)
                episodeId = existingId
            } else {
                episodeId = try await api.createEpisode(draft: recording.episode)
            }
            recording.episode.transistorEpisodeId = episodeId
            recording.episode.status = .draft

            switch publishMode {
            case .draft:
                try await api.publishEpisode(id: episodeId, status: "draft")
                recording.episode.status = .draft
            case .schedule:
                try await api.publishEpisode(id: episodeId, status: "scheduled")
                recording.episode.status = .scheduled
            case .now:
                try await api.publishEpisode(id: episodeId, status: "published")
                recording.episode.status = .published
                recording.episode.publishedAt = Date()
            }

            store.update(recording)
            statusMessage = "Done — episode \(publishMode == .now ? "published" : "saved") on Transistor."

            var baserowFailed = false
            if settings.autoSyncBaserow && settings.hasBaserowConfig {
                baserowFailed = await syncToBaserow() == false
            }

            var craftFailed = false
            if settings.autoSendToCraft && settings.hasCraftConfig {
                craftFailed = await sendToCraft() == false
            }

            // Only reclaim local space once every destination that needed
            // the file has actually read it — a failed Baserow/Craft send
            // keeps the file around so a retry has something to work with.
            if settings.autoDeleteAfterUpload && !baserowFailed && !craftFailed {
                store.deleteLocalAudio(for: recording.id)
                recording.audioRemovedLocally = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func syncToBaserow() async -> Bool {
        guard BaserowSyncCoordinator.begin(recording.id) else {
            // Another sync for this recording is already running — treat
            // this as unconfirmed rather than successful, so the caller's
            // auto-delete-local-audio logic doesn't fire before we know the
            // in-flight sync actually finished.
            statusMessage = (statusMessage ?? "") + " Baserow sync already in progress."
            return false
        }
        defer { BaserowSyncCoordinator.end(recording.id) }
        do {
            let baserow = BaserowAPI(token: settings.baserowToken, tableId: settings.baserowTableId)
            let uploaded = try await baserow.uploadFile(fileURL: recording.fileURL)
            if let rowId = recording.episode.baserowRowId {
                try await baserow.updateEpisodeRow(rowId: rowId, draft: recording.episode, recording: recording, uploadedFile: uploaded)
            } else {
                let rowId = try await baserow.createEpisodeRow(draft: recording.episode, recording: recording, uploadedFile: uploaded)
                recording.episode.baserowRowId = rowId
            }
            recording.episode.syncedToBaserow = true
            store.update(recording)
            statusMessage = (statusMessage ?? "") + " Synced to Baserow."
            return true
        } catch {
            errorMessage = "Baserow sync failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func sendToCraft() async -> Bool {
        do {
            let label = try await CraftPublisher.send(recording: recording, settings: settings)
            recording.sentToCraft = true
            store.update(recording)
            statusMessage = (statusMessage ?? "") + " \(label) sent to Craft."
            return true
        } catch {
            errorMessage = (errorMessage ?? "") + " Craft send failed: \(error.localizedDescription)"
            return false
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
