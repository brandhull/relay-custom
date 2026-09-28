#if os(macOS)
import SwiftUI

enum AppearanceMode: String {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 3 always-visible icon buttons (System/Light/Dark), Mac-only — matches
/// the pattern used in Arthur/Maverick. Stored via @AppStorage (plain
/// UserDefaults), not through AppSettings' iCloud-synced store: toggling
/// appearance on the Mac shouldn't also flip it on Brandon's iPhone/iPad,
/// the exact thing Arthur's own AppearanceSwitcher was built to avoid.
struct AppearanceSwitcher: View {
    @AppStorage("macAppearanceMode") private var mode: AppearanceMode = .system

    var body: some View {
        HStack(spacing: 2) {
            button(.system, systemImage: "circle.lefthalf.filled")
            button(.light, systemImage: "sun.max")
            button(.dark, systemImage: "moon")
        }
    }

    private func button(_ target: AppearanceMode, systemImage: String) -> some View {
        let isActive = mode == target
        return Button {
            mode = target
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.accent : Theme.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
