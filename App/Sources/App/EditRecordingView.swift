import SwiftUI

struct EditRecordingView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayer()
    @State var recording: Recording

    @State private var trimStart: CGFloat = 0
    @State private var trimEnd: CGFloat = 1
    @State private var overwriteOriginal = false
    @State private var isSaving = false
    @State private var showShareSheet = false
    @State private var showDeleteConfirm = false
    @State private var showReplaceConfirm = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isTranscribing = false
    @State private var transcribeStatus: String?
    @FocusState private var titleFocused: Bool

    private var samples: [CGFloat] {
        WaveformView.placeholderSamples(seed: recording.id.hashValue)
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if !recording.audioRemovedLocally { player.load(url: recording.fileURL) }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [recording.fileURL])
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the audio file and removes it from your Library. This can't be undone.")
        }
        .confirmationDialog(
            "Replace the original recording?",
            isPresented: $showReplaceConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { Task { await saveTrimmed() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites the original audio with the trimmed version. This can't be undone.")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $recording.episode.title)
                    .font(.headline)
                    .foregroundStyle(Theme.fg)
                    .focused($titleFocused)
                    .onChange(of: recording.episode.title) { _, _ in store.update(recording) }
                Text("\(recording.createdAt.formatted(date: .numeric, time: .shortened)) · \(timeString(recording.duration)) · Recorded")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }

            if recording.audioRemovedLocally {
                audioRemovedNotice
                Spacer()
            } else {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.card)
                    WaveformView(
                        samples: samples,
                        progress: player.duration > 0 ? player.currentTime / player.duration : 0
                    )
                    .padding(.horizontal, 16)
                    TrimSelectorOverlay(trimStart: $trimStart, trimEnd: $trimEnd)
                        .padding(.horizontal, 16)
                }
                .frame(height: 100)

                HStack {
                    Text(timeString(player.currentTime))
                    Spacer()
                    if trimStart > 0 || trimEnd < 1 {
                        Text("Trim: \(timeString(Double(trimStart) * recording.duration))–\(timeString(Double(trimEnd) * recording.duration))")
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text(timeString(recording.duration))
                }
                .font(.caption)
                .foregroundStyle(Theme.muted)

                HStack {
                    Spacer()
                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                VStack(spacing: 12) {
                    if trimStart > 0 || trimEnd < 1 {
                        Toggle("Replace original instead of saving a copy", isOn: $overwriteOriginal)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 4)
                    }

                    HStack(spacing: 12) {
                        quickActionButton("scissors", overwriteOriginal ? "Replace" : "Trim") {
                            if overwriteOriginal {
                                showReplaceConfirm = true
                            } else {
                                await saveTrimmed()
                            }
                        }
                        .disabled(isSaving || (trimStart == 0 && trimEnd == 1))
                        quickActionButton("folder", "iCloud") { await saveToICloud() }
                    }
                    HStack(spacing: 12) {
                        quickActionButton("table", "Baserow") { await pushToBaserow() }
                        quickActionButton("doc.text", "Transcribe") { await transcribeToCraft() }
                    }
                    if isTranscribing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(transcribeStatus ?? "Working…")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    }
                }

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share Recording", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.tintedAction)
            }

            NavigationLink {
                EpisodeDetailsView(recording: $recording)
            } label: {
                Text("Continue to Episode Details")
            }
            .buttonStyle(.primaryAction)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("Delete Recording")
            }
            .buttonStyle(.destructiveAction)
        }
        .padding(20)
    }

    private var audioRemovedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent)
            Text("Audio Uploaded")
                .font(.headline)
                .foregroundStyle(Theme.fg)
            Text("The local copy was removed to save space after this episode uploaded successfully. It's safely stored on Transistor.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }

    private func quickActionButton(_ icon: String, _ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.quickAction)
        .disabled(isSaving || isTranscribing)
    }

    private func saveTrimmed() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let start = Double(trimStart) * recording.duration
            let end = Double(trimEnd) * recording.duration
            let url = try await AudioPlayer.trim(sourceURL: recording.fileURL, start: start, end: end)
            let newDuration = end - start

            if settings.iCloudBackupEnabled {
                backupManager.backup(fileURL: url)
            }

            if overwriteOriginal {
                let oldURL = recording.fileURL
                recording.fileName = url.lastPathComponent
                recording.duration = newDuration
                store.update(recording)
                try? FileManager.default.removeItem(at: oldURL)
                player.load(url: recording.fileURL)
                trimStart = 0
                trimEnd = 1
                overwriteOriginal = false
            } else {
                let copy = Recording(
                    id: UUID(),
                    fileName: url.lastPathComponent,
                    createdAt: Date(),
                    duration: newDuration,
                    episode: recording.episode
                )
                store.add(copy)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveToICloud() async {
        errorMessage = nil
        statusMessage = nil
        guard let folderName = backupManager.folderName else {
            errorMessage = "Choose a backup folder in Settings first."
            return
        }
        isSaving = true
        defer { isSaving = false }
        if backupManager.backup(fileURL: recording.fileURL) {
            recording.backedUpToICloud = true
            store.update(recording)
            statusMessage = "Saved to \(folderName)."
        } else {
            errorMessage = "Couldn't save to \(folderName) — check the folder is still accessible in Settings."
        }
    }

    private func pushToBaserow() async {
        errorMessage = nil
        statusMessage = nil
        guard settings.hasBaserowConfig else {
            errorMessage = "Add your Baserow token + table ID in Settings first."
            return
        }
        guard BaserowSyncCoordinator.begin(recording.id) else {
            statusMessage = "Already syncing to Baserow — hang tight."
            return
        }
        isSaving = true
        defer { isSaving = false; BaserowSyncCoordinator.end(recording.id) }
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
            statusMessage = "Pushed to Baserow."
        } catch {
            errorMessage = "Baserow push failed: \(error.localizedDescription)"
        }
    }

    private func transcribeToCraft() async {
        errorMessage = nil
        statusMessage = nil
        isTranscribing = true
        defer { isTranscribing = false; transcribeStatus = nil }

        do {
            let label = try await CraftPublisher.send(recording: recording, settings: settings) { status in
                Task { @MainActor in self.transcribeStatus = status }
            }
            recording.sentToCraft = true
            store.update(recording)
            statusMessage = "\(label) added to \(settings.craftFolderTitle.isEmpty ? "Craft" : settings.craftFolderTitle)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecording() {
        store.delete(recording)
        dismiss()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Draggable start/end trim handles over the waveform. Values are fractions
/// of the recording's total duration (0...1).
private struct TrimSelectorOverlay: View {
    @Binding var trimStart: CGFloat
    @Binding var trimEnd: CGFloat

    // Fraction value at the moment each drag began, so mid-drag re-renders
    // (which move the handle under the finger) don't compound with the
    // gesture's own translation.
    @State private var startAtDragBegin: CGFloat?
    @State private var endAtDragBegin: CGFloat?

    private let minGap: CGFloat = 0.02
    private let handleWidth: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let startX = trimStart * width
            let endX = trimEnd * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.bg.opacity(0.6))
                    .frame(width: startX)
                Rectangle()
                    .fill(Theme.bg.opacity(0.6))
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)

                Rectangle()
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)

                handle(x: startX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if startAtDragBegin == nil { startAtDragBegin = trimStart }
                                let proposed = (startAtDragBegin ?? trimStart) + value.translation.width / width
                                trimStart = min(max(0, proposed), trimEnd - minGap)
                            }
                            .onEnded { _ in startAtDragBegin = nil }
                    )

                handle(x: endX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if endAtDragBegin == nil { endAtDragBegin = trimEnd }
                                let proposed = (endAtDragBegin ?? trimEnd) + value.translation.width / width
                                trimEnd = max(min(1, proposed), trimStart + minGap)
                            }
                            .onEnded { _ in endAtDragBegin = nil }
                    )
            }
        }
    }

    private func handle(x: CGFloat) -> some View {
        ZStack {
            Color.clear.frame(width: handleWidth, height: 84)
            Capsule()
                .fill(Theme.accent)
                .frame(width: 6, height: 84)
        }
        .contentShape(Rectangle())
        .offset(x: x - handleWidth / 2)
    }
}

