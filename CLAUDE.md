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

### Getting the panel off screen before the jump

The panel joins every Space, so a panel still being composited when the transition
starts is drawn on the incoming Space too and rides through the animation in full
view. Closing it before jumping needs two things, and **`orderOut` alone is
neither**:

1. **`animationBehavior` must be `.none` for the removal.** `.utilityWindow` fades
   the window in *and* out, and `orderOut` only starts that fade. Measured over 15
   cycles on this machine: with the fade the window server still reports the panel
   on screen **201 ms (min) / 233 ms (median) / 454 ms (max)** after `orderOut`
   returns; with `.none`, **34 / 53 / 149 ms**. The flag is flipped for the one call
   and put straight back, so opening still fades in.
2. **Only the window server can say the removal has happened.**
   `NSWindow.isVisible` flips the instant `orderOut` is called and means nothing.
   The usable question is whether the window number is still in
   `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` — public API,
   no permission. A single-window `.optionIncludingWindow` query reading
   `kCGWindowIsOnscreen` agrees to within 1–2 ms and costs 0.24 ms against 0.78 ms,
   but depends on an optional key, so the list membership test is used.

**Poll from a background thread, never the main one.** Verified: a main-thread poll
loop after `orderOut` never sees the window leave — 731 and 825 consecutive polls
over 1.5 s, still on screen — because the ordering operation is applied when the
main run loop turns. Blocking the main thread waits for work the wait itself is
preventing. `CATransaction.flush()` does not help, nor does `NSApp.deactivate()`,
nor avoiding `NSApp.activate` in the first place; all three measure the same
~35–75 ms.

**What the code actually guarantees is weaker than "the panel is gone", and
deliberately so.** The wait is bounded (`HUDPanel.offScreenTimeout`, 1 s) and
expiry does **not** cancel the jump — the user asked to go somewhere, and a hotkey
that silently does nothing is a worse failure than a panel drawn over a transition.
So the guarantee is: *the jump starts only after the removal is confirmed, unless
confirmation could not be had within the bound, in which case it starts anyway and
says so.* `whenOffScreen` reports which of the two happened rather than just
calling back, and the expiry is logged with the wait and the target Space
(`grep "still on screen after"`). Verified end to end by rebuilding the app with
the bound cut to 1 ms: the log line appears with the wait and the target, and the
jump still lands — expiry is a safety valve, not a cancel.

The bound is sized against the worst removal ever observed here, **149 ms** (the
`.none` figure above); the latest 15-cycle run gives 29.5 / 39.8 / 98.3 ms
min/median/max. One second is therefore ~7× the worst case and ~10× a bad ordinary
one, which makes reaching it anomalous rather than merely unlikely. Do not tighten
it towards the medians: the run-to-run spread is nearly 5×, and the margin is what
makes the log line worth reading when it does appear.

### A window number does not identify the panel

`showPanel()` reuses the one `HUDPanel`, so a panel reopened while a removal wait
is still running **carries the very window number being watched**. The wait cannot
tell "not gone yet" from "gone and back", and must not try: it correctly reports
that the window is on screen.

Whether the completion is still *wanted* is therefore a question only the
controller can answer, and it answers it with object identity —
`SwitcherController.pendingJump`, one `Jump` per selection, holding the target
Space and the display snapshot it was resolved against. The two hops that come
back to the main actor — after the removal wait, and when the engine reports —
check `pendingJump === jump` and drop the work otherwise.

Reopening the panel and opening Settings both clear it. Choosing again does not
*clear* it: it **replaces** it with a different object, and that is what
invalidates the old one, because every comparison is against the object the jump
started with.

**This is not theoretical.** Measured with the panel-and-Space sampler against two
builds of these same sources differing only in the two `pendingJump === jump`
guards. Choose a Space, reopen the panel 15 ms later, then watch: without the
guards the target Space arrives **1.98 s after the reopen, with the panel back up
and visible** — the exact defect the phase exists to remove. With them, the target
Space never arrives at all and the log says why.

Note what that run also showed: the removal had been **confirmed** — the panel left
the screen 76 ms after the keystroke, some 350 ms before the reopened panel was
composited again — and the stale jump fired anyway, on top of the panel that was
back. The race is therefore not an artefact of the wait expiring, and no amount of
tightening the bound addresses it. Only the token does.

