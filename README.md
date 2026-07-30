# spaceSwitcher

A small macOS utility that lists your Mission Control Spaces and jumps to one.

Press **⌃⌥Space** and a panel appears listing every Space, labelled with the apps
on it. Pick one with the arrow keys, a number key, or the mouse.

```
╔══════════════════════════════════════╗
║ Built-in Display                     ║
║  1  Desktop 1          current       ║
║     Code · Chrome · Outlook          ║
║ ▶2  Desktop 2                        ║
║     Code                             ║
║ Studio Display                       ║
║  3  Desktop 3          empty         ║
╚══════════════════════════════════════╝
   ↑↓ select   ⏎ jump   esc close   q quit
```

macOS gives desktops no names, so listing the apps on each one is what makes the
panel usable — otherwise it would just read "Desktop 1, 2, 3". Fullscreen Spaces
are named after the app filling them.

You can also name desktops yourself, in settings, and the panel shows your name
in place of "Desktop 2" while keeping the app list underneath it. Names are tied
to the Space itself rather than to its position, so they survive a restart. The
one exception is your main display's first desktop, which macOS gives no identity
of its own: its name is remembered by position, so removing that desktop passes
the name on to whichever one takes its place. Fullscreen Spaces cannot be renamed:
they are built afresh every time an app goes fullscreen, so a name given to one
would quietly stop applying.

## Install

```bash
./build.sh
open build/spaceSwitcher.app
```

The app has no dock icon — the hotkey is the whole interface. Press **q** in the
panel to quit it, or turn on the optional menu bar icon in settings, which is
where Quit also lives.

Settings open from the gear button in the panel, from the menu bar icon, or with
`⌘,`. They hold the global shortcut, whether the app opens at login, whether the
menu bar icon is shown, and the names of your Spaces.

For a signed, notarized build suitable for copying to another Mac:

```bash
./scripts/release.sh
```

## Permissions

On the first jump macOS will ask for permission to control **System Events**.
Allow it — that is the mechanism the app uses to switch Spaces (see below).

Listing Spaces needs no permission at all, so the panel always opens and always
shows the full list. A permission warning, if one appears, sits *above* the list
rather than replacing it — the Spaces stay visible and selectable, because
selecting one is what triggers the permission prompt in the first place.

## Keys

| Key | Action |
| --- | --- |
| `⌃⌥Space` | open or close the panel (the default; change it in settings) |
| `↑` `↓` | move the highlight |
| `1`–`9` | jump straight to that Space |
| `⏎` | jump to the highlighted Space |
| `esc` | close without jumping |
| `q` | quit the app |

Opening the panel preselects the **next** Space rather than the one you are on,
so pressing `⏎` straight away jumps somewhere — the same convention the app
switcher follows. The Space you are currently on is marked `current`.

The panel can also be opened from a script, Shortcuts, Alfred or Raycast:

```bash
notifyutil -p cc.carpio.spaceSwitcher.toggle
```

## Languages

English and Spanish, following the system language. Adding another is a matter of
copying `Resources/en.lproj/Localizable.strings` to a new `<lang>.lproj`
directory and translating it — `build.sh` bundles every `.lproj` it finds, and no
code changes are needed.

## Icons

| | Master | Rebuild with |
| --- | --- | --- |
| App icon | `Resources/AppIcon-1024.png` | `./scripts/make-app-icon.sh` |
| Menu bar icon | `Resources/MenuBarIcon.svg` | `python3 scripts/make-menubar-icon.py` |

The `.icns` is a build product and is not committed: `build.sh` rebuilds it
whenever the 1024 × 1024 master is newer, so replacing the artwork is enough.
The menu bar PNGs *are* committed, because regenerating those needs Pillow and
building the app should not.

The menu bar icon is a **template image** — pure black on transparency, which is
what lets macOS invert it for light and dark menu bars. It is drawn from the
geometry constants at the top of `scripts/make-menubar-icon.py` rather than
hand-drawn, so the SVG master and both PNGs cannot drift apart. Anything that
replaces it must keep the black-on-transparency contract; grey or colour breaks
the inversion and the icon disappears against one of the two menu bars.

## How it works, and why it works that way

There is no public API for Spaces. Everything here rests on empirical testing
against macOS 27, because most of the obvious approaches fail — several of them
*silently*, which is worse. The full findings are in [CLAUDE.md](CLAUDE.md); the
short version:

**Reading** the Spaces layout uses the private SkyLight framework
(`CGSCopyManagedDisplaySpaces` and friends), resolved with `dlsym` because the
framework exists only inside the dyld shared cache. This needs no permission and
no SIP change.

**Jumping** is the awkward part:

- `CGSManagedDisplaySetCurrentSpace`, the private call that looks like the right
  answer, updates WindowServer's bookkeeping without driving the compositor. The
  result is the target Space's windows being drawn onto the Space still on
  screen. It also makes `CGSGetActiveSpace` report success, so it is easy to
  believe it worked. **Not used.**
- Synthesised `CGEvent` key presses never reach the WindowServer hotkey matcher —
  tested with every event source and with explicit modifier key events, with
  Accessibility granted. A silent no-op. **Not used.**
- Asking **System Events** to press `⌃←`/`⌃→` performs a real, animated,
  reliable transition. **This is what the app does.** Navigation is relative, so
  the app computes how many steps away the target is from SkyLight's ordering,
  steps that far, and confirms arrival by polling `CGSGetActiveSpace`.

Because this depends on private API, a future macOS can break it. Symbols are
resolved defensively: if they disappear, the panel says so instead of
misbehaving.

## Caveats

- Space ids are not stable across reboots or when Spaces are added and removed,
  so nothing is persisted — the list is rebuilt every time the panel opens.
- Relative navigation means a distant Space takes several animated steps. With
  the handful of Spaces most setups have, this is not noticeable. macOS's own
  "switch to desktop N" shortcuts, which would allow a single jump, are disabled
  by default and would have to be enabled by hand in System Settings.
- On a multi-display setup with "Displays have separate Spaces" enabled, jumping
  to a Space on another display warps the mouse cursor there first, because
  relative navigation applies to whichever display has focus.
- Not sandboxed, so it can never be distributed on the Mac App Store.

## License

MIT — see [LICENSE](LICENSE).
