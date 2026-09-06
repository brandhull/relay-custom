import AppIntents
import Foundation

/// Exposes `Recording` to Shortcuts as a pickable entity — e.g. so Export
/// Recording can show a list of recordings by title/date instead of always
/// grabbing the most recent one.
struct RecordingEntity: AppEntity {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Recording"
    static var defaultQuery = RecordingQuery()

    var displayRepresentation: DisplayRepresentation {
        let subtitle = "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.formatted(duration))"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    private static func formatted(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    @MainActor
    init(_ recording: Recording) {
        id = recording.id
        title = recording.episode.title.isEmpty ? "Untitled Recording" : recording.episode.title
        createdAt = recording.createdAt
        duration = recording.duration
    }
}

struct RecordingQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [RecordingEntity.ID]) async throws -> [RecordingEntity] {
        RecordingStore.shared.recordings
            .filter { identifiers.contains($0.id) }
            .map(RecordingEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RecordingEntity] {
        RecordingStore.shared.recordings.prefix(10).map(RecordingEntity.init)
    }
}
