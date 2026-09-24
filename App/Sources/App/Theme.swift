import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Bits color palette (~/Projects/bits/public/app.css), ported to SwiftUI.
enum Theme {
    static let bg = Color(light: 0xF5F4F0, dark: 0x101014)
    static let fg = Color(light: 0x1C1C1E, dark: 0xECECEE)
    static let muted = Color(light: 0x8A8A8E, dark: 0x8A8A92)
    static let card = Color(light: 0xFFFFFF, dark: 0x1B1B21)
    static let accent = Color(light: 0x2563EB, dark: 0x5B9BFF)
    static let accentFg = Color(light: 0xFFFFFF, dark: 0x0D1420)
    static let border = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    static let danger = Color(light: 0xC0392B, dark: 0xE6604F)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        #if os(iOS)
        self.init(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let (r, g, b) = rgb(hex)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = rgb(isDark ? dark : light)
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}
