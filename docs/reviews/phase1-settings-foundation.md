> **Orchestrator note on how these were resolved.**
> - Finding 1 is a **false positive**. `swift build` and `./build.sh` both exited 0
>   on the exact tree reviewed, before and after: Darwin's `Foundation` re-exports
>   `Combine`, so `ObservableObject` resolves. The explicit `import Combine` was
>   added anyway, as clarity about a real dependency rather than a compile fix.
> - Finding 2 **accepted and fixed**: `Preferences` is now `@MainActor`. That made
>   the `MainActor.assumeIsolated` in `MenuBarController.start()` sound rather than
>   merely lucky. It also surfaced two new warnings — a default argument is
>   evaluated in a nonisolated context and so cannot read a main-actor `static let`
>   — fixed by dropping the `= .shared` default and passing the store explicitly.
> - Finding 3 **accepted and fixed**: `.capsLock` is now masked out, via a shared
>   `commandOnly` helper covering both `⌘,` and `⌘W`.
>
> Verified after the fixes: full recompile with zero warnings, `./build.sh` exit 0,
> and a launch smoke test with the icon preference on.

---

Found three issues, ranked by severity:

1. **High — project will not compile:** `Preferences.swift:1,10,38`  
   `ObservableObject` and `@Published` come from Combine, but this file imports only Foundation. Imports in `MenuBarController.swift` do not carry across files. Add `import Combine`.

2. **Medium — status-bar updates are not guaranteed to run on the main actor:** `MenuBarController.swift:37-39`  
   `@Published` delivers on the thread that changes the property. `MainActor.assumeIsolated` asserts isolation; it does not switch executors. Because `Preferences` is not main-actor-isolated, an off-main assignment could trip an actor precondition or touch `NSStatusBar` off-main. Isolate `Preferences` to `@MainActor`, or explicitly deliver/hop to the main actor before calling `setVisible`.

3. **Low — Cmd+comma and Cmd+W fail while Caps Lock is enabled:** `SettingsWindow.swift:82,90`  
   `.deviceIndependentFlagsMask` includes `.capsLock`, so comparing the result exactly with `.command` rejects those shortcuts despite the comment at lines 86-88. Remove `.capsLock` before comparing modifiers.

Otherwise, the reviewed lifecycle and event handling are sound: the Settings window is strongly retained and reusable, activation occurs before making it key, status-item callbacks avoid retain cycles, the HUD monitor is removed before Settings opens, Settings keystrokes are not swallowed, and the existing arrows/Return/Escape/q behavior remains intact.

Codex session ID: 019fb372-65b6-7312-a0c5-7464d25dae35
Resume in Codex: codex resume 019fb372-65b6-7312-a0c5-7464d25dae35
