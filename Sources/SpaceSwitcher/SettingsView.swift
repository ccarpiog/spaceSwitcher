import SwiftUI

/// The Settings window's contents: one tab per section.
///
/// The tab bar is deliberately here from the start even though there is only one
/// section so far. The remaining work slots in without reshaping anything: the
/// hotkey and open-at-login controls join "General", and the Space renaming list
/// arrives as a second tab beside it.
struct SettingsView: View {

    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences)
                .tabItem {
                    Label(NSLocalizedString("settings.tab.general",
                                            comment: "Name of the general settings tab"),
                          systemImage: "gearshape")
                }
        }
        .frame(minWidth: 460, minHeight: 240)
    }
}

/// The "General" section: settings that affect the app as a whole rather than a
/// particular Space.
struct GeneralSettingsView: View {

    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("settings.general.menuBarIcon",
                                         comment: "Label of the menu bar icon toggle"),
                       isOn: $preferences.showsMenuBarIcon)
            } footer: {
                // Worth spelling out: the menu bar icon is where Quit lives, and a
                // user who never turns it on has no obvious way to end the app.
                Text(NSLocalizedString("settings.general.menuBarIcon.detail",
                                       comment: "Explains what the menu bar icon is for"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
