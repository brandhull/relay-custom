import SwiftUI
import UniformTypeIdentifiers

/// Lets the user pick any folder (typically one inside iCloud Drive) as a
/// backup destination, and copies each new recording there. Uses the
/// standard document picker + security-scoped bookmark, so it needs no
/// iCloud container entitlement or paid developer team — it works with any
/// folder the user can already see in the Files app.
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var folderName: String?

    private let bookmarkKey = "backupFolderBookmark"

    init() {
        folderName = resolveFolderURL()?.lastPathComponent
    }

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            folderName = url.lastPathComponent
        } catch {
            print("Failed to bookmark backup folder: \(error)")
        }
    }

    func clearFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folderName = nil
    }

    private func resolveFolderURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let refreshed = try? url.bookmarkData() {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// Copies a recording's audio file into the chosen backup folder, if one is set.
    ///
    /// The destination is typically a File Provider location (iCloud Drive),
    /// not a plain filesystem path. A bare `FileManager.copyItem` can report
    /// success while the provider never actually registers the write for
    /// upload, so the copy runs through `NSFileCoordinator` — the mechanism
    /// Apple's own docs require for writing into a folder obtained via
    /// `UIDocumentPickerViewController`.
    @discardableResult
    func backup(fileURL: URL) -> Bool {
        guard let folder = resolveFolderURL() else { return false }
        guard folder.startAccessingSecurityScopedResource() else { return false }
        defer { folder.stopAccessingSecurityScopedResource() }

        let destination = folder.appendingPathComponent(fileURL.lastPathComponent)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copySucceeded = false

        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                try FileManager.default.copyItem(at: fileURL, to: coordinatedURL)
                copySucceeded = true
            } catch {
                print("Backup copy failed: \(error)")
            }
        }

        if let coordinationError {
            print("Backup coordination failed: \(coordinationError)")
            return false
        }
        return copySucceeded
    }
}

/// Presents the system document picker in folder-selection mode.
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
