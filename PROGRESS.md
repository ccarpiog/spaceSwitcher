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
| 3 | Space renaming (persistent identity + Settings list + HUD display) | **done**, verified, committed |
| 4 | Hide the panel before the Space switch begins | **done**, verified, committed |

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

## Phase 3 — completed

**What was built**

- `SpaceModel.swift` — `Space` gained `uuid`, `customName`, `nameKey`,
  `rowIdentity`, `isRenameable`, and a `generatedTitle` split out of `title`, so
  the generated "Desktop N" / fullscreen labelling is untouched and a rename is a
  pure override. `SpaceEnumerator.enumerate(customNames:)` resolves the name at
  enumeration time, which is why the HUD needed no change to display it.
- `Preferences.swift` — `cc.carpio.spaceSwitcher.spaceNames`, a
  `[String: String]` of name key → name, behind `setSpaceName(_:for:)` /
  `spaceName(for:)` with a defensive reader. `private(set)` with a mutator rather
  than an open dictionary, so a blank name cannot be written as an empty string.
- `SpacesSettingsView.swift` — the Spaces tab: displays, their Spaces, a "current"
  badge, the app list as a subtitle, and a name field bound straight to the store.
  Re-enumerates on `onAppear`, on `didBecomeActive`, and from
  `SettingsWindowController.show()`.
- `NSScreenAdapter.primaryDisplayUUID()` — needed to identify the one display
  whose first Space has no uuid.

**Acceptance**

| Criterion | Met | Evidence |
| --- | --- | --- |
| `swift build` clean | yes | exit 0, zero warnings, forced full recompile after `touch`; also from a wiped `.build` |
| `./build.sh` produces the bundle | yes | exit 0, Developer ID signed, `codesign --verify --strict` valid |
| en/es string keys identical | yes | key lists extracted and diffed, no difference; **47 keys each**, 6 new |
| `.strings` files parse | yes | `plutil -lint` OK on both |
| Name persists and reaches the HUD | yes | typed in the real signed bundle, stored under the Space uuid, shown in the panel; emptying the field removed the entry outright |
| Hostile defaults do not trap | yes | scratch probe over non-string, array, wrong-typed, empty-key, newline and 300-char values |
| App launches and quits cleanly | yes | bundle launched, alive, terminated cleanly, no crash report |

**The identity decision, as actually implemented**

The rename key is SkyLight's per-Space `uuid`. **Verified again on this machine
during this phase**: `CGMainDisplayID()` is 3, UUID `D5CE04A8-…`, matching
SkyLight's `"Display Identifier"`; that display's Space[0] is the *only* Space
reporting `uuid == ""`, while the second display's Space[0] carries a real uuid.
So the empty-uuid caveat is about the **primary display specifically**, not "the
first Space of each display" — an earlier phrasing of it was wrong.

A positional key `position:<displayID>#<index>` is therefore derived **only** when
the uuid is empty *and* the display is primary *and* the index is 0. Any other
uuid-less Space gets `nameKey == nil`: listed, but not renameable. That narrowing
is what closes review finding 1 (below). Space *ids* are persisted nowhere.

**Accepted residual risk, documented at the derivation site:** removing the primary
display's first Space passes its name to whichever Space takes that position. It is
inherent to positional keying. It is *not* solved by garbage-collecting entries
that match no live Space — a display merely unplugged would take its Spaces' names
with it.

**Deviations and decisions**

- **Fullscreen Spaces are not renameable.** They are rebuilt with a new uuid every
  time an app re-enters fullscreen, so a name would silently stop applying and
  orphan its entry; macOS already labels them by app. They still appear in the
  list, with an explanation where the field would be.
- **Names are stored verbatim, not trimmed.** Trimming on the way in swallows a
  trailing space the instant it is typed, which makes a two-word name impossible to
  enter. Blankness is judged on a trimmed copy; readers normalise.
- **Names are sanitised, which is not the same as trimmed.** Control characters and
  newlines each collapse to one space (ZWJ spared, so emoji sequences survive) and
  the result is truncated grapheme-safely at `Space.maximumNameLength` (60).
  Applied on write *and* on read, since the store must be assumed already dirty.
- **Row identity is not `Space.id`.** For renameable rows `rowIdentity` *is* the
  `nameKey`, so identity and storage key cannot diverge; keyless rows fall back to
  `unkeyed:<display>#<index>`, a namespace that cannot collide with a uuid or a
  `position:` key.
- A UI defect found during visual verification and fixed: inside a `Form`,
  `TextField(_:text:)`'s title renders as a label *beside* the field, so every row
  showed a stray second "Desktop 1". Now `prompt:` + `labelsHidden()`.

**Codex review** — `docs/reviews/phase3-space-renaming.md`

Three findings, all accepted and fixed in the working tree:

1. *High — the positional fallback could rename the wrong Space.* It was applied to
   every uuid-less Space at any index, so an orphaned entry could be inherited by a
   different Space, and a uuid-bearing Space that lost its uuid could pick up a
   stale positional entry at its index. Fixed by narrowing the fallback to the one
   empirically verified case, as described above.
