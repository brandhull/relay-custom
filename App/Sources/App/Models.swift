import Foundation

struct Recording: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var fileName: String
    var createdAt: Date
    var duration: TimeInterval
    var episode: EpisodeDraft
    /// True once the local audio file has been deleted (after upload) to
    /// reclaim space. The episode's metadata and history stay in the
    /// Library either way — only the audio blob is gone.
    var audioRemovedLocally: Bool = false
    /// True once this recording has been backed up to the user's chosen
    /// iCloud folder — drives the Library row's destination badges.
    var backedUpToICloud: Bool = false
    /// True once this recording's transcript/summary has been sent to
    /// Craft — drives the Library row's destination badges.
    var sentToCraft: Bool = false

    var fileURL: URL {
        Recording.directory.appendingPathComponent(fileName)
    }

    // Custom Codable so older saved recordings (before these fields existed)
    // still decode instead of silently losing the whole library.
    enum CodingKeys: String, CodingKey {
        case id, fileName, createdAt, duration, episode, audioRemovedLocally, backedUpToICloud, sentToCraft
    }

    init(id: UUID, fileName: String, createdAt: Date, duration: TimeInterval, episode: EpisodeDraft, audioRemovedLocally: Bool = false, backedUpToICloud: Bool = false, sentToCraft: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.episode = episode
        self.audioRemovedLocally = audioRemovedLocally
        self.backedUpToICloud = backedUpToICloud
        self.sentToCraft = sentToCraft
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        episode = try container.decode(EpisodeDraft.self, forKey: .episode)
        audioRemovedLocally = try container.decodeIfPresent(Bool.self, forKey: .audioRemovedLocally) ?? false
        backedUpToICloud = try container.decodeIfPresent(Bool.self, forKey: .backedUpToICloud) ?? false
        sentToCraft = try container.decodeIfPresent(Bool.self, forKey: .sentToCraft) ?? false
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

struct EpisodeDraft: Codable, Equatable, Hashable {
    var showId: String?
    var showTitle: String?
    var title: String = ""
    var summary: String = ""
    var description: String = ""
    var explicit: Bool = false
    var season: String = ""
    var number: String = ""

    // Publishing state
    var transistorEpisodeId: String?
    var transistorAudioURL: String?
    var status: PublishStatus = .notUploaded
    var publishedAt: Date?
    var syncedToBaserow: Bool = false
    /// Set once a Baserow row exists for this episode; subsequent syncs
    /// update that row instead of creating a duplicate.
    var baserowRowId: Int?
}

enum PublishStatus: String, Codable, Hashable {
    case notUploaded
    case draft
    case scheduled
    case published
}

struct TransistorShow: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
}
