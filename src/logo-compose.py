#!/usr/bin/env python3
"""Compose the FluxBilling console background in the fluxbilling.app style.

Usage: logo-compose.py <icon.png> <out.png>

Canvas 800x600 black (matches the iPXE framebuffer console; the white/gray
menu text draws on top from the top-left down). A fluxbilling.app-style app
"window title bar" sits in a footer band - three traffic-light dots, the
brand icon, the wordmark, and a one-line tagline - so the boot screen reads
like the product's own native-app chrome. The top two-thirds stay clear for
the prompts and the OS menu.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

ICON, OUT = sys.argv[1], sys.argv[2]
W, H = 800, 600
ICON_SIZE = 56
WORDMARK = "FluxBilling.app"
TAGLINE = "The hosting platform that bills, provisions, and tracks the rack"

# Debian/builder image fonts (DejaVu ships with fonts-dejavu-core).
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Palette mirrors the site: near-black ink inverts to white on a dark console;
# the #A3A3A3 grays stay gray; the traffic-light dots are the exact brand hexes.
# Dim watermark palette. iPXE draws the picture as a FIXED background and the
# setup prompts scroll on top of it, so the logo must stay much darker than the
# bright terminal text or it turns the input to mush. These greys read as a
# subtle brand watermark that white/cyan text stays legible over.
INK = (74, 74, 74)      # wordmark  (dim)
GRAY = (56, 56, 56)      # tagline   (dimmer)


def load_font(path, size, fallback=FONT_BOLD):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.truetype(fallback, size)


canvas = Image.new("RGB", (W, H), (0, 0, 0))
draw = ImageDraw.Draw(canvas)
icon = Image.open(ICON).convert("RGBA").resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
# Dim the icon to match the watermark so bright terminal text reads over it.
_r, _g, _b, _a = icon.split()
icon = Image.merge("RGBA", (_r, _g, _b, _a.point(lambda p: int(p * 0.38))))

wm_font = load_font(FONT_BOLD, 34)
tag_font = load_font(FONT_REG, 18)

# --- geometry: one centered row [icon] [wordmark], tagline under it ----
# band_cy sits in the lower third: below where the setup prompts reach (~y=400)
# but high enough that the tagline (~band_cy+58) clears the 600px bottom edge.
# No hairline rule - it used to collide with the live prompt row.
band_cy = 500                      # vertical center of the icon + wordmark row
label_gap = 18                     # icon -> wordmark

wm_w = int(draw.textlength(WORDMARK, font=wm_font))
row_w = ICON_SIZE + label_gap + wm_w
x = (W - row_w) // 2

# brand icon, centered on the row
icon_x = x
canvas.paste(icon, (icon_x, band_cy - ICON_SIZE // 2), icon)

# wordmark, optically centered against the icon
ascent, descent = wm_font.getmetrics()
draw.text((icon_x + ICON_SIZE + label_gap, band_cy - (ascent + descent) // 2),
          WORDMARK, font=wm_font, fill=INK)

# tagline, centered under the whole row
tag_w = draw.textlength(TAGLINE, font=tag_font)
draw.text(((W - tag_w) // 2, band_cy + ICON_SIZE // 2 + 8), TAGLINE, font=tag_font, fill=GRAY)

canvas.save(OUT, "PNG")
print(f"wrote {OUT} ({W}x{H}, title-bar band at y={band_cy})")
