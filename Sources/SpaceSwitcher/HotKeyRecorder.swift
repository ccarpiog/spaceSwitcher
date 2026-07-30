import AppKit
import SwiftUI

/// The control that reads a new global shortcut off the keyboard.
///
/// Clicking it starts capture, the next key press becomes the shortcut, and
/// Escape gives up. While capturing, every key event in the app is swallowed:
/// reading the keyboard is the entire point of the control, so letting the events
/// through as well would mean recording `⌘W` closes the window it was recorded in.
///
/// The capture itself belongs to `HotKeyController`, monitor and all. This view
/// only asks for it to start and stop: a SwiftUI view is a value that can be
/// rebuilt, discarded and duplicated at the framework's discretion, which is no
/// basis for owning a process-wide event monitor.
struct HotKeyRecorder: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var hotKeys: HotKeyController

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleCapture) {
                Text(label)
                    .frame(minWidth: 88)
            }
            .buttonStyle(.bordered)
            .help(NSLocalizedString("settings.general.hotKey.help",
                                    comment: "Tooltip on the shortcut recorder button"))

            Button(NSLocalizedString("settings.general.hotKey.reset",
                                     comment: "Button restoring the default shortcut")) {
                hotKeys.stopCapturing()
                hotKeys.restoreDefault()
            }
            // Enabled whenever either half is not the default: after a launch
            // fallback the store holds the user's own shortcut while the default
            // is what is registered, and this button is how that is settled.
            .disabled(preferences.hotKey == .default
                      && hotKeys.activeCombination == .default)
        }
        // Capture must not outlive the window it belongs to. A monitor left
        // installed would go on swallowing every key press in the app, with the
        // shortcut stood down and no visible control to end it — the panel would
        // simply stop responding.
        .onDisappear(perform: hotKeys.stopCapturing)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            hotKeys.stopCapturing()
        }
        // Losing focus ends capture too: a recorder that keeps listening while the
        // user is working in another app is reading keystrokes not meant for it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hotKeys.stopCapturing()
        }
    } // End of body

    /// What the button reads: the shortcut in force, or the invitation to type
    /// one while capturing.
    ///
    /// The registered combination rather than the stored one, so a shortcut that
    /// was refused at launch is never displayed as though it were working. The
    /// store is only fallen back on when nothing is registered at all, where
    /// showing the user's own choice is the least misleading thing available.
    private var label: String {
        if hotKeys.isRecording {
            return NSLocalizedString(
                "settings.general.hotKey.recording",
                comment: "Shown on the recorder button while it waits for a key press")
        }
        return (hotKeys.activeCombination ?? preferences.hotKey).displayString
    }

    /// Clicking the button: start capturing, or stop if it already is.
    private func toggleCapture() {
        if hotKeys.isRecording {
            hotKeys.stopCapturing()
        } else {
            hotKeys.startCapturing()
        }
    }
}
