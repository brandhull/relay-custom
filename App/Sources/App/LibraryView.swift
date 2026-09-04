import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: RecordingStore

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if store.recordings.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.recordings) { recording in
                            NavigationLink(value: recording) {
                                RecordingRow(recording: recording)
                            }
                            .listRowBackground(Theme.bg)
                        }
                        .onDelete { indexSet in
                            for index in indexSet { store.delete(store.recordings[index]) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Recording.self) { recording in
                EditRecordingView(recording: recording)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Theme.muted)
            Text("No Recordings Yet")
                .font(.headline)
                .foregroundStyle(Theme.fg)
            Text("Head to the Record tab to capture your first episode.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Which destinations this recording has actually been sent to — only
    /// non-empty entries render as badges, so a recording that's never left
    /// the device shows no badges at all.
    private var pushedDestinations: [String] {
        var labels: [String] = []
        if recording.backedUpToICloud { labels.append("iCloud") }
        if recording.episode.syncedToBaserow { labels.append("Baserow") }
        if recording.sentToCraft { labels.append("Craft") }
        if recording.episode.transistorEpisodeId != nil { labels.append("Transistor") }
        return labels
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.15))
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.episode.title.isEmpty ? "Untitled Recording" : recording.episode.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.fg)

                if isPad {
                    HStack(spacing: 10) {
                        metadataLine
                        ForEach(pushedDestinations, id: \.self) { destinationBadge($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                } else {
                    metadataLine
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    if !pushedDestinations.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(pushedDestinations, id: \.self) { destinationBadge($0) }
                        }
                        .font(.caption)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var metadataLine: some View {
        HStack(spacing: 4) {
            Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(timeString(recording.duration))")
            if recording.audioRemovedLocally {
                Image(systemName: "icloud.fill")
            }
        }
    }

    private func destinationBadge(_ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
            Text(label)
        }
        .foregroundStyle(.green)
    }

    private var statusIcon: String {
        switch recording.episode.status {
        case .notUploaded: return "waveform"
        case .draft: return "doc.text"
        case .scheduled: return "clock"
        case .published: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch recording.episode.status {
        case .notUploaded: return Theme.muted
        case .draft: return Theme.accent
        case .scheduled: return .orange
        case .published: return .green
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
