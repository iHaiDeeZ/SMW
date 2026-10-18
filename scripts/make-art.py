#!/usr/bin/env python3
"""SMW's home screen art: sce_sys/icon0.png (512x512) and sce_sys/pic1.png (1920x1080).

Drawn from shapes only (a sky, rolling hills, a sparkle burst, round "SMW" letters in Fredoka, SIL OFL 1.1): no
game asset, character or logo.

Usage: python3 scripts/make-art.py <Fredoka.ttf> [out dir, default sce_sys]
       python3 scripts/make-art.py <Fredoka.ttf> <out dir> --boot     (the boot screen's assets, make_boot)
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont


def lerp(a, b, t):
    return tuple(int(round(a[k] + (b[k] - a[k]) * t)) for k in range(len(a)))


def sky(w, h):
    img = Image.new("RGB", (w, h))
    top, mid, bottom = (38, 64, 189), (64, 148, 240), (150, 222, 255)
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = lerp(top, mid, t / 0.6) if t < 0.6 else lerp(mid, bottom, (t - 0.6) / 0.4)
        for x in range(w):
            px[x, y] = c
    return img


def burst(img, cx, cy, r, rays=16):
    """Soft light rays and a glowing core: the 'wonder' sparkle."""
    w, h = img.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for k in range(rays):
        a0 = 2 * math.pi * k / rays
        a1 = a0 + math.pi / rays * 0.55
        pts = [(cx, cy), (cx + math.cos(a0) * r * 2.2, cy + math.sin(a0) * r * 2.2),
               (cx + math.cos(a1) * r * 2.2, cy + math.sin(a1) * r * 2.2)]
        d.polygon(pts, fill=(255, 245, 190, 46))
    for k in range(6, 0, -1):
        rr = r * k / 6
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(255, 236, 140, int(40 + 25 * (6 - k))))
    layer = layer.filter(ImageFilter.GaussianBlur(r * 0.06))
    img.paste(layer, (0, 0), layer)


def star(d, cx, cy, r, fill, points=5, inner=0.45, rot=-math.pi / 2):
    pts = []
    for k in range(points * 2):
        rr = r if k % 2 == 0 else r * inner
        a = rot + math.pi * k / points
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    d.polygon(pts, fill=fill)


def hills(img, base, scale):
    w, h = img.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for (cx, cy, rx, ry, col) in [
        (0.15, 0.98, 0.45, 0.30, (78, 186, 92)),
        (0.80, 1.02, 0.55, 0.34, (60, 168, 80)),
        (0.45, 1.10, 0.60, 0.30, (96, 204, 104)),
    ]:
        d.ellipse([w * (cx - rx), h * (cy - ry) - base, w * (cx + rx), h * (cy + ry) - base], fill=col + (255,))
    # little round bushes and dots on the hills
    for (x, y, r) in [(0.10, 0.80, 0.035), (0.88, 0.83, 0.03), (0.62, 0.90, 0.025)]:
        d.ellipse([w * x - h * r, h * y - h * r - base, w * x + h * r, h * y + h * r - base], fill=(44, 140, 64, 255))
    img.paste(layer, (0, 0), layer)


def letters(img, font_path, text, size, cx, cy):
    font = ImageFont.truetype(font_path, size)
    try:
        font.set_variation_by_axes([700])  # Fredoka is a variable font: its boldest weight
    except Exception:
        pass
    w, h = img.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    box = d.textbbox((0, 0), text, font=font, stroke_width=int(size * 0.09))
    tx, ty = cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((tx + size * 0.04, ty + size * 0.07), text, font=font, fill=(20, 24, 80, 170),
                                stroke_width=int(size * 0.09), stroke_fill=(20, 24, 80, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.03))
    img.paste(shadow, (0, 0), shadow)
    d.text((tx, ty), text, font=font, fill=(255, 255, 255, 255), stroke_width=int(size * 0.09),
           stroke_fill=(32, 40, 120, 255))
    # each letter's own colour inside the white outline
    colours = [(240, 64, 56), (255, 196, 32), (64, 176, 255)]
    x = tx
    for k, ch in enumerate(text):
        d.text((x, ty), ch, font=font, fill=colours[k % 3] + (255,))
        x += d.textlength(ch, font=font)
    img.paste(layer, (0, 0), layer)


def make(font, w, h, title_size, subtitle=None, logo_y=0.44, low_stars=True):
    img = sky(w, h).convert("RGBA")
    s = min(w, h)
    burst(img, w * 0.5, h * (logo_y - 0.02), s * 0.30)
    d = ImageDraw.Draw(img)
    stars = [(0.14, 0.18, 0.035), (0.86, 0.16, 0.03)]
    if low_stars:  # the boot screen's bar sits where these are
        stars += [(0.78, 0.62, 0.02), (0.22, 0.60, 0.022)]
    for (x, y, r) in stars:
        star(d, w * x, h * y, s * r, (255, 240, 160, 255))
    hills(img, 0, 1)
    letters(img, font, "SMW", title_size, w * 0.5, h * logo_y)
    if subtitle:
        f = ImageFont.truetype(font, int(title_size * 0.16))
        try:
            f.set_variation_by_axes([600])
        except Exception:
            pass
        d = ImageDraw.Draw(img)
        tw = d.textlength(subtitle, font=f)
        d.text((w / 2 - tw / 2, h * 0.70), subtitle, font=f, fill=(255, 255, 255, 255), stroke_width=4,
               stroke_fill=(32, 40, 120, 255))
    return img.convert("RGB")


GLYPH_W, GLYPH_H, GLYPH_SIZE = 40, 56, 34  # boot screen text cells (ASCII 32-126)


def make_boot(font, out):
    """The boot screen's raw assets (runtime/src/ps4/ps4_boot_screen.cpp reads them from /app0/boot):

    background.rgba  1920x1080 RGBA: the home screen art with the logo high, room for the bar below it
    font.bin         'SMWF', u16 cell width, u16 cell height, u8 first char (32), u8 count (95), count advances
                     (u8), then count cells of RGBA: white Fredoka with a navy outline, the baseline at 3/4 of a cell
    """
    os.makedirs(out, exist_ok=True)
    bg = make(font, 1920, 1080, 340, logo_y=0.33, low_stars=False)
    with open(os.path.join(out, "background.rgba"), "wb") as f:
        f.write(bg.convert("RGBA").tobytes())
    f_ = ImageFont.truetype(font, GLYPH_SIZE)
    try:
        f_.set_variation_by_axes([600])
    except Exception:
        pass
    first, count = 32, 95
    advances, cells = bytearray(), bytearray()
    for k in range(count):
        ch = chr(first + k)
        cell = Image.new("RGBA", (GLYPH_W, GLYPH_H), (0, 0, 0, 0))
        d = ImageDraw.Draw(cell)
        d.text((3, int(GLYPH_H * 0.75)), ch, font=f_, anchor="ls", fill=(255, 255, 255, 255), stroke_width=3,
               stroke_fill=(30, 44, 114, 255))
        advances.append(min(GLYPH_W, int(round(d.textlength(ch, font=f_))) + 2))
        cells += cell.tobytes()
    with open(os.path.join(out, "font.bin"), "wb") as f:
        f.write(b"SMWF" + GLYPH_W.to_bytes(2, "little") + GLYPH_H.to_bytes(2, "little") + bytes([first, count]))
        f.write(bytes(advances) + bytes(cells))
    make_menu_font(font, os.path.join(out, "menu_font.bin"))
    bg.save(os.path.join(out, "preview.png"))
    print("wrote", out, "(background.rgba, font.bin, menu_font.bin)")


MENU_W, MENU_H, MENU_SIZE = 30, 42, 29  # the quick menu's and frame counter's text cells


def make_menu_font(font, path):
    """The quick menu's text (runtime/src/ps4/ps4_menu.cpp): the same format as font.bin, but plain white glyphs
    (anti-aliased in alpha, no outline) drawn at their own size, so the menu can colour them."""
    f_ = ImageFont.truetype(font, MENU_SIZE)
    try:
        f_.set_variation_by_axes([500])
    except Exception:
        pass
    first, count = 32, 95
    advances, cells = bytearray(), bytearray()
    for k in range(count):
        ch = chr(first + k)
        cell = Image.new("RGBA", (MENU_W, MENU_H), (255, 255, 255, 0))
        d = ImageDraw.Draw(cell)
        d.text((1, int(MENU_H * 0.76)), ch, font=f_, anchor="ls", fill=(255, 255, 255, 255))
        advances.append(min(MENU_W, int(round(d.textlength(ch, font=f_)))))
        cells += cell.tobytes()
    with open(path, "wb") as f:
        f.write(b"SMWF" + MENU_W.to_bytes(2, "little") + MENU_H.to_bytes(2, "little") + bytes([first, count]))
        f.write(bytes(advances) + bytes(cells))


def main():
    font = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "sce_sys"
    if len(sys.argv) > 3 and sys.argv[3] == "--boot":
        make_boot(font, out)
        return
    os.makedirs(out, exist_ok=True)
    make(font, 512, 512, 210).save(os.path.join(out, "icon0.png"), optimize=True)
    make(font, 1920, 1080, 420, "Switch recomp for PS4").save(os.path.join(out, "pic1.png"), optimize=True)
    print("wrote", os.path.join(out, "icon0.png"), os.path.join(out, "pic1.png"))


if __name__ == "__main__":
    main()
