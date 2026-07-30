import AppKit
import SwiftUI

/// A borderless floating panel that can take key events without activating the
/// app in the usual sense.
///
/// `.nonactivatingPanel` plus `canBecomeKey` lets the panel own the keyboard
/// while it is up, and `.canJoinAllSpaces` is essential: a window that exists on
/// every Space stops macOS from yanking the active Space back to wherever this
/// app "lives" once the switch happens.
final class HUDPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when the user dismisses the panel with Escape or by clicking away.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
    } // End of init(contentRect:)

    /// Routes Escape to cancellation; everything else goes to the content view.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Centres the panel on whichever screen currently holds the mouse, so it
    /// appears where the user is looking on a multi-display setup.
    func centreOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let size = frame.size
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        setFrameOrigin(origin)
    } // End of centreOnActiveScreen()
}
