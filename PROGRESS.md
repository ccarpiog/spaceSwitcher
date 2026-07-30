# PROGRESS — Settings window

Implementation checkpoint for `todo.md`: *"Add a Settings window that allows
changing the keyboard shortcut, opening at login and renaming spaces."*

This file is the authoritative state. A fresh session should be able to resume
from it without any conversation history.

## Roadmap

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Preferences store, Settings window shell, entry points (gear, menu bar icon, ⌘,) | **done**, verified, committed |
| 2 | General tab: configurable hotkey + open at login | not started |
| 3 | Space renaming (persistent identity + Settings list + HUD display) | not started |

## Phase 1 — completed

**What was built**

- `Preferences.swift` — `@MainActor`, `ObservableObject`, `UserDefaults`-backed,
  keys namespaced with the bundle id. Holds `showsMenuBarIcon`; the phase-2 and
  phase-3 key names are reserved in a comment so they stay consistent.
- `SettingsWindow.swift` — one reusable window (`isReleasedWhenClosed = false`),
  `SettingsWindowController.shared` shows or re-focuses it. `.moveToActiveSpace`
  so opening Settings never drags the user off their current Space.
- `SettingsView.swift` — a `TabView` with a General tab. Phase 2 extends that tab;
  phase 3 adds a Spaces tab.
- `MenuBarController.swift` — `NSStatusItem` created and torn down live from a
  Combine subscription. Menu: show the panel, Settings…, Quit.
- Gear button in the HUD hint bar, and `⌘,` handled in the panel's key monitor
  and in `SettingsWindow.performKeyEquivalent`.

**Acceptance**

| Criterion | Met | Evidence |
| --- | --- | --- |
| `swift build` clean | yes | exit 0, full recompile after `touch`, zero warnings |
| `./build.sh` produces the bundle | yes | exit 0, signed `build/spaceSwitcher.app` |
| en/es string keys identical | yes | key sets diffed, no difference; 9 new keys |
| Single Settings instance, re-focuses | yes | code review of `SettingsWindowController` |
| Status item lives off the preference | yes | code review + launch smoke test with the pref on |

**Notable additions beyond the literal ask**

- **Quit.** The app previously had no way out except killing the process. The
  status menu now has one. It is the only quit affordance; the panel's plain `q`
  is unchanged.
- **`⌘W`** closes the Settings window. With no menu bar there is no File ▸ Close,
  so without it the window could only be dismissed with the mouse.

**Deviations and decisions**

- The HUD's key monitor is app-wide, so it now defers whenever a *different*
  window is key — otherwise `q` typed into a Settings text field would quit the
  app. A `nil` key window still proceeds, which preserves the existing behaviour
  during the instant between the panel being ordered front and becoming key.
- `MenuBarController.start()` is called from `SwitcherController.start()` rather
  than from `init`, so nothing touches `NSStatusBar` before `NSApp.run()`.
- `MenuBarController.init` takes `preferences` explicitly with no default: a
  default argument is evaluated in a nonisolated context and cannot read a
  main-actor-isolated `static let`.
- The status menu has no key equivalents — they only fire while the menu is open,
  so `⌘Q` there would advertise a shortcut that works nowhere else.

**Codex review** — `docs/reviews/phase1-settings-foundation.md`

Three findings. Two accepted and fixed (`Preferences` isolated to `@MainActor`;
Caps Lock masked out of the `⌘,`/`⌘W` comparison, which otherwise broke both
shortcuts whenever Caps Lock was on). One refuted: Codex claimed the project
would not compile without `import Combine`, but both builds exited 0 on that
exact tree — Darwin's `Foundation` re-exports `Combine`. The import was added
anyway for clarity. Full text and the resolution note are in the review file.

**Not verified headlessly** — clicking the toggle in Settings and seeing the icon
appear/disappear. Flipping the key with `defaults write` from outside the process
does not propagate into the running app, so that check proved the app survives,
not that the live toggle works. The live path rests on code review plus the phase
worker's manual test.

