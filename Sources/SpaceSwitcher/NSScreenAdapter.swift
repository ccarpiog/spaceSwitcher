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

    /// The SkyLight display UUID of the primary display.
    ///
    /// Asked of Core Graphics rather than of `NSScreen.main`, which is the screen
    /// holding the key window and moves with it. The primary display is the fixed
    /// one at the origin of the global coordinate space, and it is the display
    /// whose first Space SkyLight reports with an empty uuid — see
    /// `Space.nameKey(uuid:displayID:index:isPrimaryDisplay:)`.
    ///
    /// - Returns: the UUID string, or `nil` if Core Graphics will not give one,
    ///   which leaves no display matching and simply costs that Space its name key.
    static func primaryDisplayUUID() -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    /// The screen matching a SkyLight display UUID, if it is still connected.
    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { self.uuid(for: $0) == uuid }
    }
}
