import Foundation

/// Baserow sync can be triggered two ways — the manual "Baserow" quick
/// action on the Edit screen, and the automatic sync after a Transistor
/// upload — and both independently decide whether to create a new row or
/// update an existing one. Without this, back-to-back triggers can both
/// read "no row yet" before either finishes, creating two rows for one
/// episode. This just makes sure only one sync per recording runs at a time.
@MainActor
enum BaserowSyncCoordinator {
    private static var inFlight: Set<UUID> = []

    /// Claims the lock for a recording. Returns false if a sync for that
    /// recording is already running — the caller should skip rather than
    /// race it.
    static func begin(_ recordingId: UUID) -> Bool {
        guard !inFlight.contains(recordingId) else { return false }
        inFlight.insert(recordingId)
        return true
    }

    static func end(_ recordingId: UUID) {
        inFlight.remove(recordingId)
    }
}
