import AppKit
import CoreGraphics

/// Bridges `NSScreen` to the display UUIDs SkyLight reports, so Spaces can be
/// grouped under a display name the user recognises.
struct NSScreenAdapter {

    /// One screen, paired with the UUID string SkyLight uses to identify it.
    struct ScreenInfo {
        let uuid: String?
        let name: String
        let frame: CGRect
    }

    /// All active screens with their SkyLight UUIDs resolved.
    static func allScreens() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            ScreenInfo(
                uuid: uuid(for: screen),
                name: screen.localizedName,
                frame: screen.frame
            )
        }
    }

    /// The SkyLight display UUID for a screen.
    ///
    /// `NSScreen` exposes a `CGDirectDisplayID`, which Core Graphics can convert
    /// into the same UUID string that appears as `"Display Identifier"` in
    /// `CGSCopyManagedDisplaySpaces` output.
    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    /// The screen matching a SkyLight display UUID, if it is still connected.
    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { self.uuid(for: $0) == uuid }
    }
}
