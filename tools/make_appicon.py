#!/usr/bin/env python3
"""Build the tvOS app icon and Top Shelf art (brand assets) for HomeReel. Pillow only, drawn in code (no image API).

Layers, back to front: deep teal-to-indigo gradient; a film reel (ring with holes and a hub); a white play triangle.
Writes HomeReel/Assets.xcassets/"App Icon & Top Shelf Image.brandassets".

Run from the repo root:   python3 tools/make_appicon.py        (needs Pillow)
"""
import json
import os
import shutil

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)  # repo root
ASSETS = os.path.join(APP, "HomeReel", "Assets.xcassets")
BRAND = os.path.join(ASSETS, "App Icon & Top Shelf Image.brandassets")
INFO = {"info": {"version": 1, "author": "xcode"}}
SS = 3  # supersampling for smooth edges


def gradient(w, h):
    top, bot = (14, 22, 52), (28, 120, 150)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img.convert("RGBA")


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def finish(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def capsule(d, x0, y0, x1, y1, fill):
    r = (y1 - y0) / 2
    d.rounded_rectangle((x0, y0, x1, y1), radius=r, fill=fill)


def layers(w, h):
    """(back, middle, front) as w x h RGBA images. Everything scales with the height."""
    import math
    u = h * SS
    cx, cy = w * SS / 2, h * SS / 2
    back = gradient(w, h)

    # Middle: a film reel. A pale ring with 6 round holes and a small hub.
    mid = canvas(w, h)
    d = ImageDraw.Draw(mid)
    R = 0.40 * u
    d.ellipse((cx - R, cy - R, cx + R, cy + R), fill=(226, 238, 255, 255))
    for i in range(6):
        a = math.radians(60 * i + 30)
        hx, hy = cx + math.cos(a) * 0.255 * u, cy + math.sin(a) * 0.255 * u
        r = 0.085 * u
        d.ellipse((hx - r, hy - r, hx + r, hy + r), fill=(0, 0, 0, 0))
    d.ellipse((cx - 0.05 * u, cy - 0.05 * u, cx + 0.05 * u, cy + 0.05 * u), fill=(0, 0, 0, 0))
    # punch the holes through (draw with clear)
    mid = mid
    holes = canvas(w, h)
    hd = ImageDraw.Draw(holes)
    hd.ellipse((cx - R, cy - R, cx + R, cy + R), fill=(226, 238, 255, 255))
    mid = holes
    d = ImageDraw.Draw(mid)
    for i in range(6):
        a = math.radians(60 * i + 30)
        hx, hy = cx + math.cos(a) * 0.255 * u, cy + math.sin(a) * 0.255 * u
        r = 0.085 * u
        d.ellipse((hx - r, hy - r, hx + r, hy + r), fill=(0, 0, 0, 0))
    d.ellipse((cx - 0.05 * u, cy - 0.05 * u, cx + 0.05 * u, cy + 0.05 * u), fill=(0, 0, 0, 0))
    mid = finish(mid, w, h)

    # Front: a play triangle with a soft shadow so it lifts off the reel when the icon moves.
    fr = canvas(w, h)
    sh = canvas(w, h)
    for layer, color, dy in ((sh, (0, 20, 60, 150), 0.02 * u), (fr, (255, 255, 255, 255), 0)):
        dd = ImageDraw.Draw(layer)
        dd.polygon([(cx - 0.085 * u, cy - 0.15 * u + dy), (cx - 0.085 * u, cy + 0.15 * u + dy), (cx + 0.16 * u, cy + dy)], fill=color)
    sh = finish(sh, w, h).filter(ImageFilter.GaussianBlur(h * 0.012))
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    front.alpha_composite(sh)
    front.alpha_composite(finish(fr, w, h))
    return back, mid, front


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def save(img, path, flat=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    (img.convert("RGB") if flat else img).save(path)


def imagestack(name, w, h, scales):
    stack = os.path.join(BRAND, f"{name}.imagestack")
    names = ["Front", "Middle", "Back"]
    write_json(os.path.join(stack, "Contents.json"), {"layers": [{"filename": f"{n}.imagestacklayer"} for n in names], **INFO})
    for scale in scales:
        back, mid, front = layers(w * scale, h * scale)
        for lname, img in zip(names, (front, mid, back)):
            layer = os.path.join(stack, f"{lname}.imagestacklayer")
            write_json(os.path.join(layer, "Contents.json"), INFO)
            fn = f"{lname}@{scale}x.png"
            save(img, os.path.join(layer, "Content.imageset", fn), flat=(lname == "Back"))
            cj = os.path.join(layer, "Content.imageset", "Contents.json")
            entries = json.load(open(cj))["images"] if os.path.exists(cj) else []
            entries.append({"idiom": "tv", "filename": fn, "scale": f"{scale}x"})
            write_json(cj, {"images": entries, **INFO})


def topshelf(name, w, h):
    d = os.path.join(BRAND, f"{name}.imageset")
    entries = []
    for scale in (1, 2):
        back, mid, front = layers(w * scale, h * scale)
        flat = back.copy()
        flat.alpha_composite(mid)
        flat.alpha_composite(front)
        fn = f"{name.replace(' ', '')}@{scale}x.png"
        save(flat, os.path.join(d, fn), flat=True)
        entries.append({"idiom": "tv", "filename": fn, "scale": f"{scale}x"})
    write_json(os.path.join(d, "Contents.json"), {"images": entries, **INFO})


if os.path.isdir(BRAND):
    shutil.rmtree(BRAND)
os.makedirs(BRAND)
write_json(os.path.join(ASSETS, "Contents.json"), INFO)
imagestack("App Icon - Large", 1280, 768, (1,))
imagestack("App Icon - Small", 400, 240, (1, 2))
topshelf("Top Shelf Image", 1920, 720)
topshelf("Top Shelf Image Wide", 2320, 720)
write_json(os.path.join(BRAND, "Contents.json"), {"assets": [
    {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
], **INFO})
print("wrote", BRAND)
