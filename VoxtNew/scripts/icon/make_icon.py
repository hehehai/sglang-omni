#!/usr/bin/env python3
"""Generate VoxtNew's macOS app icon (1024x1024 RGBA) and a preview sheet.

Glyph: Voxt's microphone mascot (sglang-omni Voxt/Voxt/logo.svg, same
author, Apache-2.0), paths copied verbatim below. Layout matches
Auralink's resources/icon.png so the two sit together in the Dock.

Needs: Python 3 + Pillow, and rsvg-convert (librsvg) on PATH.
Usage: python3 make_icon.py [--out DIR] [--auralink PATH]
"""

import argparse
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

# --- Paths from Voxt/Voxt/logo.svg (viewBox 0 0 231 232) --------------------
SPARKLE = (
    "M195.42 43.0003C189.53 41.5603 186.12 37.8803 184.48 33.6103C183.55 31.1503 180.46 32.3803 179.94 34.9403C177.36 41.0503 174.16 45.1003 169.4 47.4503C167.35 48.3803 167.04 51.6503 168.99 52.0603C174.89 53.6103 178.2 56.9803 180.35 60.8703C181.58 63.1203 184.06 61.7903 184.68 59.3303C187.26 53.2103 190.98 49.7403 195.63 47.3903C197.68 46.4603 197.58 43.7103 195.42 43.0003Z"
)
BLOB = (
    "M138.043 61.9803C174.45 88.3256 195.247 136.854 178.782 159.608C162.316 182.363 128.035 187.147 91.6282 160.802C55.221 134.457 30.4735 86.9577 46.9394 64.2032C63.4052 41.4487 101.635 35.6349 138.043 61.9803Z"
)
STAND = (
    "M170.052 98.5039C165.056 98.5039 163.66 103.119 163.66 105.776V120.619C163.66 147.902 142.043 168.839 114.461 168.839C87.44 168.839 67.6461 147.676 67.6461 120.619V105.649C67.6461 101.297 64.8353 98.649 61.0542 98.649C56.5025 98.649 54.29 102.775 54.29 106.402V121.517C54.29 150.468 75.308 175.73 105.121 182.15V193.157H92.291C87.44 193.157 86.0436 197.772 86.0436 199.613C86.0436 204.292 89.7068 207.003 92.427 206.949H139.169C143.53 206.949 146.06 202.832 145.924 199.613C145.788 195.488 142.56 193.157 139.305 193.157H126.475V182.431C154.057 177.679 175.946 154.277 175.946 122.224V105.513C175.946 101.668 173.588 98.5039 170.052 98.5039Z"
)
EYE_L = (
    "M101.691 62.961C103.641 63.0608 105.164 63.7865 105.626 64.3849C103.096 64.784 101.836 66.7602 101.836 68.7276C101.836 71.9465 104.185 73.5782 106.271 73.5782C109.063 73.578 110.178 71.6109 110.314 70.4503C111.838 73.1976 112.662 76.5525 112.662 80.0069C112.662 88.2128 107.358 96.6094 100.839 96.6095C92.7238 96.6095 88.2902 87.2887 88.29 80.2706C88.29 70.9495 94.2653 62.6074 101.691 62.961Z"
)
EYE_R = (
    "M131.955 62.9565C133.904 63.0473 135.427 63.7732 136.116 64.4985C133.995 65.0516 132.472 66.2574 132.472 68.5874C132.472 71.5796 134.684 73.2846 137.032 73.2847C139.961 73.2847 140.94 71.4616 141.448 70.1196C143.171 73.4291 143.996 76.467 143.996 80.3296C143.996 88.2634 138.166 96.9407 130.976 96.9409C122.87 96.9409 118.29 87.1939 118.29 80.602C118.29 72.3962 123.985 62.6664 131.955 62.9565Z"
)
HEAD = (
    "M115.497 31.9502H115.361C91.9674 31.9502 76.29 52.678 76.29 72.7167V120.057C76.29 141.447 93.7627 159.944 115.361 159.944H115.497C137.24 159.944 155.955 140.921 155.955 120.057V72.7167C155.955 51.9979 139.861 31.9502 115.497 31.9502ZM100.826 96.3369C92.7109 96.3369 88.277 87.0158 88.277 79.9977C88.277 70.6765 94.2523 62.3346 101.678 62.6883C103.628 62.788 105.151 63.5134 105.614 64.1118C103.084 64.5108 101.823 66.4875 101.823 68.4551C101.823 71.6739 104.172 73.3061 106.257 73.3061C109.05 73.3061 110.165 71.3385 110.301 70.1778C111.825 72.9252 112.65 76.2801 112.65 79.7348C112.65 87.9406 107.345 96.3369 100.826 96.3369ZM130.993 96.609C122.887 96.609 118.308 86.8616 118.308 80.2697C118.308 72.0638 124.002 62.3346 131.972 62.6248C133.922 62.7155 135.445 63.4409 136.134 64.1662C134.012 64.7193 132.489 65.9253 132.489 68.2556C132.489 71.2478 134.701 72.9524 137.05 72.9524C139.979 72.9524 140.958 71.1299 141.466 69.788C143.188 73.0975 144.014 76.135 144.014 79.9977C144.014 87.9316 138.183 96.609 130.993 96.609Z"
)

