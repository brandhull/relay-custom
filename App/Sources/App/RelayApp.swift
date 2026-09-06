import SwiftUI

@main
struct RelayApp: App {
    // .shared here (not a fresh instance) so AppIntents — which run
    // in-process but outside the view hierarchy — can reach the exact same
    // store/recorder the UI is using via RecordingStore.shared /
    // AudioRecorder.shared, instead of talking to a second, disconnected
    // copy. RecordView and SettingsView also used to each create their own
    // AudioRecorder, which meant two independent objects fighting over the
    // one shared AVAudioSession (e.g. switching to Settings mid-recording
    // could re-activate/re-route the session out from under the recording
    // in progress) — one shared instance fixes that too.
    @StateObject private var store = RecordingStore.shared
    @StateObject private var settings = AppSettings()
    @StateObject private var backupManager = BackupManager()
    @StateObject private var recorder = AudioRecorder.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(backupManager)
                .environmentObject(recorder)
                .preferredColorScheme(nil)
                .tint(Theme.accent)
        }
    }
}
