#!/usr/bin/env python3
"""Composite exact-window Retina captures into deterministic demo videos.

No desktop pixels are captured. Background, menu bar and pointer are drawn here.
OrbPeek writes AX positions immediately (no easing) and polls at 30 Hz, so all
synthetic motion uses linear 30 Hz samples; six-frame transitions aid legibility.
"""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/assets/demo-source"
ASSETS = ROOT / "docs/assets"
WORK = ROOT / "Artifacts/orbpeek-demo/render"
FPS = 30
SLIDE_FRAMES = 6
SIZE = (2560, 1600)  # 2x 1280×800


def lerp(a, b, t):
    return a + (b - a) * t


def background(variant):
    W, H = SIZE
    top, bottom = ((218, 230, 238), (246, 244, 239)) if variant == "light" else ((14, 24, 35), (38, 52, 65))
    image = Image.new("RGB", SIZE)
    draw = ImageDraw.Draw(image)
    for y in range(H):
        t = y / (H - 1)
        color = tuple(round(lerp(top[c], bottom[c], t)) for c in range(3))
        draw.line((0, y, W, y), fill=color)
    menu_color = (246, 248, 249) if variant == "light" else (24, 31, 38)
    draw.rectangle((0, 0, W, 50), fill=menu_color)
    draw.line((0, 50, W, 50), fill=(190, 202, 207) if variant == "light" else (55, 67, 76))
    icon = Image.open(ROOT / "Resources/Assets.xcassets/MenuIcon.imageset/menuicon@2x.png").convert("RGBA")
    icon = icon.resize((32, 32), Image.Resampling.LANCZOS)
    if variant == "dark":
        alpha = icon.getchannel("A")
        icon = Image.new("RGBA", icon.size, (235, 241, 243, 255))
        icon.putalpha(alpha)
    image.paste(icon, (W - 58, 9), icon)
    return image


def paste(base, overlay, xy):
    frame = base.copy()
    if overlay.mode == "RGBA":
        frame.paste(overlay, xy, overlay)
    else:
        frame.paste(overlay, xy)
    return frame


def cursor(image, xy):
    image = image.copy()
    x, y = xy
    points = [(x, y), (x + 3, y + 23), (x + 8, y + 16), (x + 15, y + 28),
              (x + 20, y + 25), (x + 13, y + 13), (x + 23, y + 11)]
    ImageDraw.Draw(image).polygon(points, fill="#f8f8f8", outline="#202020")
    return image


def render_variant(variant):
    source = SOURCE / variant
    required = {name: source / f"{name}.png" for name in ("normal", "docked", "peeked")}
    missing = [str(path) for path in required.values() if not path.exists()]
    if missing:
        raise SystemExit("Missing exact-window captures:\n" + "\n".join(missing) +
                         "\nRun Scripts/capture-demo.sh --capture for this variant first.")
    normal = Image.open(required["normal"]).convert("RGBA")
    strip = Image.open(required["docked"]).convert("RGBA")
    peeked = Image.open(required["peeked"]).convert("RGBA")
    base = background(variant)
    W, H = base.size
    wx, wy = 80, 150
    ww, wh = normal.size
    normal_frame = paste(base, normal, (wx, wy))
    docked_frame = paste(base, strip, (W - strip.width, wy))
    frames = []

    def add(image, count=1):
        frames.extend(image.copy() for _ in range(count))

    add(cursor(normal_frame, (W * .45, H * .45)), FPS)
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        add(cursor(paste(base, normal, (round(lerp(wx, W - 1, t)), wy)), (W * .45, H * .45)))
    add(cursor(docked_frame, (W * .8, H * .5)), FPS // 2)
    for i in range(16):
        t = i / 15
        add(cursor(docked_frame, (lerp(W * .8, W - 8, t), H * .5)))
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        add(cursor(paste(docked_frame, peeked, (round(lerp(W - 1, W - ww, t)), wy)), (W - 12, H * .5)))
    add(cursor(paste(base, peeked, (W - ww, wy)), (W - ww / 2, H * .45)), FPS)
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        add(cursor(paste(base, peeked, (round(lerp(W - ww, W - 1, t)), wy)), (lerp(W - 12, W * .65, t), H * .5)))
    add(cursor(docked_frame, (W * .65, H * .5)), FPS // 2)

    out = WORK / variant
    out.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(frames):
        frame.save(out / f"{index:04d}.jpg", quality=91, optimize=True)
    normal_frame.save(ASSETS / f"orbpeek-poster-{variant}.png")

    video = ASSETS / f"orbpeek-demo-{variant}.mp4"
    subprocess.run(["ffmpeg", "-y", "-framerate", str(FPS), "-i", str(out / "%04d.jpg"),
                    "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(video)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    gif = ASSETS / f"demo-{variant}.gif"
    subprocess.run(["ffmpeg", "-y", "-i", str(video), "-filter_complex",
                    "[0:v]fps=12,scale=960:-1:flags=lanczos,split[a][b];"
                    "[a]palettegen=max_colors=96:stats_mode=diff[p];"
                    "[b][p]paletteuse=dither=bayer:bayer_scale=4", "-loop", "0", str(gif)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"{variant}: {len(frames)} frames, {video.name}={video.stat().st_size / 1e6:.2f}MB, "
          f"{gif.name}={gif.stat().st_size / 1e6:.2f}MB")
    if gif.stat().st_size > 3_000_000:
        print(f"warning: {gif} exceeds the 3MB target")


def main():
    variants = [name for name in ("light", "dark") if (SOURCE / name).is_dir()]
    if not variants:
        raise SystemExit("No exact-window captures found. Run --trial, then capture light/dark sources.")
    for variant in variants:
        render_variant(variant)


if __name__ == "__main__":
    main()
