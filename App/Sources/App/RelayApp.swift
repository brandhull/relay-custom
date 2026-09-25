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
    #if os(macOS)
    @AppStorage("macAppearanceMode") private var appearanceMode: AppearanceMode = .system
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            RootTabView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(backupManager)
                .environmentObject(recorder)
                .preferredColorScheme(nil)
                .tint(Theme.accent)
            #else
            // Phase 2 (Mac port): Settings isn't ported yet (Phase 3) —
            // Record + Library only, sized like a small fixed utility
            // window ("like Calculator"), not a resizable/fullscreen app.
            TabView {
                RecordView()
                    .tabItem { Label("Record", systemImage: "water.waves") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "waveform") }
            }
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(backupManager)
            .environmentObject(recorder)
            .preferredColorScheme(appearanceMode.colorScheme)
            .tint(Theme.accent)
            .frame(width: 430, height: 520)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    AppearanceSwitcher()
                }
            }
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
