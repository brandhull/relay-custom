import Foundation
import Combine

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private var indexURL: URL {
        Recording.directory.appendingPathComponent("index.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else {
            recordings = []
            return
        }
        recordings = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save()
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        save()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    /// Deletes just the local audio blob for one recording, keeping its
    /// metadata/history in the Library.
    func deleteLocalAudio(for id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].audioRemovedLocally else { return }
        try? FileManager.default.removeItem(at: recordings[idx].fileURL)
        recordings[idx].audioRemovedLocally = true
        save()
    }

    /// Removes local audio for every published episode to reclaim space.
    /// Returns how many files were cleared.
    @discardableResult
    func clearUploadedAudio() -> Int {
        var count = 0
        for i in recordings.indices where recordings[i].episode.status == .published && !recordings[i].audioRemovedLocally {
            try? FileManager.default.removeItem(at: recordings[i].fileURL)
            recordings[i].audioRemovedLocally = true
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// Total bytes currently used by local audio files still on disk.
    func totalStorageBytes() -> Int64 {
        recordings.reduce(Int64(0)) { total, recording in
            guard !recording.audioRemovedLocally,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path),
                  let size = attrs[.size] as? Int64 else { return total }
            return total + size
        }
    }
}
