## Findings

1. **High — Launch can leave this UI-less app permanently unreachable.**  
   `HotKeyController.swift:93-102`

   If the persisted shortcut has since been claimed by another app, `start()` records a failure but leaves no hotkey registered. Because the app is `.accessory`, has no Dock icon, and the menu-bar item defaults off, the user has no normal way to open Settings and see or repair that failure. `⌘,` only works after one of the app’s windows is already active.

   On launch failure, try a known fallback such as `.default` when it differs, or temporarily expose a recovery UI/status item. The failure should record the fallback as `kept`.

2. **High — Shortcut replacement is not transactional and can lose the previous shortcut.**  
   `GlobalHotKey.swift:66-83`, `HotKeyController.swift:109-126`

   `register(_:)` unregisters the working shortcut before attempting the new one. If the new combination is refused, restoring the old combination is another independent Carbon registration that can also fail—for example, another process can claim it during that gap. The controller then correctly reports `kept: nil`, but the stated guarantee that refusal leaves the previous shortcut running is not actually provided.

   Carbon hotkey IDs are caller-defined. A safer design is to register the candidate under a second ID while retaining the old `EventHotKeyRef`, then unregister the old registration only after the candidate succeeds.

3. **High — A failed unregister loses the only reference to a potentially live registration.**  
   `GlobalHotKey.swift:91-94`

   `UnregisterEventHotKey` returns an `OSStatus`, but its result is ignored and `hotKeyRef` is cleared unconditionally. If unregistering fails, Carbon may still own the old registration while the app has discarded the only handle capable of releasing it. The subsequent registration may fail, and future calls cannot retry cleanup.

   Runtime replacement should treat unregister failure as an error and retain the reference. The same issue exists conceptually in `deinit`, although recovery there is necessarily limited.

4. **Medium — Failure to install the Carbon event handler is silently treated as success.**  
   `GlobalHotKey.swift:97-125`

   The result from `InstallEventHandler` is ignored. `RegisterEventHotKey` can subsequently succeed, causing the controller to persist and display a “working” shortcut even though no handler dispatches it. Installation failure should prevent registration or be surfaced from initialization/startup.

5. **Medium — Failure to create the local event monitor strands recording mode with no hotkey.**  
   `HotKeyRecorder.swift:69-79`, `HotKeyRecorder.swift:101-107`

   `NSEvent.addLocalMonitorForEvents` returns an optional token. The code first calls `beginRecording()`, which unregisters the hotkey, and then assigns that optional token. If monitor creation returns `nil`, `stopCapturing()` becomes a no-op because of its `monitor != nil` guard, while `hotKeys.isRecording` remains true and the global shortcut remains unregistered.

   Install and validate the monitor before standing down the hotkey, or explicitly call `endRecording(with: nil)` when installation fails.

6. **Medium — Monitor ownership is only per SwiftUI view identity, not process-wide.**  
   `HotKeyRecorder.swift:16-21`, `HotKeyRecorder.swift:64-79`, `HotKeyRecorder.swift:101-113`

   A recreated or temporarily overlapping `HotKeyRecorder` receives a separate `@State monitor`. If one instance is already recording, a second instance’s `beginRecording()` returns early, but that second instance still installs another monitor. Teardown of the first instance can then restore the hotkey while the second monitor continues swallowing key events.

   The event-monitor token and recording transition should share one owner—preferably the controller or a reference-type recorder coordinator—so “one recording session” also means exactly one monitor.

7. **Low — Login-item state stays stale after approval in System Settings.**  
   `LoginItemController.swift:66-70`, `SettingsView.swift:92-94`, `SettingsWindow.swift:45-48`

   Status is refreshed when the Settings view appears or `show()` is called. If the user follows the provided System Settings button, approves the item, and returns to the still-open Settings window, neither path runs again. The toggle can continue showing off/`requiresApproval` until Settings is closed and reopened. Refresh on application activation or window focus restoration.

8. **Low — Carbon dispatch checks the ID but not the signature.**  
   `GlobalHotKey.swift:105-118`

   The callback extracts `EventHotKeyID` but routes solely using `hotKeyID.id`. Any other Carbon hotkey registered in this process with ID `1` but a different signature could trigger this controller. Validate both signature and ID.

## Confirmed correct

- The weak-box change does break the former strong-reference cycle: the Carbon callback itself does not capture the instance, and queued callbacks retain it long enough to avoid use-after-free.
- `EventHotKeyRef` ownership is otherwise correct: successful registrations are retained and released with `UnregisterEventHotKey`; no separate `CFRelease` is appropriate.
- Re-registering the same combination should work after a successful unregister, although the unnecessary release/reclaim window remains.
- Removing an instance’s own `EventHandlerRef` does not remove another instance’s separately installed handler. The fixed shared map slot still makes multiple simultaneous instances route incorrectly, but production currently uses one singleton.
- Escape, recorder-button cancellation, ordinary window close, app resignation, and normal `onDisappear` all remove an existing monitor and restore the stored shortcut.
- `SMAppService.Status` is handled exhaustively through the explicit special cases plus `default`; `.requiresApproval` is not incorrectly presented as enabled.
- Register/unregister errors are surfaced, and status is re-read after both successful and failed mutations.
- The examined main-actor usage is coherent in Swift 5 mode for the current construction paths. `GlobalHotKey` does not itself enforce main-thread access, but all production access shown is through the main-actor controller.
- No Phase 3 renaming defect is reported, and I found no contradiction with `CLAUDE.md`.

Codex session ID: 019fb398-ad3e-7e31-bde9-974cea990800
Resume in Codex: codex resume 019fb398-ad3e-7e31-bde9-974cea990800
