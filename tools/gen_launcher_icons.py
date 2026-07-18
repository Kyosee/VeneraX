"""Generate Android + iOS launcher-icon resources for the new presets.

Source art is a centered subject on a transparent canvas. We crop to the
opaque bbox, then re-pad onto a square so the subject occupies a precise
fraction of each target — avoiding the double-margin that scaling the raw
(already-margined) source would cause.

Run from repo root:  python tools/gen_launcher_icons.py
"""
import os
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Android legacy-icon sizes (complete icon on solid bg).
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# Android adaptive foreground sizes (subject on transparent, bg via XML).
FOREGROUND = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
# iOS alternate-icon loose files (complete icon on solid bg, no alpha).
IOS = {"@2x": 120, "@3x": 180}

# Subject fill fractions (subject width / canvas width).
LEGACY_FILL = 0.72       # legacy square icon
FG_FILL = 0.64           # adaptive foreground -> fits 72/108 safe zone
IOS_FILL = 0.76          # iOS icon (own rounding mask)


def crop_subject(im):
    """Crop to the opaque bounding box."""
    im = im.convert("RGBA")
    bbox = im.getbbox()
    return im.crop(bbox) if bbox else im


def fit(subject, canvas_px, fill, bg):
    """Center `subject` on a `canvas_px` square so it fills `fill` of the
    width. `bg` is an RGB tuple for a solid background, or None for
    transparent."""
    target_w = int(canvas_px * fill)
    w, h = subject.size
    scale = target_w / max(w, h)
    new = subject.resize(
        (max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS
    )
    if bg is None:
        canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
    else:
        canvas = Image.new("RGBA", (canvas_px, canvas_px), bg + (255,))
    x = (canvas_px - new.size[0]) // 2
    y = (canvas_px - new.size[1]) // 2
    canvas.alpha_composite(new, (x, y))
    return canvas


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def gen(src_rel, name, bg_hex):
    src = os.path.join(REPO, src_rel)
    subject = crop_subject(Image.open(src))
    bg = hexrgb(bg_hex)
    andr = os.path.join(REPO, "android/app/src/main/res")

    for dpi, px in LEGACY.items():
        out = os.path.join(andr, f"mipmap-{dpi}", f"ic_launcher_{name}.png")
        fit(subject, px, LEGACY_FILL, bg).save(out)
    for dpi, px in FOREGROUND.items():
        out = os.path.join(
            andr, f"mipmap-{dpi}", f"ic_launcher_{name}_foreground.png"
        )
        fit(subject, px, FG_FILL, None).save(out)

    ios = os.path.join(REPO, "ios/Runner")
    cap = name.capitalize()  # mono -> Mono, illust -> Illust
    for suf, px in IOS.items():
        out = os.path.join(ios, f"AltIcon{cap}{suf}.png")
        # iOS icons must be fully opaque; flatten to RGB.
        fit(subject, px, IOS_FILL, bg).convert("RGB").save(out)

    print(f"{name}: generated Android + iOS from {src_rel} (bg {bg_hex})")


if __name__ == "__main__":
    gen("assets/new_logo2.png", "mono", "#FFFFFF")
    gen("assets/new_logo3.png", "illust", "#14102A")
    print("done")
