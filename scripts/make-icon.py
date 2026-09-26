"""
Original app icon for Live Subtitles.

A dark "screen" (squircle) carrying a white caption card with two text lines and
a speech tail, plus a coral dot for "live". Drawn from scratch with Pillow - no
third-party artwork is reused.

Rendered at 3x then downsampled, so edges stay clean at 16-32 px.
"""
from PIL import Image, ImageDraw, ImageFilter

SS = 3
SIZE = 1024
S = SIZE * SS

TOP    = (34, 43, 58)      # #222B3A  screen, top
BOTTOM = (10, 15, 24)      # #0A0F18  screen, bottom
CARD   = (255, 255, 255)
INK    = (22, 29, 43)      # #161D2B  caption lines
ACCENT = (255, 118, 103)   # #FF7667  live dot


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(box, radius, size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- screen: squircle with a vertical gradient -----------------------------
grad = Image.new("RGB", (1, S))
for y in range(S):
    grad.putpixel((0, y), lerp(TOP, BOTTOM, y / (S - 1)))
grad = grad.resize((S, S))

INSET, RADIUS = 100 * SS, 185 * SS
squircle = rounded_mask([INSET, INSET, S - INSET, S - INSET], RADIUS, S)
canvas.paste(grad, (0, 0), squircle)

# Soft top-edge light instead of a hard ring: a white wash that fades out.
wash = Image.new("L", (S, S), 0)
wd = ImageDraw.Draw(wash)
for y in range(INSET, INSET + 300 * SS):
    t = 1 - (y - INSET) / (300 * SS)
    wd.line([(0, y), (S, y)], fill=int(46 * t * t))
highlight = Image.new("RGBA", (S, S), (255, 255, 255, 255))
canvas = Image.alpha_composite(
    canvas,
    Image.composite(highlight, Image.new("RGBA", (S, S), (0, 0, 0, 0)),
                    Image.composite(wash, Image.new("L", (S, S), 0), squircle))
)

d = ImageDraw.Draw(canvas)

# --- caption card with a speech tail --------------------------------------
cx = S // 2
card_w, card_h = 512 * SS, 296 * SS
card_l = cx - card_w // 2
card_t = 348 * SS
card_r, card_b = card_l + card_w, card_t + card_h
d.rounded_rectangle([card_l, card_t, card_r, card_b], radius=64 * SS, fill=CARD)
d.polygon([
    (card_l + 100 * SS, card_b - 8 * SS),
    (card_l + 76 * SS, card_b + 72 * SS),
    (card_l + 198 * SS, card_b - 8 * SS),
], fill=CARD)

# --- two caption lines ----------------------------------------------------
bar_h = 58 * SS
bar_r = bar_h // 2
line1_y = card_t + 72 * SS
line2_y = line1_y + bar_h + 42 * SS
d.rounded_rectangle([card_l + 74 * SS, line1_y, card_l + 416 * SS, line1_y + bar_h],
                    radius=bar_r, fill=INK)
d.rounded_rectangle([card_l + 74 * SS, line2_y, card_l + 262 * SS, line2_y + bar_h],
                    radius=bar_r, fill=INK)

# --- live dot, with a tight glow ------------------------------------------
gcx, gcy = S - 262 * SS, 262 * SS
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([gcx - 86 * SS, gcy - 86 * SS, gcx + 86 * SS, gcy + 86 * SS],
                             fill=ACCENT + (105,))
canvas = Image.alpha_composite(canvas, glow.filter(ImageFilter.GaussianBlur(28 * SS)))

d = ImageDraw.Draw(canvas)
dr = 43 * SS
d.ellipse([gcx - dr, gcy - dr, gcx + dr, gcy + dr], fill=ACCENT)

canvas.resize((SIZE, SIZE), Image.LANCZOS).save("/tmp/iconbuild/icon_1024.png")

# Legibility check strip: how it reads at real dock/Finder sizes.
strip = Image.new("RGBA", (16 + 32 + 64 + 128 + 256 + 5 * 24, 256), (245, 245, 247, 255))
x = 12
for size in (16, 32, 64, 128, 256):
    im = canvas.resize((size, size), Image.LANCZOS)
    strip.alpha_composite(im, (x, (256 - size) // 2))
    x += size + 24
strip.save("/tmp/iconbuild/icon_sizes.png")
print("wrote icon_1024.png + icon_sizes.png")
