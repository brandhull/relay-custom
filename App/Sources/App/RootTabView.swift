import SwiftUI

struct RootTabView: View {
    @StateObject private var router = AppRouter()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
                RecordView()
                    .tabItem { Label("Record", systemImage: "mic.fill") }
                    .tag(AppTab.record)

                LibraryView()
                    .tabItem { Label("Library", systemImage: "waveform") }
                    .tag(AppTab.library)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
            }
            .tint(Theme.accent)
        }
        .environmentObject(router)
    }
}
