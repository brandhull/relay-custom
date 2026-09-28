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
    @AppStorage("macPinOnTop") private var pinOnTop: Bool = false
    @State private var macTab: MacTab = .record
    // 620 gave the top bar breathing room, but EditRecordingView's content
    // (waveform, quick actions, footer, plus a status/error line once one
    // of the quick actions runs) measured at ~672pt of real content —
    // taller than the 620 budget by just enough to force a scroll for the
    // last sliver (the bottom of Delete Recording), which is exactly the
    // "I don't want to have to scroll" case Brandon flagged. 720 gives
    // clear headroom above that measured worst case.
    private static let windowHeight: CGFloat = 720
    private static let topBarHeight: CGFloat = 56
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
            // Record + Library + Settings, sized like a small fixed utility
            // window ("like Calculator"), not a resizable/fullscreen app.
            //
            // Pin + appearance icons live in a plain in-content HStack, NOT
            // a `.toolbar { ToolbarItem }` — macOS draws its own grouping/
            // segmented chrome around adjacent toolbar items regardless of
            // .buttonStyle(.plain) on the buttons inside. Matches Arthur's
            // topBar (MacAgendaLayout.swift), which is a plain HStack for
            // exactly this reason.
            //
            // The Record/Library switcher is a hand-built pill, not SwiftUI's
            // native macOS `TabView` — the native tab strip is opaque AppKit
            // chrome that paints over any other SwiftUI content sharing its
            // row (confirmed: icons placed there were hit-testable via
            // accessibility but never actually painted). Building our own
            // pill puts the whole top row under normal SwiftUI layout, so
            // the icons can share the exact same line as the tabs, per
            // Brandon's "same horizontal level" ask — and it's styled to
            // match the native pill it replaces pixel-for-pixel.
            VStack(spacing: 0) {
                // Left-justified, not centered — a centered pill would grow
                // toward the icons on the right as tabs were added (3
                // segments visibly overlapped the pin/appearance icons at
                // this window width), and left-aligned never competes with
                // them regardless of pill width.
                HStack(spacing: 2) {
                    MacTabPill(selection: $macTab)
                    Spacer()
                    Button {
                        pinOnTop.toggle()
                    } label: {
                        Image(systemName: "mappin")
                            .font(.system(size: 13, weight: pinOnTop ? .semibold : .regular))
                            .foregroundStyle(pinOnTop ? Theme.accent : Theme.muted)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    AppearanceSwitcher()
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 16)
                // A *fixed* height, not maxHeight: .infinity — SettingsView's
                // Form ignores a flexible height proposal and reports its
                // own full intrinsic content height regardless (confirmed:
                // maxHeight: .infinity here had zero effect), which grows
                // this whole VStack past the window's fixed 520pt and the
                // outer .frame below then crops it symmetrically around
                // center — pushing this tab bar up out of the visible
                // window instead of just letting Form scroll internally.
                // Giving both rows below an exact height instead of a
                // proposal, plus .clipped(), forces Form into a real
                // scrollable region instead of dictating the window's size.
                .frame(height: Self.topBarHeight)

                Group {
                    switch macTab {
                    case .record: RecordView()
                    case .library: LibraryView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.windowHeight - Self.topBarHeight)
                .clipped()
            }
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(backupManager)
            .environmentObject(recorder)
            .preferredColorScheme(appearanceMode.colorScheme)
            .tint(Theme.accent)
            .frame(width: 430, height: Self.windowHeight)
            .pinnedOnTop(pinOnTop)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

#if os(macOS)
private enum MacTab {
    case record, library, settings
}

/// Hand-built replacement for SwiftUI's native macOS TabView pill — see the
/// comment above its call site in RelayApp.body for why. Styled to match
/// the native pill it replaces: a capsule track with a lighter capsule
/// riding on top of whichever segment is selected.
private struct MacTabPill: View {
    @Binding var selection: MacTab

    var body: some View {
        HStack(spacing: 2) {
            segment("Record", tab: .record)
            segment("Library", tab: .library)
            segment("Settings", tab: .settings)
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func segment(_ title: String, tab: MacTab) -> some View {
        let isActive = selection == tab
        return Button {
            selection = tab
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.fg : Theme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(isActive ? Color.white.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
#endif