## Decisions taken before phase 1

- **Settings is reachable two ways, both requested by the user**: a gear button
  in the HUD panel, and an *optional* menu bar icon (`NSStatusItem`) toggled from
  Settings. `⌘,` opens Settings as well — an `.accessory` app owns no menu bar,
  so the shortcut is handled by the panel/window key path rather than by a menu.
- **The menu bar icon defaults to off.** The app's stated design is menu-less
  (see `CLAUDE.md`), so the default preserves current behaviour; the toggle makes
  it opt-in. Flipping the default is a one-line change in `Preferences`.
- **Renaming happens in the Settings window**, as a list of displays and their
  Spaces with editable name fields. No inline rename in the HUD: the panel's job
  is to close fast, and an edit mode fights that.
- **Rename identity key: SkyLight's per-Space `uuid`.** Verified empirically on
  this machine (macOS 27.0) — `CGSCopyManagedDisplaySpaces` returns a `uuid` per
  Space that matches the one persisted in
  `~/Library/Preferences/com.apple.spaces.plist`, so it survives reboots, unlike
  `ManagedSpaceID`. **Caveat, also verified**: the primary display's first Space
  reports an *empty* `uuid`, so a positional fallback key
  (`displayID + index`) is required for that case. Space *ids* must still never
  be persisted.
- **Open at login: `SMAppService.mainApp`** (macOS 13+, matching the package's
  deployment target). No login-item helper bundle.

## Verification commands for this project

There is no test target and no linter configured. Verification is:

    swift build            # debug compile, fast
    ./build.sh             # release build + .app bundle + codesign

Runtime checks are manual (open the bundle, press the hotkey).

## Next action

Execute **phase 2**: the General tab gains a configurable hotkey and an open-at-login
toggle. Concretely:

1. Add a hotkey recorder control to `SettingsView.swift`'s General tab — a button
   that, once clicked, captures the next key-with-modifiers via a local event
   monitor and displays the combination.
2. Persist it in `Preferences` under the reserved keys
   `cc.carpio.spaceSwitcher.hotKeyCode` and `….hotKeyModifiers`, defaulting to the
   current Ctrl+Option+Space so an untouched install is unchanged.
3. Make `GlobalHotKey` re-registerable at runtime — it currently registers once in
   `init` and only unregisters in `deinit`. `SwitcherController` must swap the
   hotkey when the preference changes, without a relaunch.
4. Require at least one modifier, and surface `RegisterEventHotKey` failing with a
   non-`noErr` status (the combination is already taken) as a visible message
   rather than the current silent `NSLog`.
5. Add open-at-login with `SMAppService.mainApp` (`register()` / `unregister()`),
   reflecting `SMAppService.mainApp.status` rather than a stored boolean, since the
   user can revoke it in System Settings behind the app's back.

New strings go in **both** `.lproj/Localizable.strings` files.

Note for phase 2: `SMAppService` needs the app to be launched from a stable
location. Testing it from `build/spaceSwitcher.app` inside the repo may behave
differently from `/Applications`; if `status` looks wrong, check that first.

## Key paths

- `Sources/SpaceSwitcher/` — all Swift sources (SwiftUI views hosted in AppKit)
- `Sources/SpaceSwitcher/Preferences.swift` — add phase-2 keys here
- `Sources/SpaceSwitcher/SettingsView.swift` — the General tab to extend
- `Sources/SpaceSwitcher/GlobalHotKey.swift` — currently register-once; phase 2
  must make it re-registerable
- `Resources/en.lproj/Localizable.strings`, `Resources/es.lproj/Localizable.strings`
- `CLAUDE.md` — platform findings; read before touching the Spaces code
- `docs/reviews/` — Codex review transcripts, one file per phase

## Git state

- Phase 1 committed on `main`; see the commit log for the SHA. Push result and
  tree state are recorded with each phase above.