# ---------------------------------------------------------------------------
# Layout: match Auralink's resources/icon.png (measured): 1024x1024 canvas,
# opaque body 100..923 (824 px), corner radius ~185 px, no drop shadow,
# vertical gradient body, white glyph.
# ---------------------------------------------------------------------------

SIZE = 1024
BODY = 824
ORIGIN = (SIZE - BODY) // 2  # 100
RADIUS = 185

# Voxt logo.svg: the body (the rounded rect) spans x 1.35..229.7 in a
# 231x232 viewBox; map that span onto ours, then shrink the glyph a little
# so it carries about the same visual weight as Auralink's bars.
LOGO_BODY_X0 = 1.35
LOGO_BODY_W = 229.7 - 1.35
LOGO_CENTER = (115.5, 115.5)

# Warm orange/coral: clearly apart from the family's teal (Pik, Dicta,
# Auralink) and blue-violet (AudioSmith).
ORANGE_TOP = "#FF9F43"
ORANGE_BOTTOM = "#F2542D"
EYE_ON_ORANGE = "#7A2410"


def body_rect(fill):
    return (
        f'<rect x="{ORIGIN}" y="{ORIGIN}" width="{BODY}" height="{BODY}" '
        f'rx="{RADIUS}" ry="{RADIUS}" fill="{fill}"/>'
    )


def gradient(gid, top, bottom):
    return (
        f'<linearGradient id="{gid}" x1="0" y1="{ORIGIN}" x2="0" '
        f'y2="{ORIGIN + BODY}" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{top}"/>'
        f'<stop offset="1" stop-color="{bottom}"/></linearGradient>'
    )


def logo_transform(glyph_scale, dx=0.0, dy=0.0):
    """SVG transform from Voxt logo coordinates into the icon body."""
    s = BODY / LOGO_BODY_W * glyph_scale
    cx, cy = LOGO_CENTER
    tx = SIZE / 2 - cx * s + dx
    ty = SIZE / 2 - cy * s + dy
    return f"matrix({s:.5f} 0 0 {s:.5f} {tx:.3f} {ty:.3f})"


def mascot(eye, blob_fill, blob_opacity, sparkle, glyph_scale, dx=0.0, dy=0.0):
    """Voxt's mic mascot (logo.svg paths)."""
    t = logo_transform(glyph_scale, dx, dy)
    return (
        f'<g transform="{t}">'
        f'<path d="{BLOB}" fill="{blob_fill}" fill-opacity="{blob_opacity}"/>'
        f'<path d="{STAND}" fill="#FFFFFF"/>'
        # Head outline only (the logo's HEAD path also cuts slightly larger
        # eye holes, which leave a seam), then the eyes on top; their notch
        # reveals the white head as the highlight.
        f'<path d="{HEAD.split("Z")[0]}Z" fill="#FFFFFF"/>'
        f'<path d="{EYE_L}" fill="{eye}"/>'
        f'<path d="{EYE_R}" fill="{eye}"/>'
        f'<path d="{SPARKLE}" fill="{sparkle}"/>'
        "</g>"
    )


def tray_mic(color):
    """VoxtNew's menu bar mic (internal/trayicon/voxt.png) redrawn as
    vectors: capsule head with two grille arcs cut out, U-shaped cradle.
    Coordinates are measured on the 512 px tray image."""
    k = 1.32  # glyph ~560 px tall, like Auralink's bars

    def p(x, y):
        return SIZE / 2 + (x - 255.5) * k, SIZE / 2 + (y - 255.5) * k

    stroke = 29.5 * k
    cap_x0, cap_y0 = p(123, 43)
    cap_x1, cap_y1 = p(389, 410)
    w = cap_x1 - cap_x0
    head = (
        f'<rect x="{cap_x0:.1f}" y="{cap_y0:.1f}" width="{w:.1f}" '
        f'height="{cap_y1 - cap_y0:.1f}" rx="{w / 2:.1f}" fill="{color}"/>'
    )
    lx, top = p(78.5, 241)
    rx_, mid = p(432.5, 290)
    cradle = (
        f'<path d="M{lx:.1f},{top:.1f} V{mid:.1f} '
        f'A{177 * k:.1f},{163.5 * k:.1f} 0 0 0 {rx_:.1f},{mid:.1f} '
        f'V{top:.1f}" fill="none" stroke="{color}" '
        f'stroke-width="{stroke:.1f}" stroke-linecap="round"/>'
    )
    arcs = ""
    for dy in (-59, 0):
        x0, y0 = p(217, 207 + dy)
        x1, _ = p(294, 207 + dy)
        cx, cy = p(255.5, 185 + dy)
        arcs += (
            f'<path d="M{x0:.1f},{y0:.1f} Q{cx:.1f},{cy:.1f} {x1:.1f},{y0:.1f}" '
            f'fill="none" stroke="#000" stroke-width="{stroke:.1f}" '
            'stroke-linecap="round"/>'
        )
    # Grille arcs are cut out of the head so the body colour shows through.
    mask = (
        f'<mask id="grille" maskUnits="userSpaceOnUse" x="0" y="0" '
        f'width="{SIZE}" height="{SIZE}">'
        f'<rect width="{SIZE}" height="{SIZE}" fill="#fff"/>{arcs}</mask>'
    )
    return mask, f'<g mask="url(#grille)">{head}</g>{cradle}'


