# PROGRESS — Settings window

Implementation checkpoint for `todo.md`: *"Add a Settings window that allows
changing the keyboard shortcut, opening at login and renaming spaces."*

This file is the authoritative state. A fresh session should be able to resume
from it without any conversation history.

## Roadmap

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Preferences store, Settings window shell, entry points (gear, menu bar icon, ⌘,) | **done**, verified, committed |
| 2 | General tab: configurable hotkey + open at login | **done**, verified, committed |
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

## Phase 2 — completed

**What was built**

- `HotKeyCombination.swift` — the shortcut as one value (key code + Carbon
  modifier mask), its `⌃⌥␣` rendering, and the Cocoa→Carbon flag conversion.
  The key's character comes from the active layout via `UCKeyTranslate`, not from
  a hard-coded table, so `Z` on QWERTY and `W` on AZERTY — the same key code —
  print correctly.
- `GlobalHotKey.swift` — rewritten. `init()` only installs the Carbon handler;
  `register(_:)` / `unregister()` claim and release combinations at will. The
  static `instances` map now holds weak boxes (a strong entry kept every instance
  alive forever, so `deinit` — the only place the handler is removed — never ran),
  and `deinit` clears the slot only if no newer instance has taken the id.
- `HotKeyController.swift` — owns registration *policy*: validates, registers,
  and only then persists, so what is stored is always a shortcut that works. On a
  refusal it puts the previous one back and publishes a `Failure` the UI shows.
- `HotKeyRecorder.swift` — the recorder control. Click to capture, Escape to
  cancel; a local `.keyDown` monitor swallows everything while capturing.
- `LoginItemController.swift` — `SMAppService.mainApp`, status re-read rather
  than cached.
- `Preferences.swift` — `hotKey`, read defensively (see below).
- `SettingsView.swift` — three sections: shortcut, login, menu bar icon.

**Acceptance**

| Criterion | Met | Evidence |
| --- | --- | --- |
| `swift build` clean | yes | exit 0, full recompile after `touch`, zero warnings |
| `./build.sh` produces the bundle | yes | exit 0, Developer ID signed |
| en/es string keys identical | yes | key lists extracted and diffed, no difference; 41 keys each, 18 new (4 of them from the review fixes) |
| `.strings` files parse | yes | `plutil -lint` OK on both |
| Display formatting | yes | scratch binary over `HotKeyCombination`: `⌃⌥␣`, `⇧⌘A`, `⌃F5`, `⌥←`; bare `J` reports `hasModifier == false`; Caps Lock alone likewise |
| App launches and stays up | yes | bundle launched, alive, no log output, quit cleanly |

**Deviations and decisions**

- **The shortcut is one `@Published` value, not two.** A key code and a modifier
  mask published separately emit an intermediate combination nobody asked for,
  and whoever registers it would briefly claim it.
- **The preference follows the registration, never the reverse.** Nothing is
  written until Carbon has accepted the combination, so the store cannot hold a
  shortcut that does not work. That is also why `HotKeyController` does not
  subscribe to `Preferences` — it is the only writer, and subscribing would loop.
- **The shortcut is stood down while recording.** A registered hotkey is taken by
  the WindowServer before any key event reaches the app, so the one combination
  the user is most likely to re-record — the current one — would open the panel
  instead of being read.
- **Capture is ended from three directions**: the button, `onDisappear`, and
  `NSWindow.willClose` / `NSApplication.didResignActive`. A monitor left installed
  swallows every key press in the app with the shortcut off and no visible control
  to stop it, which would look exactly like the app having died.
- **Escape cancels only when pressed alone**, so `⌃⎋` can still be recorded.
- **The stored shortcut is validated on read.** The app is non-sandboxed and its
  defaults are plain text: a negative number would trap the `UInt32` conversion,
  and a modifier-less combination would claim a bare key machine-wide.
- **No `opensAtLogin` key.** The reserved name was dropped rather than used —
  `SMAppService` holds that state and a copy would go stale the moment the user
  revoked it in System Settings.
- **`.requiresApproval` reads as off**, with an explanation and a button into
  System Settings. Showing it as on would promise a launch that is not going to
  happen.
- Settings window grew to 500×440 (min 480×400) to fit three sections.
- README updated: the shortcut is now "the default", and the paragraph claiming
  the app has no menu bar item was left over from before phase 1.

**Codex review** — `docs/reviews/phase2-hotkey-and-login.md`

Eight findings, all addressed in the working tree:

