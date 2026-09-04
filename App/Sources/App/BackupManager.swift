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
        return url
    }

    /// Copies a recording's audio file into the chosen backup folder, if one is set.
    @discardableResult
    func backup(fileURL: URL) -> Bool {
        guard let folder = resolveFolderURL() else { return false }
        guard folder.startAccessingSecurityScopedResource() else { return false }
        defer { folder.stopAccessingSecurityScopedResource() }

        let destination = folder.appendingPathComponent(fileURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return true
        } catch {
            print("Backup copy failed: \(error)")
            return false
        }
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
