import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var store = RecordingStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var backupManager = BackupManager()
    // Owned once here — RecordView and SettingsView both used to create
    // their own AudioRecorder, which meant two independent objects fighting
    // over the one shared AVAudioSession (e.g. switching to Settings
    // mid-recording could re-activate/re-route the session out from under
    // the recording in progress). One shared instance now.
    @StateObject private var recorder = AudioRecorder()

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
