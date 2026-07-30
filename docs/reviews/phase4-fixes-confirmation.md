## Original findings

1. **Timeout abandons the off-screen guarantee — partially closed.**

   The bound is now 1 second, `.timedOut` is explicit, and the timeout is logged with elapsed time and the captured target before proceeding ([HUDPanel.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/HUDPanel.swift:142), [SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:359)). That materially improves observability and practical margin.

   However, the fundamental behavior remains: after expiry the jump starts even though the matching window is still on screen. Therefore the original visible-transition defect remains possible on that exceptional path. The documentation now accurately admits this weaker guarantee.

2. **Reopening the reused panel permits a stale jump — partially closed.**

   The original removal-wait race is closed. Each `choose` creates a new `Jump`, captures both the target and display snapshot, and checks identity after `whenOffScreen` returns ([SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:342)). `showPanel()` and `openSettings()` invalidate that object ([SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:161), [SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:234)). Reopening during the removal poll can no longer launch the old jump.

   The stale-snapshot portion is also closed: `jump.displays` is passed to the engine, while the starting Space is deliberately read live after the cursor warp ([SpaceSwitchEngine.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpaceSwitchEngine.swift:155)).

   It is not fully closed because there is a later unguarded asynchronous boundary, detailed below.

3. **A stale failure reopens the HUD — closed.**

   Every engine completion reaches the second identity check before `pendingJump` is cleared or `report(_:)` is called ([SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:364)). All `SpaceSwitchEngine` completion paths dispatch to the main queue. Once the user reopens the panel or opens Settings, an old failure is logged and discarded; it cannot reach `reopenWithFailureNotice()`.

## New finding

**High — the token is not checked after `switchTo` queues its background operation.**

[SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:364) checks the token immediately before calling `switchTo`, but [SpaceSwitchEngine.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpaceSwitchEngine.swift:137) then queues the actual switching work without any cancellation/current-operation check.

Trigger:

1. The off-screen callback passes its identity check.
2. `switchTo` queues work.
3. Before that queued block sends its first keypress—or while a multi-step walk is running—the user reopens the HUD or opens Settings.
4. `pendingJump` is cleared, but the engine still sends the Space keypresses.

Consequently, a stale transition can still begin or continue underneath the newly opened panel or Settings window. The final identity check only suppresses its completion/report; it cannot prevent the already queued operation. Cross-display switching widens the pre-keypress window because `focusDisplayIfNeeded` sleeps for 50 ms.

This also makes CLAUDE.md’s statement that “Every hop checks `pendingJump === jump`” inaccurate ([CLAUDE.md](/Users/ccarpio/Developer/spaceSwitcher/CLAUDE.md:160)). The engine-queue hop does not check. “Choosing again … clear[s] it” is imprecise too: another choice replaces the token with a different object, which correctly invalidates the old one.

## Specific confirmations

- Reference identity itself is sound. Every choice allocates a fresh `Jump`; old closures retain their object while comparing it, so allocator address reuse cannot defeat `===`.
- `pendingJump` is main-actor confined. `SwitcherController` is `@MainActor`; the removal poll runs in the background but invokes its callback on the main queue, and every engine completion also returns on the main queue.
- Clearing before the first guard does not strand the user: reopening visibly presents the HUD, and opening Settings visibly presents Settings. Cancellation at that stage is intentional.
- `.timedOut` logging is reachable. If the token remains current, it logs the measured wait and `jump.space.id`, then calls the engine using `jump.space` and `jump.displays`, so the selected state remains correctly captured.

**Verdict:** not ready to commit. The stale-report and removal-poll races are fixed, but the unguarded engine-queue hop still permits the central stale-jump behavior after reopening.

Codex session ID: 019fb4e2-7e2c-7140-bcbd-1e9b61a8d01e
Resume in Codex: codex resume 019fb4e2-7e2c-7140-bcbd-1e9b61a8d01e
