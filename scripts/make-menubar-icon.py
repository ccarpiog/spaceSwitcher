#!/usr/bin/env python3
"""
Generates the menu bar template icon from a single geometry definition.

The glyph is three staggered, overlapping cards with the front one filled — the
monochrome echo of the app icon, so the two read as one app.

Both the SVG master and the PNGs are emitted from the constants below, so
editing the shape means editing one place and re-running this script; the
vector and the raster can never drift apart.

Why not three cards in a row: three side-by-side cards are unavoidably wider
than 3:1, which at the menu bar's fixed 18 pt height comes out around 75 pt
wide — as wide as the clock. Staggering them keeps the same idea at 1.4:1.

Output is a *template* image: pure black on transparency, which is the contract
that lets macOS recolour it for light and dark menu bars. Nothing here may emit
colour or grey; antialiasing must live in the alpha channel alone.

Usage:  python3 scripts/make-menubar-icon.py
Needs:  Pillow  (pip install Pillow)
"""

import os
from PIL import Image, ImageDraw

# --- Geometry, in abstract units; everything scales from these -------------
CARD_W, CARD_H = 26.0, 18.0   # a single card, landscape like the app icon's
RADIUS = 4.0                  # corner radius
STROKE = 3.2                  # outline weight, uniform across the glyph
STAGGER_X, STAGGER_Y = 9.0, 6.0   # offset between consecutive cards
KNOCKOUT = 2.4                # transparent gap punched behind each card

WIDTH = 2 * STAGGER_X + CARD_W + STROKE
HEIGHT = 2 * STAGGER_Y + CARD_H + STROKE

SUPERSAMPLE = 16              # draw large, downsample: clean edges without a
                              # vector rasteriser being installed

# 1x and 2x for an 18 pt status item. macOS does not use 3x on the Mac.
#
# The @2x file must be *exactly* double the @1x one in both axes. Rounding each
# size independently from the aspect ratio does not guarantee that — 18 pt tall
# rounds to 26 px wide while 36 pt tall rounds to 51, and 51 is not 2 x 26. Cocoa
# then takes its logical size from the @2x representation, so the image measures
# 25.5 pt rather than 26 and one of the two representations is resampled every
# time it is drawn. Deriving both from a single base size avoids that.
BASE_HEIGHT = 18
PNG_SCALES = [("MenuBarIcon.png", 1), ("MenuBarIcon@2x.png", 2)]

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(REPO, "Resources")


def card_origins():
    """Positions of the three cards, back to front: up and to the right.

    - Returns: a list of (x, y) top-left corners in geometry units.
    """
    pad = STROKE / 2
    return [(pad + i * STAGGER_X, pad + (2 - i) * STAGGER_Y) for i in range(3)]


def render_mask():
    """Paints the glyph's alpha channel at supersampled resolution.

    Cards are drawn back to front. Before each card is stroked, a slightly
    larger rounded rectangle is erased from what is already there, which is what
    keeps the card behind from touching it — in a template image that erased
    band is transparent, so it reads as a gap against any menu bar colour.

    - Returns: a PIL "L" image holding the finished alpha channel.
    """
    mask = Image.new("L", (round(WIDTH * SUPERSAMPLE), round(HEIGHT * SUPERSAMPLE)), 0)
    draw = ImageDraw.Draw(mask)

    for index, (x, y) in enumerate(card_origins()):
        knock = [(x - KNOCKOUT), (y - KNOCKOUT),
                 (x + CARD_W + KNOCKOUT), (y + CARD_H + KNOCKOUT)]
        draw.rounded_rectangle([v * SUPERSAMPLE for v in knock],
                               radius=(RADIUS + KNOCKOUT) * SUPERSAMPLE, fill=0)

        card = [x * SUPERSAMPLE, y * SUPERSAMPLE,
                (x + CARD_W) * SUPERSAMPLE, (y + CARD_H) * SUPERSAMPLE]
        if index == 2:
            draw.rounded_rectangle(card, radius=RADIUS * SUPERSAMPLE, fill=255)
        else:
            draw.rounded_rectangle(card, radius=RADIUS * SUPERSAMPLE,
                                   outline=255, width=round(STROKE * SUPERSAMPLE))
    return mask
# End of render_mask()


def write_png(mask, filename, scale):
    """Downsamples the mask to one output size and writes it as black + alpha.

    - Parameter mask: the supersampled alpha channel from render_mask().
    - Parameter filename: name to write inside Resources/.
    - Parameter scale: 1 for the @1x file, 2 for @2x. Both axes are multiplied by
      it, so the pair stays an exact power-of-two match.
    """
    width_px = round(mask.width / mask.height * BASE_HEIGHT) * scale
    height_px = BASE_HEIGHT * scale
    alpha = mask.resize((width_px, height_px), Image.LANCZOS)
    image = Image.new("RGBA", alpha.size, (0, 0, 0, 255))
    image.putalpha(alpha)
    path = os.path.join(RESOURCES, filename)
    image.save(path)
    print("  %-22s %d x %d" % (filename, width_px, height_px))


def write_svg(filename):
    """Writes the editable vector master, using the same constants as the PNGs.

    The knockout cannot be expressed by stacking shapes, because a template
    image has no background colour to hide behind — the gap has to be genuinely
    transparent. So the whole glyph is painted through a mask in which black
    erases and white draws, replaying the same back-to-front order as the
    raster path.

    - Parameter filename: name to write inside Resources/.
    """
    body = []
    for index, (x, y) in enumerate(card_origins()):
        body.append(
            '      <rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="black"/>'
            % (x - KNOCKOUT, y - KNOCKOUT, CARD_W + 2 * KNOCKOUT,
               CARD_H + 2 * KNOCKOUT, RADIUS + KNOCKOUT))
        if index == 2:
            body.append(
                '      <rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="white"/>'
                % (x, y, CARD_W, CARD_H, RADIUS))
        else:
            body.append(
                '      <rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f"'
                ' fill="none" stroke="white" stroke-width="%.2f"/>'
                % (x, y, CARD_W, CARD_H, RADIUS, STROKE))
    # End of the loop building one mask entry per card

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %.2f %.2f"\n'
        '     width="%.2f" height="%.2f">\n'
        '  <!-- spaceSwitcher menu bar template icon. Generated by\n'
        '       scripts/make-menubar-icon.py - edit the constants there, not this file. -->\n'
        '  <defs>\n'
        '    <mask id="glyph">\n'
        '%s\n'
        '    </mask>\n'
        '  </defs>\n'
        '  <rect width="%.2f" height="%.2f" fill="black" mask="url(#glyph)"/>\n'
        '</svg>\n'
        % (WIDTH, HEIGHT, WIDTH, HEIGHT, "\n".join(body), WIDTH, HEIGHT))

    path = os.path.join(RESOURCES, filename)
    with open(path, "w") as handle:
        handle.write(svg)
    print("  %-22s %.2f x %.2f units" % (filename, WIDTH, HEIGHT))
# End of write_svg()


def main():
    """Emits the SVG master and every PNG size into Resources/."""
    print("Menu bar icon: aspect %.2f:1 (%.0f pt wide at an 18 pt status item)"
          % (WIDTH / HEIGHT, 18 * WIDTH / HEIGHT))
    mask = render_mask()
    write_svg("MenuBarIcon.svg")
    for filename, scale in PNG_SCALES:
        write_png(mask, filename, scale)


if __name__ == "__main__":
    main()
