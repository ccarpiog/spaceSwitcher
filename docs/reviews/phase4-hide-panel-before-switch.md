## Findings

1. **High — the timeout explicitly abandons the required guarantee.**  
   [HUDPanel.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/HUDPanel.swift:116) breaks out after 250 ms and invokes the jump callback even while the matching window remains on screen. If compositor removal takes longer than 250 ms, the Apple Event starts while the panel is still composited, restoring the original visible-transition bug. The measured 149 ms maximum gives margin on the tested runs, but the code provides no guarantee that a healthy WindowServer under load cannot exceed it. That possibility is a hypothesis; the definite problem is the behavior once it does exceed it. This also contradicts CLAUDE.md’s statement that removal “has to be confirmed.”

2. **High — reopening the reused panel invalidates an in-flight removal check.**  
   [SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:89) permits the global hotkey to reopen the panel immediately after `dismiss`, while [HUDPanel.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/HUDPanel.swift:117) identifies only its window number. Because `showPanel()` reuses the same `HUDPanel`, the reopened window has the number being polled. The old poll then times out and sends the old jump while the panel is visibly open. If the user makes another selection, two jumps can also be queued. Moreover, the first callback combines its captured old `row.space` with mutable, potentially re-enumerated `self.model.displays` at [SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:281), which can produce `spaceNotFound` or calculate relative navigation from a different snapshot.

3. **Medium — a stale failure can reopen the HUD after the user has moved on.**  
   [SwitcherController.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SwitcherController.swift:315) unconditionally calls `reopenWithFailureNotice()` for non-permission failures. If the user reopens and dismisses the panel, or opens Settings while the switch remains queued/running, the earlier operation’s eventual failure calls `present()` and takes focus back with the HUD. There is no operation generation or pending-jump state to discard stale completions.

## Checks that are fine

- `.canJoinAllSpaces` remains intact at [HUDPanel.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/HUDPanel.swift:58).
- The jump does not perform a permission pre-check. It classifies the error returned by `sendControlKey` at [SpaceSwitchEngine.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpaceSwitchEngine.swift:177). The existing status query only controls the warning shown when presenting the panel.
- Normal multi-display handling remains unchanged: the cursor warp and target display’s `currentSpaceID` are still used. Only the stale-snapshot race above compromises it.
- Fade suppression and restoration are synchronous, non-throwing, and called through the main-actor controller. A second main-thread dismissal cannot interleave between those assignments.
- The Core Graphics results are ARC-managed, and the integer window-number comparison is correct. The retained panel makes ordinary number reuse unlikely; reopening the same numbered panel is the concrete identity problem.
- The callback captures the controller weakly, so there is no retain cycle or use-after-free. AppKit/UI work returns to main.
- `error.jumpFailed` is localized in both English and Spanish, sentence case, and accessed through `NSLocalizedString`.
- The two new empirical findings in `CLAUDE.md` match the implemented fade suppression and background WindowServer polling, apart from the timeout weakening its claimed confirmation guarantee.

**Verdict:** not ready to commit. The timeout behavior and reopen race can both reproduce the exact panel-during-transition defect this phase is meant to eliminate.

Codex session ID: 019fb43c-30a8-7bc1-b9e6-0013c1679dd6
Resume in Codex: codex resume 019fb43c-30a8-7bc1-b9e6-0013c1679dd6
