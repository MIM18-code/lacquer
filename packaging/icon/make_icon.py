"""Draws Lacquer's app icon: a black, glossy optical disc on a lacquer-red tile.

    python3 packaging/icon/make_icon.py   # writes packaging/AppIcon.icns

Needs Pillow and NumPy. Rendered at 2x and downsampled for clean edges.
"""
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
SS = 2                      # supersampling factor
N = 1024 * SS
C = N / 2


def squircle_mask(size, inset, exponent=5.0):
    """macOS-style superellipse tile."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    r = size / 2 - inset
    nx = np.abs(x - size / 2 + 0.5) / r
    ny = np.abs(y - size / 2 + 0.5) / r
    inside = (nx ** exponent + ny ** exponent) <= 1.0
    return Image.fromarray((inside * 255).astype(np.uint8))


def radial(size):
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    return np.hypot(x - size / 2 + 0.5, y - size / 2 + 0.5), np.arctan2(y - size / 2, x - size / 2)


def render():
    inset = 100 * SS                       # Apple grid: 824pt tile in 1024
    tile = squircle_mask(N, inset)
    dist, ang = radial(N)
    y = np.mgrid[0:N, 0:N][0].astype(np.float64) / N

    # Lacquer red, lit from the top.
    top = np.array([196, 38, 38], dtype=np.float64)
    bottom = np.array([112, 14, 20], dtype=np.float64)
    bg = top[None, None, :] * (1 - y[..., None]) + bottom[None, None, :] * y[..., None]

    # Disc: black with fine tracks and a blue-violet sheen (the Blu-ray tint).
    disc_r = 330 * SS
    hub_r = 92 * SS             # clear plastic hub
    stack_r = 62 * SS           # stacking ring
    hole_r = 24 * SS
    rr = dist / disc_r
    tracks = 0.5 + 0.5 * np.sin(dist / (1.6 * SS) * np.pi)
    sheen = np.clip(np.cos(2 * (ang + 0.75)), 0, 1) ** 5        # two opposed highlights
    glow = sheen * (0.3 + 0.7 * rr)
    tint = np.array([108, 112, 255], dtype=np.float64)
    base = 12 + 7 * tracks
    disc = base[..., None] + glow[..., None] * tint[None, None, :] * 0.75 \
        + (glow ** 3)[..., None] * 90

    img = bg.copy()
    in_disc = dist <= disc_r
    img[in_disc] = disc[in_disc]

    # Hub: clear plastic shows the red through, darkened; a grey stacking
    # ring; the centre hole.
    in_hub = dist <= hub_r
    img[in_hub] = bg[in_hub] * 0.45 + 18
    data_edge = (dist <= hub_r + 3 * SS) & (dist > hub_r)
    img[data_edge] = 70
    in_stack = (dist <= stack_r) & (dist >= stack_r - 10 * SS)
    img[in_stack] = np.array([150, 150, 158], dtype=np.float64)
    in_hole = dist <= hole_r
    img[in_hole] = bg[in_hole] * 0.9

    # Rim highlight so the disc reads against the red.
    rim = (dist <= disc_r) & (dist >= disc_r - 4 * SS)
    img[rim] = img[rim] * 0.4 + 255 * 0.25

    rgb = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")

    # Disc drop shadow onto the tile.
    shadow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(shadow).ellipse(
        [C - disc_r, C - disc_r + 18 * SS, C + disc_r, C + disc_r + 18 * SS], fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(22 * SS))
    shaded = Image.composite(Image.new("RGB", (N, N), (40, 4, 6)), Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8)), shadow)
    disc_mask = Image.fromarray((in_disc * 255).astype(np.uint8))
    rgb = Image.composite(rgb, shaded, disc_mask)

    # Soft top gloss on the tile.
    gloss = Image.fromarray((np.clip(0.18 - y * 0.35, 0, 1) * 255).astype(np.uint8))
    rgb = Image.composite(Image.new("RGB", (N, N), (255, 255, 255)), rgb, gloss)

    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    # Tile shadow, per Apple's icon template.
    tshadow = tile.filter(ImageFilter.GaussianBlur(14 * SS)).point(lambda v: int(v * 0.45))
    tshadow = Image.fromarray(np.roll(np.array(tshadow), 10 * SS, axis=0))
    out.paste(Image.new("RGBA", (N, N), (0, 0, 0, 255)), (0, 0), tshadow)
    out.paste(rgb.convert("RGBA"), (0, 0), tile)
    return out.resize((1024, 1024), Image.LANCZOS)


def main():
    master = render()
    master.save(HERE / "AppIcon-1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
                master.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE.parent / "AppIcon.icns")], check=True)
    print("wrote", HERE.parent / "AppIcon.icns")


if __name__ == "__main__":
    main()
