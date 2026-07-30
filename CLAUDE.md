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

## Distribution

The app must be **non-sandboxed** (private framework + Apple Events). It can
therefore never ship on the Mac App Store. It is built as a proper `.app` bundle
by `./build.sh`.
