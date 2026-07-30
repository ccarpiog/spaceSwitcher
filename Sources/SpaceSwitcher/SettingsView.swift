import AppKit
import SwiftUI

/// The Settings window's contents: one tab per section.
///
/// "General" holds what affects the app as a whole; "Spaces" is the list of
/// Spaces and the names given to them.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var hotKeys: HotKeyController
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var spaces: SpacesSettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences,
                                hotKeys: hotKeys,
                                loginItem: loginItem)
                .tabItem {
                    Label(NSLocalizedString("settings.tab.general",
                                            comment: "Name of the general settings tab"),
                          systemImage: "gearshape")
                }

            SpacesSettingsView(preferences: preferences, model: spaces)
                .tabItem {
                    Label(NSLocalizedString("settings.tab.spaces",
                                            comment: "Name of the Space renaming tab"),
                          systemImage: "square.grid.2x2")
                }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

/// The "General" section: settings that affect the app as a whole rather than a
/// particular Space.
struct GeneralSettingsView: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var hotKeys: HotKeyController
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HotKeyRecorder(preferences: preferences, hotKeys: hotKeys)
                } label: {
                    Text(NSLocalizedString("settings.general.hotKey",
                                           comment: "Label of the global shortcut row"))
                }

                // Registering can fail for reasons only the user can resolve —
                // another app already owns the combination — so the refusal is
                // shown here rather than logged where nobody will read it.
                if let failure = hotKeys.failure {
                    note(failure.message, isWarning: true)
                }
            } footer: {
                note(NSLocalizedString("settings.general.hotKey.detail",
                                       comment: "Explains how to record a new shortcut"))
            }

            Section {
                Toggle(NSLocalizedString("settings.general.login",
                                         comment: "Label of the open-at-login toggle"),
                       isOn: Binding(get: { loginItem.isEnabled },
                                     set: { loginItem.setEnabled($0) }))

                if let notice = loginItem.notice {
                    note(notice, isWarning: true)
                }

                if loginItem.offersSystemSettings {
                    Button(NSLocalizedString(
                        "settings.general.login.openSystemSettings",
                        comment: "Button opening the login items list in System Settings")) {
                            loginItem.openSystemSettings()
                        }
                }
            } footer: {
                note(NSLocalizedString("settings.general.login.detail",
                                       comment: "Explains what opening at login does"))
            }

            Section {
                Toggle(NSLocalizedString("settings.general.menuBarIcon",
                                         comment: "Label of the menu bar icon toggle"),
                       isOn: $preferences.showsMenuBarIcon)
            } footer: {
                // Worth spelling out: the menu bar icon is where Quit lives, and a
                // user who never turns it on has no obvious way to end the app.
                note(NSLocalizedString("settings.general.menuBarIcon.detail",
                                       comment: "Explains what the menu bar icon is for"))
            }
        }
        .formStyle(.grouped)
        // The login item can be revoked in System Settings behind the app's back,
        // so the state is re-read rather than remembered from last time.
        .onAppear(perform: loginItem.refresh)
        // And again whenever the app comes back to the front. The button above
        // sends the user to System Settings to approve the item; without this the
        // toggle would still read "off" when they returned, and would go on doing
        // so until the window was closed and reopened.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItem.refresh()
            }
    } // End of body

    /// One line of explanatory text under a control.
    ///
    /// - Parameters:
    ///   - text: the already localised message.
    ///   - isWarning: `true` for something that went wrong, which is tinted rather
    ///     than left in the secondary grey every other note uses.
    private func note(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
