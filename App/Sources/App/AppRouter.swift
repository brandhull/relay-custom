import SwiftUI

enum AppTab { case record, library, settings }

/// Shared tab selection so a screen buried in a navigation stack (e.g. Edit's
/// Done button, reachable from Library) can send the user back to Record.
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .record
    /// Bumped when the Library tab is tapped while already showing, so the
    /// Library pops back to its list.
    @Published var libraryReselectCount = 0

    /// Call for every tab tap, including taps on the tab already selected.
    func select(_ tab: AppTab) {
        if tab == .library && selectedTab == .library { libraryReselectCount += 1 }
        selectedTab = tab
    }
}
