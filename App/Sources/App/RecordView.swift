import SwiftUI

struct RecordView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var backupManager: BackupManager
    @EnvironmentObject var recorder: AudioRecorder
    @State private var justRecorded: Recording?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                let isPortrait = geo.size.height >= geo.size.width
                let logoSize: CGFloat = (isPad || isPortrait) ? 56 : 32

                VStack(spacing: 0) {
                    Image(systemName: "water.waves")
                        .font(.system(size: logoSize, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 64)

                    Spacer()

                    VStack(spacing: 8) {
                        Text(timeString(recorder.elapsed))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.fg)

                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }

                    if recorder.isRecording {
                        ProgressBar(level: recorder.meterLevel)
                            .frame(height: 4)
                            .padding(.horizontal, 40)
                            .padding(.top, 24)
                    }

                    Spacer()

                    HStack(spacing: 32) {
                        if recorder.isRecording {
                            Button {
                                if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                            } label: {
                                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.danger)
                                    .frame(width: 52, height: 52)
                                    .background(Circle().fill(Theme.card))
                            }
                        }

                        Button {
                            toggleRecord()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Theme.danger, lineWidth: 4)
                                    .frame(width: 84, height: 84)
                                if recorder.isRecording {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.danger)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                colors: [Theme.danger.opacity(0.9), Theme.danger],
                                                center: .center, startRadius: 5, endRadius: 45
                                            )
                                        )
                                        .frame(width: 72, height: 72)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)

                    if !recorder.currentInputName.isEmpty {
                        Label(recorder.currentInputName, systemImage: micIcon)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .navigationDestination(item: $justRecorded) { recording in
                EditRecordingView(recording: recording)
            }
        }
        .task {
            _ = await recorder.requestPermission()
            recorder.configureSessionPreferringExternalMic()
        }
    }

    private var micIcon: String {
        recorder.currentInputName.lowercased().contains("iphone") ||
        recorder.currentInputName.lowercased().contains("built") ? "mic" : "mic.badge.plus"
    }

    private var statusText: String {
        if recorder.isRecording {
            return recorder.isPaused ? "Paused" : "Recording..."
        }
        return "Ready to record"
    }

    private func toggleRecord() {
        if recorder.isRecording {
            let duration = recorder.stop()
            guard let url = recorder.outputURL else { return }
            var recording = Recording(
                id: UUID(),
                fileName: url.lastPathComponent,
                createdAt: Date(),
                duration: duration,
                episode: EpisodeDraft(title: defaultTitle())
            )
            store.add(recording)
            if settings.iCloudBackupEnabled {
                if backupManager.backup(fileURL: recording.fileURL) {
                    recording.backedUpToICloud = true
                    store.update(recording)
                }
            }
            justRecorded = recording
        } else {
            recorder.startRecording()
        }
    }

    private func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Recording \(formatter.string(from: Date()))"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private struct ProgressBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(Theme.danger)
                    .frame(width: geo.size.width * CGFloat(max(0.03, level)))
            }
        }
    }
}
