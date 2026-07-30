import AppKit
import Combine
import ServiceManagement

/// The "open at login" setting, expressed as whatever macOS currently thinks
/// rather than as a flag of our own.
///
/// Nothing is cached on purpose. A login item can be switched off in System
/// Settings › General › Login items without the app ever hearing about it, so a
/// stored boolean would drift out of step and the toggle would state something
/// untrue. `SMAppService.mainApp.status` is the only source of truth, re-read
/// every time the Settings window comes up.
@MainActor
final class LoginItemController: ObservableObject {

    /// The instance the app runs on.
    static let shared = LoginItemController()

    /// What macOS last reported.
    @Published private(set) var status: SMAppService.Status = .notRegistered

    /// The message from the last `register()` or `unregister()` that threw.
    /// Kept separate from `status`, since a failure leaves the status truthful and
    /// only the attempt worth reporting.
    @Published private(set) var errorMessage: String?

    /// Reads the status straight away so the toggle is never drawn wrong first
    /// and corrected a frame later. Safe here because nothing touches this class
    /// before the app has launched.
    private init() {
        status = SMAppService.mainApp.status
    }

    /// Whether the toggle reads as on.
    ///
    /// Only `.enabled` counts. `.requiresApproval` means macOS holds the item but
    /// is not launching it, and showing that as on would promise something that is
    /// not going to happen.
    var isEnabled: Bool { status == .enabled }

    /// What to say beyond the plain description, or `nil` when there is nothing
    /// to explain.
    var notice: String? {
        if let errorMessage { return errorMessage }

        switch status {
        case .requiresApproval:
            return NSLocalizedString(
                "settings.general.login.requiresApproval",
                comment: "Shown when macOS is holding the login item pending approval")
        case .notFound:
            // The usual cause is running a copy macOS does not consider installed,
            // e.g. straight out of the build directory.
            return NSLocalizedString(
                "settings.general.login.notFound",
                comment: "Shown when macOS does not recognise this copy of the app")
        default:
            return nil
        }
    } // End of notice

    /// Whether the shortcut into System Settings is worth offering. Only for
    /// `.requiresApproval`, which is the one state the user can resolve there.
    var offersSystemSettings: Bool { status == .requiresApproval }

    /// Re-reads the status from macOS, discarding any stale error.
    ///
    /// Called on every activation of the app, not only when Settings opens, so the
    /// assignments are guarded: an unconditional write to a `@Published` property
    /// notifies subscribers whether or not anything changed, and the usual reason
    /// the app is activated is that the panel came up.
    func refresh() {
        if errorMessage != nil { errorMessage = nil }

        let current = SMAppService.mainApp.status
        if current != status { status = current }
    } // End of refresh()

    /// Registers or unregisters the app as a login item.
    ///
    /// The status is read back afterwards instead of being assumed: a successful
    /// `register()` can still leave the item `.requiresApproval`, and
    /// unregistering something that was never registered is a silent no-op. It is
    /// assigned directly rather than through `refresh()`, which would wipe the
    /// error just recorded.
    ///
    /// - Parameter enabled: the state the user asked for.
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = String(
                format: NSLocalizedString(
                    "settings.general.login.failed",
                    comment: "Shown when changing the login item threw; %@ is the "
                        + "system's description of the error"),
                error.localizedDescription)
        }
        status = SMAppService.mainApp.status
    } // End of setEnabled(_:)

    /// Opens System Settings at the login items list.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
