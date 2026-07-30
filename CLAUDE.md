# spaceSwitcher

A small macOS menu-less utility: a global hotkey opens a HUD panel listing the
current Mission Control Spaces (labelled by the apps on them) and lets you jump
to one.

## Conventions

- **User-facing text: English and Spanish**, with the structure in place to add
  more languages later. All strings go through `NSLocalizedString` with keys in
  `Resources/<lang>.lproj/Localizable.strings`. Adding a language = adding one
  `.lproj` directory; no code changes.
- All code, comments, documentation and README content in English.
- Sentence case in user-facing strings, never TitleCase.
- Doc comments on every function; a `// End of ...` comment closing any
  function or loop longer than ~10 lines.

## Platform findings (verified empirically on macOS 27.0, build 26A5388g)

There is **no public API** for Spaces. What follows was tested on this machine,
not assumed — several plausible approaches fail silently, so do not "simplify"
the implementation into one of them.

### Reading Spaces — private SkyLight framework, works freely

`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` is **shared-cache
only** — the binary does not exist on disk, so you cannot link against it. Resolve
symbols with `dlopen` + `dlsym`. Both `CGS*` and `SLS*` prefixes are exported.

| Symbol | Use |
| --- | --- |
| `CGSMainConnectionID` | connection id for all other calls |
| `CGSCopyManagedDisplaySpaces` | per-display ordered Space list |
| `CGSGetActiveSpace` | current Space id |
| `CGSCopySpacesForWindows` | which Spaces a window occupies |

Requires **no permission and no SIP change**. `type: 0` is a normal desktop,
`type: 4` a fullscreen-app Space.

Space ids are **not stable** across reboots or when Spaces are added/removed.
Never persist them; re-enumerate every time the panel opens.

### Switching Spaces — the part where the obvious approaches fail

Three approaches were tested. Only the third works.

1. **`CGSManagedDisplaySetCurrentSpace` — DO NOT USE.** It updates WindowServer's
   bookkeeping (so `CGSGetActiveSpace` dutifully reports the new Space and the
   call *looks* successful) but does not drive the compositor. The observed result
   is the target Space's windows being drawn onto the Space still displayed.
   Recovering needs a real Dock-driven switch. **`CGSGetActiveSpace` returning the
   target value is not proof of a switch** — that false positive is exactly what
   this API produces.
2. **Synthesised `CGEvent` key presses — do not work.** `Ctrl+←`/`Ctrl+→` posted
   via `CGEvent.post(tap: .cghidEventTap)` never reach the WindowServer hotkey
   matcher, with Accessibility granted and with every event source tried
   (`.hidSystemState`, `.combinedSessionState`, `.privateState`, `nil`), and with
   both `.flags`-only and explicit modifier key-down/key-up sequences. Silent
   no-op, not an error.
3. **System Events (Apple Events) — works.** `tell application "System Events" to
   key code 124 using control down` performs a genuine, animated, stable
   transition. Verified by time-series sampling: the Space changes at ~0.75 s (the
   animation) and holds. Needs **Automation permission** for System Events.

The hotkeys this relies on, `Ctrl+←`/`Ctrl+→` ("move left/right a space",
symbolic hotkey ids 79/80), are **enabled by default**. The direct-jump shortcuts
"Switch to Desktop N" (ids 118–121) are **absent from
`com.apple.symbolichotkeys` by default, i.e. disabled** — so direct jumping is
not available unless the user enables it. Hence relative navigation.

### Automation permission cannot be reduced to a boolean

`AEDeterminePermissionToAutomateTarget` has three outcomes that matter, and
treating "not `noErr`" as "denied" produces a false warning on a perfectly
healthy system:

| Code | Meaning | Correct handling |
| --- | --- | --- |
| `noErr` | granted | jump freely |
| `-1743` `errAEEventNotPermitted` | **actually refused** | the only case worth warning about |
| `-1744` | consent not yet requested | stay quiet; the prompt appears on the first jump |
| `-600` `procNotFound` | **System Events is not running** | stay quiet; says nothing about permission |

`-600` is the common case, not an edge case: System Events is a faceless
background app that is usually not running, and merely querying it does not
launch it. Sending the Apple Event does.

Consequently the jump path **must not pre-check permission**. Sending the event
is itself the check — it launches System Events and raises the TCC prompt at a
moment the user understands. A pre-check reports a bogus refusal whenever System
Events simply happened to be idle. Classify the *error returned by the event*,
not a speculative query made beforehand.

### UI rule that follows from the above

A permission warning must never replace the Space list. An earlier version showed
the warning *instead of* the list, which deadlocked the panel: it told the user
to choose a Space in order to trigger the permission prompt, while hiding every
Space they could choose. Only an unreadable Spaces layout justifies blanking the
list.

### Testing gotcha

macOS pulls the active Space back to wherever the frontmost app's window lives.
A test run from a terminal sitting on Desktop 1 will appear to snap back the
moment the test process exits. Sample the Space **over time inside one process**;
a single reading after the fact is misleading. The app's own panel avoids this by
joining all Spaces (`.canJoinAllSpaces`).

### Multi-display

With "Displays have separate Spaces" on, each display has an independent Space
list and relative navigation applies to the display that currently has focus.
To target another display, the cursor is warped there first
(`CGWarpMouseCursorPosition`).

**Every display has its own current Space**, reported per display as
`"Current Space"` in `CGSCopyManagedDisplaySpaces`. This is *not* the same as the
globally active Space from `CGSGetActiveSpace` — only one display holds that.
Relative navigation must be computed from the target display's own current Space:
using the global one looks up a Space that is not in that display's list at all,
so every jump to a non-focused display aborts silently. The same applies to
verifying arrival afterwards.

### Do not preselect the active Space

The panel highlights the Space *after* the active one. Highlighting the active
Space makes the most natural gesture — open the panel, press Return — close the
panel and change nothing, which reads as a broken jump rather than as the no-op
it is.

### Registering the global hotkey — what Carbon actually refuses

`RegisterEventHotKey` is far more permissive than it looks, verified on this
machine with a scratch binary and a second process holding the combination:

| Situation | Result |
| --- | --- |
| Another **process** already registered the same combination | **succeeds** (`noErr`) |
| The **system** owns it (tried `⌘Space`, Spotlight) | **succeeds** (`noErr`) |
| The **same process** registers it twice, any hotkey id | fails, `eventHotKeyExistsErr` (-9878) |
| A second `GlobalHotKey` in the process installs its handler | fails, `eventHandlerAlreadyInstalledErr` — the callback is a non-capturing closure, so both instances pass Carbon the same function pointer for the same target |

So "another app owns the shortcut" does **not** produce a registration failure.
Do not write code — or user-facing text — that assumes a refusal means the
combination is taken; the refusal you can actually trigger is our own duplicate.
The app still handles refusal defensively, because there is no interface left
when the one shortcut fails, but it is a rare path, not the common one.

Two consequences for the code:

- `register(_:)` short-circuits when the combination asked for is already the one
  registered. It has to: the replacement is claimed *before* the old one is
  released, so without the short-circuit re-registering the current combination
  would hit -9878.
- Exactly one `GlobalHotKey` may exist per process, which is why it lives inside
  the `HotKeyController` singleton.

## Distribution

The app must be **non-sandboxed** (private framework + Apple Events). It can
therefore never ship on the Mac App Store. It is built as a proper `.app` bundle
by `./build.sh`.
