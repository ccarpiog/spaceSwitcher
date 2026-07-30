## Findings

1. **High — positional fallback can apply an orphaned name to the wrong Space.**  
   [SpaceModel.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpaceModel.swift:106) derives every empty or missing UUID as `position:<displayID>#<index>`. If the named UUID-less Space is removed, or another Space takes its position, the surviving positional entry is applied to the replacement Space. Likewise, if a previously UUID-bearing Space later reports no UUID, it can inherit an older positional entry at that index while its UUID-keyed name becomes orphaned. The `position:` prefix prevents namespace collisions, but not positional reassignment.

2. **Medium — hostile string values can produce malformed HUD layout.**  
   [Preferences.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/Preferences.swift:149) accepts every nonblank string without rejecting embedded newlines/control characters or imposing a practical length limit. [HUDView.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/HUDView.swift:226) renders the name without a line limit. A manually stored value such as `"Work\nInjected row"` therefore becomes a multiline title and increases the fixed-width HUD’s height; an extremely long multiline value can make the panel unusable. The reader does safely reject wrong container/value types and does not contain an evident trapping conversion.

3. **Medium — Settings rows use the explicitly unstable Space ID as SwiftUI identity.**  
   [SpacesSettingsView.swift](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpacesSettingsView.swift:83) uses `ForEach(display.spaces)`, whose identity is [Space.id](/Users/ccarpio/Developer/spaceSwitcher/Sources/SpaceSwitcher/SpaceModel.swift:22). When Spaces are added or removed while a text field remains focused across application deactivation, macOS may reassign those IDs before the activation refresh. If an ID is reused for another Space, SwiftUI considers it the same row while its binding key has changed, so continued editing can target the replacement Space. A stable UUID/name-key-based row identity is needed to avoid that reuse.

## Fine

- No numeric Space ID is persisted.
- UUID and positional key namespaces do not collide for valid SkyLight UUIDs.
- Fullscreen Spaces are neither editable nor given stored overrides.
- Blank values are consistently judged through `normalisedName`; storage remains verbatim while HUD display is trimmed.
- The main-actor annotations cover preference publication and refresh mutations; no re-entrant write or publish loop is evident.
- Ordinary refreshes do not overwrite edits because text bindings read directly from `Preferences`.
- All new user-facing strings are localized in both English and Spanish and use sentence case.
- No changed code contradicts the switching and per-display findings in `CLAUDE.md`.

**Verdict:** not ready to commit because an orphaned positional entry can silently rename the wrong Space. The unstable SwiftUI row identity should also be resolved before commit.

Codex session ID: 019fb3e3-7e73-7ba2-9e09-a59dea522c80
Resume in Codex: codex resume 019fb3e3-7e73-7ba2-9e09-a59dea522c80
