import SwiftUI

// Shared button treatments so every screen's actions look consistent:
// one primary (red, filled) style, one secondary (card) style, and one
// tinted style for lighter-weight actions like Share.
private let actionCornerRadius: CGFloat = 14
private let actionVerticalPadding: CGFloat = 14
// Only used on the Edit screen's 2x2 quick-action grid, which needs to fit
// alongside the waveform and the three footer buttons with no scrolling —
// its own smaller constant so shrinking it doesn't touch every other
// button in the app that shares actionVerticalPadding.
private let quickActionVerticalPadding: CGFloat = 8

struct PrimaryActionButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, actionVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: actionCornerRadius)
                    .fill(isEnabled ? Theme.danger : Theme.danger.opacity(0.4))
            )
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct TintedActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, actionVerticalPadding)
            .background(RoundedRectangle(cornerRadius: actionCornerRadius).fill(Theme.accent.opacity(0.15)))
            .foregroundStyle(Theme.accent)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Plain-text red style for rare, serious actions (e.g. permanent delete).
/// Deliberately lighter-weight than PrimaryActionButtonStyle's solid red
/// fill, which this app already uses as its everyday CTA color — a filled
/// destructive button here would read as "the next step," not "danger."
struct DestructiveActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, actionVerticalPadding)
            .foregroundStyle(Theme.danger)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Compact, centered card style for short-label actions arranged in a grid
/// (e.g. the Trim / iCloud / Baserow / Transcribe row on the Edit screen).
struct QuickActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, quickActionVerticalPadding)
            .background(RoundedRectangle(cornerRadius: actionCornerRadius).fill(Theme.card))
            .foregroundStyle(Theme.fg)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension ButtonStyle where Self == TintedActionButtonStyle {
    static var tintedAction: TintedActionButtonStyle { TintedActionButtonStyle() }
}

extension ButtonStyle where Self == DestructiveActionButtonStyle {
    static var destructiveAction: DestructiveActionButtonStyle { DestructiveActionButtonStyle() }
}

extension ButtonStyle where Self == QuickActionButtonStyle {
    static var quickAction: QuickActionButtonStyle { QuickActionButtonStyle() }
}