Two consequences worth stating separately:

- **Capture, do not re-read.** `model.displays` is replaced on every opening, so a
  completion that reads it resolves the target against a list the user never saw —
  a different ordering, or `spaceNotFound`.
- **But start the walk from live state.** The *ordering* comes from the snapshot;
  the Space the walk starts from is read fresh inside
  `SpaceSwitchEngine.switchTo`, after the cursor warp. Using the snapshot's
  `currentSpaceID` would measure the delta from where the display was rather than
  from where it is, which walks the wrong distance whenever anything moved in
  between — including an earlier jump of ours only just finishing.

### Identity stops the report; only a token stops the work

`pendingJump` is main-actor confined, and `switchTo` hands its work to the
engine's own serial queue. Between those two facts sits everything the walk
actually does — the cursor warp, and one `Ctrl`+arrow per step, each followed by
up to 2.5 s of waiting for the transition to settle. **That stretch cannot read
`pendingJump` at all**, so identity alone leaves the central defect in place: the
user reopens the panel, the token is dropped, and the keypresses go out anyway,
underneath the window they just opened.

So the `Jump` carries a second thing, `SpaceSwitchEngine.Cancellation` — a lock
guarded one-way flag, safe to read from any thread. `abandonPendingJump(because:)`
cancels it in the same breath as it clears `pendingJump`, so reopening the panel,
opening Settings and choosing again all reach it. The engine asks it **before the
cursor warp and before every keypress**, not once at the start: a walk several
Spaces long runs for seconds, and has to be able to stop partway.

**A stopped walk stays where it stopped.** The press already handed to System
Events cannot be recalled, so the walk halts on the next Space boundary, possibly
short of the target. Retracing is the tempting alternative and is wrong twice
over: the reason for stopping is that a window is now on screen, so every extra
transition *is* the panel-drawn-over-a-transition defect this phase exists to
remove — and walking back doubles them rather than avoiding them. Nor does it
strand the user: `present()` re-enumerates and re-selects on every opening, so the
panel they just opened lists the Spaces from wherever the walk stopped, with the
selection placed relative to it. One keystroke finishes the journey.

The check deliberately stops at the keypress boundary. `waitForSpaceChange` is
**not** cancellable: the press is already with System Events and the Space is
moving regardless, so returning early would report a Space the compositor is in
the middle of leaving — and that reading is exactly what the next jump measures
its distance from. The cost is that a cancelled walk holds the serial queue until
its last step settles, which is one animation, and which any following jump would
have waited for anyway.

**Measured, against two builds of these sources differing only in those two
checks.** The queue is serial, so a jump made while an earlier one is still
walking sits there having sent nothing — the report's exact state, and the way to
make that window hundreds of milliseconds wide instead of the microsecond it is on
an idle queue. Queue a second jump 100 ms behind the first, cancel it at 300 ms,
and watch the display: **with the checks it reports `cancelled` and the display
stays on the first jump's target; without them it reports 4.14 s later and the
display has been dragged back**, which is the stale transition running underneath
whatever the user has just opened.

The per-step check is measured the same way, on a walk of two steps cancelled
200 ms in — while the first transition was still settling. **With the checks the
walk stops after step one and reports at 0.64 s; without them it reports at
3.44 s**, the difference being one further keypress and the full 2.5 s
`arrivalTimeout` it then spends waiting for a transition that never comes. So the
check placed *inside* the loop is doing work: hoisting it to the top of `switchTo`
would leave that second press to go out.

Two things about staging this on a machine with only two Spaces per display, since
they will be needed again. `switchTo` takes the display list as a parameter, so a
list padded with Spaces that do not exist makes the engine walk further; every
press it then sends is real, and the ones that fall off the end of the real layout
are no-ops that each cost an `arrivalTimeout` — which is what makes the number of
presses legible in the elapsed time. And the harness must **take focus first**:
System Events delivers `key code … using control down` to the frontmost app, so
with the user's editor in front the Apple Event succeeds and the Space does not
move. A locked screen defeats it entirely — the login window owns the keyboard,
and every scenario then reports a failure that says nothing about the code.

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
