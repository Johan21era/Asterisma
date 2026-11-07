#!/usr/bin/env python3
"""Generate the interim AsterismaV2.5 app icon.

A quiet night-sky field, an open book, a gold bookmark, and a small
constellation. Drawn at 4x and downsampled for clean macOS icon edges.
Replace with final artwork later; this clears the packaging blocker.
"""
from __future__ import annotations

import math
import os
from PIL import Image, ImageDraw, ImageFilter

MASTER = 1024
SS = 4  # supersample
S = MASTER * SS
OUT = os.path.join(os.path.dirname(__file__), "..", "AsterismaV2.5",
                   "Assets.xcassets", "AppIcon.appiconset")


def lerp(a, b, t):
    return int(a + (b - a) * t)


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def radial_gradient(size, inner, outer):
    img = Image.new("RGB", (size, size), outer)
    d = ImageDraw.Draw(img)
    cx = cy = size / 2
    maxr = math.hypot(cx, cy)
    # coarse rings, then blur for a smooth glow
    steps = 220
    for i in range(steps, 0, -1):
        t = i / steps
        r = maxr * t
        c = tuple(lerp(inner[j], outer[j], t) for j in range(3))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
    return img.filter(ImageFilter.GaussianBlur(size * 0.012))


def star(d, x, y, r, color):
    d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    # subtle four-point sparkle
    d.line([(x - r * 2.2, y), (x + r * 2.2, y)], fill=color, width=max(1, int(r * 0.7)))
    d.line([(x, y - r * 2.2), (x, y + r * 2.2)], fill=color, width=max(1, int(r * 0.7)))


def main():
    os.makedirs(OUT, exist_ok=True)
    img = radial_gradient(S, (28, 43, 78), (7, 12, 28)).convert("RGBA")
    d = ImageDraw.Draw(img, "RGBA")

    # clipped to a macOS-style rounded square
    mask = rounded_mask(S, int(S * 0.225))
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    base.paste(img, (0, 0), mask)

    d = ImageDraw.Draw(base, "RGBA")
    # star field
    rng = __import__("random").Random(17)
    for _ in range(95):
        x = rng.uniform(S * 0.08, S * 0.92)
        y = rng.uniform(S * 0.08, S * 0.72)
        r = rng.uniform(S * 0.0012, S * 0.0038)
        alpha = rng.randint(90, 210)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(220, 232, 255, alpha))

    # a small constellation over the book
    pts = [(S * 0.30, S * 0.27), (S * 0.40, S * 0.20), (S * 0.50, S * 0.25),
           (S * 0.60, S * 0.18), (S * 0.69, S * 0.27)]
    for a, b in zip(pts, pts[1:]):
        d.line([a, b], fill=(180, 205, 255, 95), width=max(1, int(S * 0.0022)))
    for (x, y) in pts:
        star(d, x, y, S * 0.0075, (245, 249, 255, 235))

    # book pages: two soft cream quadrilaterals meeting at the spine
    cream = (246, 238, 218, 255)
    cream_shadow = (212, 200, 176, 255)
    left = [(S * 0.20, S * 0.58), (S * 0.49, S * 0.52),
            (S * 0.49, S * 0.82), (S * 0.20, S * 0.87)]
    right = [(S * 0.80, S * 0.58), (S * 0.51, S * 0.52),
             (S * 0.51, S * 0.82), (S * 0.80, S * 0.87)]
    d.polygon(left, fill=cream_shadow)
    d.polygon(right, fill=cream_shadow)
    # inset page faces
    def inset(poly, dx, dy):
        cx = sum(p[0] for p in poly) / 4
        cy = sum(p[1] for p in poly) / 4
        return [(p[0] + (cx - p[0]) * dx, p[1] + (cy - p[1]) * dy) for p in poly]
    d.polygon(inset(left, 0.035, 0.04), fill=cream)
    d.polygon(inset(right, 0.035, 0.04), fill=cream)

    # page lines
    for side in (0, 1):
        for i in range(4):
            y0 = S * (0.62 + i * 0.045)
            if side == 0:
                d.line([(S * 0.25, y0), (S * 0.45, y0 - S * 0.018)],
                       fill=(170, 160, 145, 120), width=max(1, int(S * 0.004)))
            else:
                d.line([(S * 0.55, y0 - S * 0.018), (S * 0.75, y0)],
                       fill=(170, 160, 145, 120), width=max(1, int(S * 0.004)))

    # spine shadow
    d.line([(S * 0.50, S * 0.52), (S * 0.50, S * 0.82)],
           fill=(120, 105, 88, 150), width=max(2, int(S * 0.006)))

    # gold bookmark ribbon
    ribbon = [(S * 0.62, S * 0.58), (S * 0.68, S * 0.58),
              (S * 0.68, S * 0.90), (S * 0.65, S * 0.86), (S * 0.62, S * 0.90)]
    d.polygon(ribbon, fill=(224, 176, 76, 255))
    d.line(ribbon + [ribbon[0]], fill=(255, 219, 130, 180), width=max(1, int(S * 0.002)))

    # soft inner border
    d.rounded_rectangle([S * 0.012, S * 0.012, S * 0.988, S * 0.988],
                        radius=int(S * 0.218), outline=(190, 210, 255, 40),
                        width=max(1, int(S * 0.0025)))

    master = base.resize((MASTER, MASTER), Image.LANCZOS)
    master.save(os.path.join(OUT, "icon_512x512@2x.png"))

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))

    contents = {
        "images": [
            {"idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"},
            {"idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"},
            {"idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"},
            {"idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"},
            {"idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"},
            {"idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"},
            {"idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"},
            {"idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"},
            {"idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"},
            {"idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