2. *Medium — hostile or oversized names broke the HUD.* `"Work\nInjected row"`
   became a multiline title and a long value could make the panel unusable. Fixed
   by the sanitising described above plus `.lineLimit(1)` and `.truncationMode(.tail)`
   on the HUD title. Worth noting this was never only a hostile-defaults concern:
   a user can type an absurdly long name into the field themselves.
3. *Medium — SwiftUI row identity used the unstable `Space.id`.* An id reused for a
   different Space while a field was focused could send continued editing to the
   wrong Space. Fixed by `rowIdentity`.

Codex also confirmed as fine: no numeric Space id persisted, uuid and positional
namespaces do not collide, blank handling consistent through `normalisedName`,
main-actor annotations sound with no publish loop, refreshes do not overwrite edits
(the text bindings read straight from `Preferences`), and localisation complete.

**Not verified headlessly** — that a stable row id keeps a focused field on its own
row while the list re-enumerates underneath it, and the HUD's visual truncation.
Both need a real focused field in a real window and rest on code review.

## Phase 4 — completed

The user's ask, added to `todo.md` after phase 3: *"make sure that the program
window disappears before we switch to the new space."* The panel used to ride
through the transition animation with the desktop.

**What was built**

- `HUDPanel.hideNow()` — suppresses the `.utilityWindow` fade for the removal only
  (restored immediately, so opening still fades in) and returns the window number.
- `HUDPanel.whenOffScreen(windowNumber:then:)` — polls
  `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` on a `.userInteractive`
  background queue until the window server stops listing the panel, then calls back
  on main with `.confirmed` or `.timedOut`. The guarantee is the window server's own
  on-screen list — not `orderOut` returning, and not `isVisible`.
- `SwitcherController.pendingJump` — a `Jump` **reference** type holding the target
  Space, the display snapshot from selection time, and a cancellation flag. Every
  asynchronous hop guards on `pendingJump === jump`.
- `SpaceSwitchEngine.Cancellation` — a lock-guarded one-way flag, safe to read off
  the main actor, checked inside the engine's own queue before the cursor warp and
  again **before every keypress** in a walk.

**Acceptance**

| Criterion | Met | Evidence |
| --- | --- | --- |
| `swift build` clean | yes | exit 0, zero warnings, forced full recompile, debug and release |
| `./build.sh` produces the bundle | yes | exit 0, Developer ID signed, `codesign --verify --deep --strict` passes |
| en/es string keys identical | yes | extracted and diffed, no difference; **48 keys each**, 1 new (`error.jumpFailed`) |
| `.strings` files parse | yes | `plutil -lint` OK on both |
| Panel gone before the transition | yes | see numbers below |
| Stale jump discarded | yes | negative control reproduced the defect without the guards |
| App launches and quits cleanly | yes | bundle launched, alive, quit cleanly, no crash report |

**The measurements** — sampled in one process, off the main thread, panel visibility
and the target display's current Space together, per `CLAUDE.md`'s testing rule that
a single reading after the fact is misleading:

- Panel gone **55.1 ms** after the keystroke; Space changed at **1118.5 ms** — the
  panel left ~1063 ms before the transition.
- Removal latency over 15 cycles through the jump's own path: **29.5 / 39.8 /
  98.3 ms** min/median/max.
- **Before this phase**, 6–67 samples per run showed the panel still composited at
  or after the Apple Event went out (last at 162–276 ms). **After**, 0 such samples
  in 4 of 4 runs.
- A **main-thread** poll never observes the removal at all — 731 and 825
  consecutive polls over 1.5 s still saw the window. This is why the wait is
  off-main, and it is not an optimisation.

**Deviations and decisions**

- **The 1 s bound proceeds on expiry rather than cancelling.** A visible panel
  during the transition is cosmetic; a hotkey that silently does nothing is a
  functional failure. 1 s is ~7× the worst removal ever measured here (149 ms).
  Expiry is not silent — it logs the wait and the target. `CLAUDE.md` was corrected
  to state this weaker guarantee rather than claim removal "has to be confirmed".
- **A cancelled mid-walk stays where it stopped, and does not retrace.** The reason
  for stopping is that a window is now on screen, so every extra transition *is*
  the defect this phase removes, and walking back doubles them. The check sits
  before a keypress, after the previous step settled, so the display is always left
  on a real Space, never mid-animation. `present()` re-enumerates on every opening,
  so the panel lists Spaces from wherever the walk stopped — one keystroke finishes
  the journey.
- **`waitForSpaceChange` is deliberately not cancellable.** Bailing early would
  report a Space the compositor is leaving, which is exactly the reading the next
  jump measures its distance from.
- **The starting Space is still read live after the cursor warp**, not taken from
  the captured snapshot. Only the display *list* is captured.
- **Failure handling changed because the panel now goes first.** Non-permission
  failures were `NSLog`-only, which would have left the user with no panel, no Space
  change and no explanation. They now reopen the panel with an `error.jumpFailed`
  notice. `.automationDenied` keeps its existing alert with the System Settings
  button. `.cancelled` reports silently.

