#!/usr/bin/env python3
"""Composite real Peekaboo captures into deterministic demo videos.

OrbPeek writes AX positions immediately (no easing) and polls at 30 Hz. The
synthetic cursor/window motion therefore uses linear 30 Hz samples; six-frame
transitions (0.2 s) are solely for legibility, not a claim of native easing.
"""
from pathlib import Path
import shutil
import subprocess
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/assets/demo-source"
ASSETS = ROOT / "docs/assets"
WORK = ROOT / "Artifacts/orbpeek-demo/render"
FPS = 30
SLIDE_FRAMES = 6
REGION = (1280, 800)
WINDOW = (40, 75, 900, 600)  # x, y, width, height, relative to DEMO_REGION


def scaled(rect, width):
    scale = width / REGION[0]
    x, y, w, h = rect
    return tuple(round(v * scale) for v in (x, y, x + w, y + h))


def cursor(image, xy):
    image = image.copy()
    x, y = xy
    # A synthetic pointer, deliberately drawn after the real screen captures.
    points = [(x, y), (x + 3, y + 23), (x + 8, y + 16),
              (x + 15, y + 28), (x + 20, y + 25), (x + 13, y + 13), (x + 23, y + 11)]
    draw = ImageDraw.Draw(image)
    draw.polygon(points, fill="#f8f8f8", outline="#202020")
    return image


def lerp(a, b, t):
    return a + (b - a) * t


def render_variant(variant):
    source = SOURCE / variant
    required = {name: source / f"{name}.png" for name in ("background", "normal", "docked", "peeked")}
    missing = [str(path) for path in required.values() if not path.exists()]
    if missing:
        raise SystemExit("Missing real captures:\n" + "\n".join(missing) +
                         "\nRun Scripts/capture-demo.sh --capture for this variant first.")

    background = Image.open(required["background"]).convert("RGB")
    normal = Image.open(required["normal"]).convert("RGB")
    docked = Image.open(required["docked"]).convert("RGB")
    if len({background.size, normal.size, docked.size}) != 1:
        raise SystemExit(f"{variant}: source images have different dimensions")
    W, H = background.size
    window = normal.crop(scaled(WINDOW, W))
    wx = round(WINDOW[0] * W / REGION[0]); wy = round(WINDOW[1] * H / REGION[1])
    ww = window.width; wh = window.height
    frames = []

    def add(image, count=1):
        frames.extend(image.copy() for _ in range(count))

    add(cursor(normal, (W * .45, H * .45)), FPS)
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        frame = background.copy()
        frame.paste(window, (round(lerp(wx, W - 1, t)), wy))
        add(cursor(frame, (W * .45, H * .45)))
    add(cursor(docked, (W * .8, H * .5)), FPS // 2)
    for i in range(16):
        t = i / 15
        add(cursor(docked, (lerp(W * .8, W - 8, t), lerp(H * .5, H * .5, t))), 1)
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        frame = docked.copy()
        frame.paste(window, (round(lerp(W - 1, W - ww, t)), wy))
        add(cursor(frame, (W - 12, H * .5)))
    add(cursor(normal, (W - ww / 2, H * .45)), FPS)
    for i in range(SLIDE_FRAMES):
        t = i / (SLIDE_FRAMES - 1)
        frame = background.copy()
        frame.paste(window, (round(lerp(W - ww, W - 1, t)), wy))
        add(cursor(frame, (lerp(W - 12, W * .65, t), H * .5)))
    add(cursor(docked, (W * .65, H * .5)), FPS // 2)

    out = WORK / variant
    out.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(frames):
        frame.save(out / f"{index:04d}.jpg", quality=91, optimize=True)
    shutil.copy2(normal, ASSETS / f"orbpeek-poster-{variant}.png")

    video = ASSETS / f"orbpeek-demo-{variant}.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-framerate", str(FPS), "-i", str(out / "%04d.jpg"),
        "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", str(video)
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    gif = ASSETS / f"demo-{variant}.gif"
    subprocess.run([
        "ffmpeg", "-y", "-i", str(video), "-filter_complex",
        "[0:v]fps=12,scale=960:-1:flags=lanczos,split[a][b];"
        "[a]palettegen=max_colors=96:stats_mode=diff[p];"
        "[b][p]paletteuse=dither=bayer:bayer_scale=4",
        "-loop", "0", str(gif)
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"{variant}: {len(frames)} frames, {video.name}={video.stat().st_size / 1e6:.2f}MB, "
          f"{gif.name}={gif.stat().st_size / 1e6:.2f}MB")
    if gif.stat().st_size > 3_000_000:
        print(f"warning: {gif} exceeds the 3MB target")


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    variants = [name for name in ("light", "dark") if (SOURCE / name).is_dir()]
    if not variants:
        raise SystemExit("No real captures found. Run Scripts/capture-demo.sh --trial first, "
                         "then capture light/dark sources with --capture.")
    for variant in variants:
        render_variant(variant)


if __name__ == "__main__":
    main()
