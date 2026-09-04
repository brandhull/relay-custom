import Foundation
import Combine

/// Backs most settings with `NSUbiquitousKeyValueStore` so they sync across
/// the user's devices via iCloud (requires the iCloud Key-Value Storage
/// entitlement — see Relay.entitlements). API keys/tokens are the
/// exception: they live in the Keychain instead, via `KeychainHelper`.
@MainActor
final class AppSettings: ObservableObject {
    private let kv = NSUbiquitousKeyValueStore.default
    private var externalChangeObserver: NSObjectProtocol?

    @Published var transistorAPIKey: String {
        didSet { KeychainHelper.set(transistorAPIKey, key: "transistorAPIKey") }
    }
    @Published var baserowToken: String {
        didSet { KeychainHelper.set(baserowToken, key: "baserowToken") }
    }
    @Published var baserowTableId: String {
        didSet { kv.set(baserowTableId, forKey: "baserowTableId") }
    }
    @Published var autoSyncBaserow: Bool {
        didSet { kv.set(autoSyncBaserow, forKey: "autoSyncBaserow") }
    }
    /// Whether Publish also sends a transcript/summary to Craft after a
    /// successful Transistor upload — mirrors autoSyncBaserow, off by
    /// default since transcription is a heavier operation than a metadata
    /// sync and shouldn't fire as a surprise.
    @Published var autoSendToCraft: Bool {
        didSet { kv.set(autoSendToCraft, forKey: "autoSendToCraft") }
    }
    @Published var cachedShows: [TransistorShow] {
        didSet {
            if let data = try? JSONEncoder().encode(cachedShows) {
                kv.set(data, forKey: "cachedShows")
            }
        }
    }
    @Published var autoDeleteAfterUpload: Bool {
        didSet { kv.set(autoDeleteAfterUpload, forKey: "autoDeleteAfterUpload") }
    }
    @Published var iCloudBackupEnabled: Bool {
        didSet { kv.set(iCloudBackupEnabled, forKey: "iCloudBackupEnabled") }
    }
    @Published var craftAPIURL: String {
        didSet { kv.set(craftAPIURL, forKey: "craftAPIURL") }
    }
    @Published var craftFolderId: String {
        didSet { kv.set(craftFolderId, forKey: "craftFolderId") }
    }
    @Published var craftFolderTitle: String {
        didSet { kv.set(craftFolderTitle, forKey: "craftFolderTitle") }
    }
    @Published var cachedCraftFolders: [CraftFolder] {
        didSet {
            if let data = try? JSONEncoder().encode(cachedCraftFolders) {
                kv.set(data, forKey: "cachedCraftFolders")
            }
        }
    }
    /// Recordings longer than this switch from full transcript to a summary
    /// (when on-device summarization is available) when sent to Craft.
    @Published var summarizeThresholdMinutes: Int {
        didSet { kv.set(Int64(summarizeThresholdMinutes), forKey: "summarizeThresholdMinutes") }
    }

    init() {
        transistorAPIKey = KeychainHelper.get(key: "transistorAPIKey") ?? ""
        baserowToken = KeychainHelper.get(key: "baserowToken") ?? ""
        baserowTableId = kv.string(forKey: "baserowTableId") ?? ""
        autoSyncBaserow = kv.object(forKey: "autoSyncBaserow") != nil ? kv.bool(forKey: "autoSyncBaserow") : true
        autoSendToCraft = kv.bool(forKey: "autoSendToCraft")
        autoDeleteAfterUpload = kv.bool(forKey: "autoDeleteAfterUpload")
        iCloudBackupEnabled = kv.bool(forKey: "iCloudBackupEnabled")
        craftAPIURL = kv.string(forKey: "craftAPIURL") ?? ""
        craftFolderId = kv.string(forKey: "craftFolderId") ?? ""
        craftFolderTitle = kv.string(forKey: "craftFolderTitle") ?? ""
        let threshold = kv.longLong(forKey: "summarizeThresholdMinutes")
        summarizeThresholdMinutes = threshold > 0 ? Int(threshold) : 5
        if let data = kv.data(forKey: "cachedShows"),
           let shows = try? JSONDecoder().decode([TransistorShow].self, from: data) {
            cachedShows = shows
        } else {
            cachedShows = []
        }
        if let data = kv.data(forKey: "cachedCraftFolders"),
           let folders = try? JSONDecoder().decode([CraftFolder].self, from: data) {
            cachedCraftFolders = folders
        } else {
            cachedCraftFolders = []
        }

        kv.synchronize()
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadFromCloud() }
        }
    }

    deinit {
        if let externalChangeObserver {
            NotificationCenter.default.removeObserver(externalChangeObserver)
        }
    }

    /// Pulls in values changed on another device. Re-assigning each
    /// @Published property re-triggers its didSet, which just writes the
    /// same value back to the store — harmless, and keeps this in one path
    /// instead of a separate read-only sync routine.
    private func reloadFromCloud() {
        baserowTableId = kv.string(forKey: "baserowTableId") ?? baserowTableId
        autoSyncBaserow = kv.object(forKey: "autoSyncBaserow") != nil ? kv.bool(forKey: "autoSyncBaserow") : autoSyncBaserow
        autoSendToCraft = kv.bool(forKey: "autoSendToCraft")
        autoDeleteAfterUpload = kv.bool(forKey: "autoDeleteAfterUpload")
        iCloudBackupEnabled = kv.bool(forKey: "iCloudBackupEnabled")
        craftAPIURL = kv.string(forKey: "craftAPIURL") ?? craftAPIURL
        craftFolderId = kv.string(forKey: "craftFolderId") ?? craftFolderId
        craftFolderTitle = kv.string(forKey: "craftFolderTitle") ?? craftFolderTitle
        let threshold = kv.longLong(forKey: "summarizeThresholdMinutes")
        if threshold > 0 { summarizeThresholdMinutes = Int(threshold) }
        if let data = kv.data(forKey: "cachedShows"),
           let shows = try? JSONDecoder().decode([TransistorShow].self, from: data) {
            cachedShows = shows
        }
        if let data = kv.data(forKey: "cachedCraftFolders"),
           let folders = try? JSONDecoder().decode([CraftFolder].self, from: data) {
            cachedCraftFolders = folders
        }
    }

    var hasTransistorKey: Bool { !transistorAPIKey.isEmpty }
    var hasBaserowConfig: Bool { !baserowToken.isEmpty && !baserowTableId.isEmpty }
    var hasCraftConfig: Bool { !craftAPIURL.isEmpty && !craftFolderId.isEmpty }
}