**Codex reviews** — `docs/reviews/phase4-hide-panel-before-switch.md` and
`docs/reviews/phase4-fixes-confirmation.md`

First review: three findings. (1) *High* — the reopened panel reuses the same window
number, so an in-flight poll matched the **new** window, timed out, and fired the
**old** jump while the panel was visibly open. (2) *High* — the 250 ms bound
abandoned the guarantee. (3) *Medium* — a stale failure could reopen the HUD after
the user had moved on. Fixed with the `Jump` token, the raised bound, and the token
covering the report path.

Confirmation pass: findings 1 and 3 closed, 2 partially (by design — see above),
plus **one new High**: the token was checked before `switchTo` but the engine then
queued its work with no cancellation check, so a stale transition could still begin,
or continue mid-walk, underneath a newly opened panel or Settings window. Closed by
`Cancellation`, checked before every keypress.

**The negative control that proves it** — two harness bundles built from the app's
own sources, differing *only* in the guard blocks:

- *Queued jump*: with the fix, `cancelled`, display stays on Space 5. Without it,
  `didNotArrive` 4.14 s later and **the display dragged back to Space 1** — the
  stale transition running under the newly opened window.
- *Mid-walk*: a two-step walk cancelled 200 ms in stops after step 1 and reports at
  **0.64 s**; the control reports at **3.44 s**, the extra press plus its full
  2.5 s arrival timeout.

**Two testing gotchas found, now recorded in `CLAUDE.md`** — a harness must take
focus first, because System Events delivers the key to the frontmost app (the
user's editor was eating `Ctrl+arrow`); and a locked screen makes every scenario
fail for reasons unrelated to the code.

**Not verified headlessly** — the `.automationDenied` alert branch (Automation
permission was not revoked to test it), and the `spaceNotFound` / `didNotArrive`
reopen paths, which were not forced.

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

**Everything in `todo.md` is implemented, verified and committed.** There is no
phase 5 planned. A fresh session has nothing queued: ask the user what they want
next rather than inventing work.

What remains is **manual acceptance by a human at the keyboard**. None of it blocks
anything; all of it is listed because it could not be verified headlessly. Run
`build/spaceSwitcher.app` (or install it) and check:

- **Phase 2** — record a shortcut; cancel one with Escape; "restore default"; the
  login item round trip including returning from System Settings. Note that
  "a combination another app owns is refused" is *not* testable: Carbon does not
  refuse those (see `CLAUDE.md`).
- **Phase 3** — keep focus in a Space name field while the list re-enumerates
  (switch away to another app and back); confirm the edit stays on its own row.
  Also confirm a very long name truncates in the HUD rather than reshaping it.
- **Phase 4** — the actual point of the phase: press the hotkey, choose a Space,
  and confirm the panel is gone before the animation starts. Then reopen the panel
  immediately after choosing and confirm no stale jump fires.
- **Not tested anywhere** — the `.automationDenied` alert (Automation permission was
  never revoked to force it), and the `spaceNotFound` / `didNotArrive` reopen paths.

If anything new is picked up, note that new strings go in **both**
`.lproj/Localizable.strings` files, and that `CLAUDE.md` is the record of what has
been verified empirically on this machine — read it before touching the Spaces or
switching code.

## Key paths

- `Sources/SpaceSwitcher/` — all Swift sources (SwiftUI views hosted in AppKit)
- `Sources/SpaceSwitcher/SpaceSwitchEngine.swift`, `SwitcherController.swift`,
  `HUDPanel.swift` — where phase 4 has to hide the panel before the jump
- `Sources/SpaceSwitcher/Preferences.swift` — the `spaceNames` store
- `Sources/SpaceSwitcher/SettingsView.swift`, `SpacesSettingsView.swift` — Settings
- `Sources/SpaceSwitcher/SpaceModel.swift`, `SkyLightBridge.swift` — the Space
  enumeration and the name-key derivation
- `Resources/en.lproj/Localizable.strings`, `Resources/es.lproj/Localizable.strings`
- `CLAUDE.md` — platform findings; read before touching the Spaces code
- `docs/reviews/` — Codex review transcripts, one file per phase

## Git state

- Phase 1: commit `c62bcf5` on `main`, pushed to `origin` successfully
  (`7be5f65..c62bcf5`). Checkpoint recorded in `8a546ae`.
- Phase 2: commit `1660547` on `main`, pushed to `origin` successfully
  (`8a546ae..1660547`), review fixes included. Checkpoint recorded in `dd94564`.
- App and menu bar icons: commit `c74de0a`, pushed (`dd94564..c74de0a`).
- Phase 3: commit `99a5fe8` on `main`, pushed to `origin` successfully
  (`c74de0a..99a5fe8`), review fixes included in the same commit.
- Base before this work: `7be5f65`.

- Phase 4: commit `3866f37` on `main`, pushed to `origin` successfully
  (`c82ba48..3866f37`). Both review rounds' fixes included, along with `todo.md`
  (the user's phase-4 line) and the two review transcripts. Tree clean.
