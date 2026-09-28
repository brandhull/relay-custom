#if os(macOS)
import SwiftUI
import AppKit

/// Grabs the hosting NSWindow via an invisible NSView and sets its level —
/// SwiftUI has no direct window-level API on macOS, so this is the standard
/// bridge. Re-applied on every `pinOnTop` change (updateNSView), and once
/// more on the next runloop tick after the view first attaches (makeNSView
/// runs before `view.window` is populated). Ported from Arthur's
/// PinOnTop.swift.
private struct WindowLevelAccessor: NSViewRepresentable {
    var pinOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        view.window?.level = pinOnTop ? .floating : .normal
    }
}

extension View {
    func pinnedOnTop(_ pinOnTop: Bool) -> some View {
        background(WindowLevelAccessor(pinOnTop: pinOnTop))
    }
}
#endif