def svg(defs, content):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" '
        f'height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}"><defs>{defs}</defs>'
        f"{content}</svg>"
    )


def variant_main():
    """Orange body + white Voxt mascot."""
    return svg(
        gradient("bg", ORANGE_TOP, ORANGE_BOTTOM),
        body_rect("url(#bg)")
        + mascot(
            eye=EYE_ON_ORANGE,
            blob_fill="#FFFFFF",
            blob_opacity=0.22,
            sparkle="#FFFFFF",
            glyph_scale=0.92,
            dy=8,
        ),
    )


def variant_dark():
    """Voxt's near-black body + white mascot, orange accents."""
    return svg(
        gradient("bg", "#2A2A2E", "#0B0B0D"),
        body_rect("url(#bg)")
        + mascot(
            eye="#1A1A1C",
            blob_fill=ORANGE_BOTTOM,
            blob_opacity=0.85,
            sparkle=ORANGE_TOP,
            glyph_scale=0.92,
            dy=8,
        ),
    )


def variant_tray():
    """Orange body + flat menu-bar mic (no face): pure family style."""
    mask, glyph = tray_mic("#FFFFFF")
    return svg(
        gradient("bg", ORANGE_TOP, ORANGE_BOTTOM) + mask,
        body_rect("url(#bg)") + glyph,
    )


VARIANTS = {
    "icon.png": variant_main,
    "icon-alt1.png": variant_dark,
    "icon-alt2.png": variant_tray,
}


def render(svg_text, out_path):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        tmp = f.name
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), "-o", out_path, tmp],
            check=True,
        )
    finally:
        os.unlink(tmp)
    # Normalise to 8-bit RGBA.
    Image.open(out_path).convert("RGBA").save(out_path, optimize=True)


def contact_sheet(rows, out_path):
    """rows: [(label, image)]; columns: 1024 (shown at 256), 128, 32, 16 px
    on a light and a dark backdrop. Small sizes are drawn 1:1 and also 4x
    (nearest) so the pixels can be judged."""
    sizes = [128, 32, 16]
    cell = 280
    label_w = 150
    sheet_w = label_w + 2 * (cell + len(sizes) * 150)
    sheet_h = 40 + len(rows) * cell
    sheet = Image.new("RGBA", (sheet_w, sheet_h), (255, 255, 255, 255))
    d = ImageDraw.Draw(sheet)
    backdrops = [((236, 236, 236, 255), (0, 0, 0)), ((30, 30, 32, 255), (230, 230, 230))]
    half = cell + len(sizes) * 150
    for b, (bg, fg) in enumerate(backdrops):
        x0 = label_w + b * half
        d.rectangle([x0, 0, x0 + half - 1, sheet_h], fill=bg)
        d.text((x0 + 10, 12), "1024 (shown 256)", fill=fg)
        for i, s in enumerate(sizes):
            d.text((x0 + cell + i * 150 + 10, 12), f"{s}px (1:1 + 4x)", fill=fg)
    for r, (label, img) in enumerate(rows):
        y = 40 + r * cell
        d.text((10, y + cell // 2 - 6), label, fill=(0, 0, 0))
        for b in range(2):
            x0 = label_w + b * half
            sheet.alpha_composite(img.resize((256, 256), Image.LANCZOS), (x0 + 12, y + 12))
            for i, s in enumerate(sizes):
                small = img.resize((s, s), Image.LANCZOS)
                cx = x0 + cell + i * 150
                sheet.alpha_composite(small, (cx + 10, y + 12))
                if s < 128:
                    big = small.resize((s * 4, s * 4), Image.NEAREST)
                    sheet.alpha_composite(big, (cx + 10, y + 12 + s + 10))
    sheet.save(out_path, optimize=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--auralink", default="/home/guanwei/helper/Auralink/resources/icon.png")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rows = []
    for name, make in VARIANTS.items():
        path = os.path.join(args.out, name)
        render(make(), path)
        rows.append((f"VoxtNew {name}", Image.open(path).convert("RGBA")))
        with open(os.path.join(args.out, name.replace(".png", ".svg")), "w") as f:
            f.write(make())
    if os.path.exists(args.auralink):
        rows.append(("Auralink", Image.open(args.auralink).convert("RGBA")))
    contact_sheet(rows, os.path.join(args.out, "preview.png"))


if __name__ == "__main__":
    main()