1. *Launch can leave the app unreachable.* `start()` is now a ladder: the stored
   shortcut, then `.default` if that was refused, and if there is still nothing,
   `onUnreachable` forces the menu bar icon on **for the session only** — the
   preference is not rewritten. The store is not rewritten either: the user's
   combination stays so it can be claimed again next launch. The recorder now
   shows the *registered* combination rather than the stored one, so a fallback is
   visible rather than silently misreported, and the failure note names both.
2. *Replacement was not transactional.* Carbon hotkey ids are ours, so
   `GlobalHotKey` alternates between two: the candidate is registered under the
   spare id while the old `EventHotKeyRef` is still held, and the old one is
   released only once the candidate is in hand. `HotKeyController` no longer has a
   restore path — there is nothing to restore. The one gap that remains is
   recording, where the shortcut *must* be unregistered; `adopt(_:persisting:fallback:)`
   covers that case explicitly.
3. *Failed unregister lost the handle.* `unregister()` throws and keeps
   `hotKeyRef` when Carbon refuses.
4. *Handler install failure was ignored.* `InstallEventHandler`'s status is read;
   with no handler, `register(_:)` throws rather than claiming a combination
   nothing would dispatch.
5. + 6. *Monitor ownership.* The monitor and the recording transition moved into
   `HotKeyController`, so one recording session means exactly one monitor. The
   monitor is installed *before* the shortcut is stood down, and the whole thing
   is abandoned if either half fails.
7. *Stale login-item state.* Refreshed on `NSApplication.didBecomeActive` as well
   as `onAppear`, so returning from System Settings updates the toggle. `refresh()`
   only assigns on change, since it now runs on every activation.
8. *Dispatch checked the id but not the signature.* Both are checked.

**Platform finding from verifying #1 and #2** — `RegisterEventHotKey` does *not*
refuse a combination another process (or the system) already holds; the only
refusal reproducible here is `eventHotKeyExistsErr` for a duplicate within the
same process. The review's stated trigger for #1 and #2 therefore does not occur
on macOS 27. The fixes were kept anyway — they are cheap and the failure mode is
an app with no interface — but see `CLAUDE.md` before writing anything that reads
a refusal as "another app owns it".

**Not verified headlessly** — clicking through the recorder, seeing a taken
combination refused, and the login item round trip. All three need a real click in
a real window. The code paths rest on review plus the display-formatting probe.
Note that `SMAppService` judges by install location: run from
`build/spaceSwitcher.app` inside the repo, `status` may well be `.notFound`, which
the UI explains rather than treating as an error.

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

Phase 2 and its review fixes are in the working tree, uncommitted. Before phase 3:
run the app from `/Applications` and check by hand what could not be verified
headlessly — recording a shortcut, cancelling one with Escape, "restore default",
and the login item round trip including the return from System Settings. Note that
"a combination another app owns is refused" is *not* testable: Carbon does not
refuse those (see `CLAUDE.md`).

Then execute **phase 3**: per-Space renaming. Concretely:

1. Persist names under `cc.carpio.spaceSwitcher.spaceNames`, keyed by SkyLight's
   per-Space `uuid`, with the positional `displayID + index` fallback for the
   primary display's first Space, whose `uuid` comes back empty (both verified —
   see the decisions below).
2. Add a Spaces tab to `SettingsView`: displays and their Spaces, each with an
   editable name field.
3. Show the name in the HUD in place of "Desktop N", keeping the app list as the
   secondary line.

New strings go in **both** `.lproj/Localizable.strings` files.

## Key paths

- `Sources/SpaceSwitcher/` — all Swift sources (SwiftUI views hosted in AppKit)
- `Sources/SpaceSwitcher/Preferences.swift` — add the phase-3 key here
- `Sources/SpaceSwitcher/SettingsView.swift` — where the Spaces tab goes
- `Sources/SpaceSwitcher/SpaceModel.swift`, `SkyLightBridge.swift` — the Space
  enumeration phase 3 has to key its names off
- `Resources/en.lproj/Localizable.strings`, `Resources/es.lproj/Localizable.strings`
- `CLAUDE.md` — platform findings; read before touching the Spaces code
- `docs/reviews/` — Codex review transcripts, one file per phase

## Git state

- Phase 1: commit `c62bcf5` on `main`, pushed to `origin` successfully
  (`7be5f65..c62bcf5`). Checkpoint recorded in `8a546ae`.
- Phase 2: commit `1660547` on `main`, pushed to `origin` successfully
  (`8a546ae..1660547`), review fixes included. Tree clean apart from the user's
  own untracked icon files (`icon_prompts.md`, `*.png`) — **not part of this work,
  do not commit them**.
- Base before this work: `7be5f65`.
