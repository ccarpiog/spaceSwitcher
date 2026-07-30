# Icon prompts

How the two icons were produced. The app icon came from an image model; the menu
bar icon did not, and the reason is worth recording before anyone tries again.

| Icon | Master | Built by |
| --- | --- | --- |
| App | `Resources/AppIcon-1024.png` | `./scripts/make-app-icon.sh` → `spaceSwitcher.icns` |
| Menu bar | `Resources/MenuBarIcon.svg` | `python3 scripts/make-menubar-icon.py` → `MenuBarIcon.png`, `@2x` |

Both share one idea, so the pair reads as one app: three staggered cards with
the front one singled out as the destination of the jump.

---

## 1. App icon — generated from this prompt

Used as-is, and the result passed: 838 × 842 artwork inside the 1024 canvas
(≈9% margins, matching Apple's grid) with fully transparent corners, so the
squircle is a real shape rather than painted onto a square.

```
Create a macOS application icon, 1024 x 1024 pixels, PNG with a transparent
background.

The app is called spaceSwitcher. It is a small macOS utility that shows every
Mission Control Space (virtual desktop) and jumps to the one you pick.

Shape: the icon must already be drawn as the macOS rounded square (a squircle:
a superellipse, noticeably rounder and softer than a plain rounded rectangle).
Leave the outer ~10% of the canvas empty on every side, so the squircle occupies
roughly the central 820 x 820 pixels and nothing touches the edge of the image.
Everything outside the squircle is fully transparent.

Background of the squircle: a smooth vertical gradient from a deep indigo-violet
at the top to a warmer magenta-pink at the bottom, in the register of Apple's own
system icons — saturated but not neon, and completely even, with no visible
banding or texture.

Foreground: three overlapping rounded rectangles, drawn as if they were desktop
screens seen straight on, no perspective and no 3D tilt. Arrange them as a
staggered stack going from the lower left to the upper right, so all three read
as separate cards with a clear gap between them. The two rear cards are flat
translucent white, around 35% opacity, with no outline. The front card, at the
upper right and drawn on top, is solid opaque white with a soft drop shadow, and
is very slightly larger than the other two: it is the Space you jump to, and it
should read instantly as the chosen one.

Keep the interior simple. No text, no letters, no numbers, no app logos, no
window controls, no dots, no traffic lights inside the cards, no arrows, no
cursor. The whole icon must survive being scaled down to 32 x 32 pixels and still
read as "three screens, one selected", so use bold shapes, generous spacing and
strong contrast between the front card and the two behind it.

Style: flat and modern, in the vein of a macOS Sequoia or Tahoe system icon.
Soft ambient shadow only, no bevels, no glossy highlights, no skeuomorphic
glass, no reflections, no noise, no border around the squircle, no mockup,
no presentation background, no drop shadow underneath the icon itself.
```

To replace it: drop a new 1024 × 1024 master at `Resources/AppIcon-1024.png` and
run `./scripts/make-app-icon.sh`.

---

## 2. Menu bar icon — not generated from a prompt

Two rounds of prompting failed on the same point, so this one is drawn from
geometry in `scripts/make-menubar-icon.py`, which emits the SVG master and both
PNGs from one set of constants.

**Why prompting kept failing.** A status item is scaled by its **canvas height**,
not by the artwork inside it. Both attempts centred a short glyph in a 512 × 512
square, which macOS then shrinks wholesale:

| | glyph bounding box | share of canvas height | rendered at 18 pt |
| --- | --- | --- | --- |
| v1 | 364 × 118 | 23% | ~4 pt tall |
| v2 | 388 × 220 | 43% | ~8 pt tall |

An SF Symbol fills roughly 15–16 pt of the 18. Asking for "12% padding" does not
survive a model that defaults to a square canvas, and a square canvas is fatal
here no matter how good the drawing is.

**The second failure was geometric, not stylistic.** Three cards in a row cannot
be narrower than about 3:1, which at the menu bar's fixed 18 pt height comes out
around **75 pt wide** — as wide as the clock. Staggering the cards instead, the
way the app icon already does, expresses the same idea at **1.42:1, about 26 pt**,
and makes the two icons match. That is a constraint no prompt wording fixes.

**Why a script rather than a hand-written SVG.** No SVG rasteriser is installed
(`rsvg-convert`, `cairosvg`, ImageMagick, Inkscape are all absent), so a `.svg`
alone could not have become the PNGs macOS needs. The script draws the raster
directly — supersampled 16× and downsampled, so the edges are clean — and writes
the matching SVG from the same constants, which keeps vector and raster from
drifting. Installing librsvg would also work; it just is not required.

To change the shape, edit the constants at the top of
`scripts/make-menubar-icon.py` and re-run it. Anything emitted must stay **pure
black on transparency**: that is the template-image contract macOS relies on to
invert the glyph for dark menu bars, and grey or colour breaks it. Both outputs
were checked and contain exactly one non-transparent colour, `#000000`, with all
antialiasing in the alpha channel.
