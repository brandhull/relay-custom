import SwiftUI

struct RootTabView: View {
    enum Tab { case record, library, settings }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            TabView {
                RecordView()
                    .tabItem { Label("Record", systemImage: "mic.fill") }
                    .tag(Tab.record)

                LibraryView()
                    .tabItem { Label("Library", systemImage: "waveform") }
                    .tag(Tab.library)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(Tab.settings)
            }
            .tint(Theme.accent)
        }
    }
}
