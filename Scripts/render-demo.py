#!/usr/bin/env python3
"""Render the light and dark OrbPeek schematic demos (requires Pillow)."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

WIDTH, HEIGHT = 960, 600
FPS = 12
SECONDS = 7
WINDOW = (190, 104, 740, 410)
DOCKED_X = WIDTH - 15

SCHEMES = {
    "light": {
        "top": (239, 244, 252),
        "bottom": (218, 228, 246),
        "blob_a": (167, 199, 248, 105),
        "blob_b": (207, 180, 241, 90),
        "menubar": (250, 252, 255, 205),
        "menu_ink": (101, 113, 136, 150),
        "window": (249, 250, 253, 255),
        "title": (244, 246, 250, 255),
        "sidebar": (235, 239, 247, 255),
        "content": (249, 250, 253, 255),
        "card": (255, 255, 255, 255),
        "line": (190, 199, 216, 255),
        "muted": (218, 224, 235, 255),
        "accent": (93, 125, 239, 255),
        "accent_soft": (219, 228, 253, 255),
        "border": (154, 167, 191, 85),
        "shadow": (52, 67, 99, 65),
    },
    "dark": {
        "top": (28, 33, 48),
        "bottom": (19, 24, 38),
        "blob_a": (57, 88, 153, 105),
        "blob_b": (91, 61, 130, 90),
        "menubar": (24, 29, 43, 205),
        "menu_ink": (179, 190, 214, 145),
        "window": (35, 40, 54, 255),
        "title": (42, 47, 62, 255),
        "sidebar": (30, 35, 48, 255),
        "content": (35, 40, 54, 255),
        "card": (43, 49, 65, 255),
        "line": (104, 117, 143, 255),
        "muted": (65, 74, 94, 255),
        "accent": (127, 153, 250, 255),
        "accent_soft": (57, 70, 108, 255),
        "border": (145, 158, 185, 65),
        "shadow": (0, 0, 0, 100),
    },
}


def ease(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3 - 2 * value)


def ramp(t, start, end):
    return ease((t - start) / (end - start))


def lerp(a, b, amount):
    return a + (b - a) * amount


def background(colors):
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT):
        amount = y / (HEIGHT - 1)
        rgb = tuple(round(lerp(a, b, amount)) for a, b in zip(colors["top"], colors["bottom"]))
        draw.line((0, y, WIDTH, y), fill=rgb + (255,))

    blobs = Image.new("RGBA", image.size)
    blob_draw = ImageDraw.Draw(blobs)
    blob_draw.ellipse((-130, 65, 500, 590), fill=colors["blob_a"])
    blob_draw.ellipse((570, -160, 1120, 390), fill=colors["blob_b"])
    blobs = blobs.filter(ImageFilter.GaussianBlur(85))
    image = Image.alpha_composite(image, blobs)

    chrome = Image.new("RGBA", image.size)
    chrome_draw = ImageDraw.Draw(chrome)
    chrome_draw.rectangle((0, 0, WIDTH, 30), fill=colors["menubar"])
    for x in (24, 42, 60):
        chrome_draw.ellipse((x - 4, 11, x + 4, 19), fill=colors["menu_ink"])
    for x in (840, 862, 884, 916):
        chrome_draw.rounded_rectangle((x, 12, x + 10, 18), radius=3, fill=colors["menu_ink"])
    return Image.alpha_composite(image, chrome)


def window_surface(colors):
    _, _, w, h = WINDOW
    margin = 26
    surface = Image.new("RGBA", (w + margin * 2, h + margin * 2))

    shadow = Image.new("RGBA", surface.size)
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (margin, margin + 4, margin + w, margin + h + 4),
        radius=17,
        fill=colors["shadow"],
    )
    surface = Image.alpha_composite(surface, shadow.filter(ImageFilter.GaussianBlur(15)))

    body = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(body)
    draw.rounded_rectangle((0, 0, w - 1, h - 1), radius=15, fill=colors["window"])
    draw.rounded_rectangle((0, 0, w - 1, 57), radius=15, fill=colors["title"])
    draw.rectangle((0, 40, w - 1, 57), fill=colors["title"])
    draw.rectangle((0, 57, 157, h - 1), fill=colors["sidebar"])
    draw.rectangle((158, 57, w - 1, h - 1), fill=colors["content"])

    for x, color in ((20, (255, 96, 88, 255)), (41, (255, 189, 68, 255)), (62, (52, 199, 89, 255))):
        draw.ellipse((x, 23, x + 11, 34), fill=color)
    draw.rounded_rectangle((108, 24, 208, 33), radius=4, fill=colors["muted"])
    draw.rounded_rectangle((w - 71, 22, w - 28, 35), radius=6, fill=colors["muted"])

    draw.rounded_rectangle((20, 81, 134, 118), radius=9, fill=colors["accent_soft"])
    draw.ellipse((31, 93, 42, 104), fill=colors["accent"])
    draw.rounded_rectangle((52, 94, 116, 102), radius=4, fill=colors["accent"])
    for y, length in ((143, 96), (181, 110), (219, 83), (257, 102), (333, 88), (371, 106)):
        draw.ellipse((29, y, 37, y + 8), fill=colors["line"])
        draw.rounded_rectangle((48, y + 1, 48 + length, y + 7), radius=3, fill=colors["line"])

    draw.rounded_rectangle((184, 82, w - 26, 213), radius=13, fill=colors["card"])
    draw.ellipse((207, 105, 253, 151), fill=colors["accent_soft"])
    draw.ellipse((219, 117, 241, 139), fill=colors["accent"])
    draw.rounded_rectangle((274, 106, 443, 118), radius=5, fill=colors["line"])
    draw.rounded_rectangle((274, 135, 388, 144), radius=4, fill=colors["muted"])
    for index, bar_height in enumerate((28, 48, 37, 65, 53, 76)):
        x = 470 + index * 29
        draw.rounded_rectangle(
            (x, 188 - bar_height, x + 16, 188), radius=5,
            fill=colors["accent"] if index == 5 else colors["accent_soft"],
        )

    for x, width in ((184, 244), (445, w - 471)):
        draw.rounded_rectangle((x, 232, x + width, 374), radius=13, fill=colors["card"])
        draw.rounded_rectangle((x + 20, 253, x + width - 20, 262), radius=4, fill=colors["muted"])
        for row, ratio in enumerate((0.82, 0.64, 0.74)):
            y = 286 + row * 23
            draw.rounded_rectangle(
                (x + 20, y, x + 20 + (width - 40) * ratio, y + 8),
                radius=4,
                fill=colors["line"],
            )

    # Keep the rounded silhouette while clipping every child layer to it.
    mask = Image.new("L", (w, h))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=15, fill=255)
    body.putalpha(mask)
    surface.alpha_composite(body, (margin, margin))

    outline = ImageDraw.Draw(surface)
    outline.rounded_rectangle(
        (margin, margin, margin + w - 1, margin + h - 1),
        radius=15,
        outline=colors["border"],
        width=1,
    )
    return surface


def cursor_layer(x, y):
    layer = Image.new("RGBA", (WIDTH, HEIGHT))
    points = [(x, y), (x + 1, y + 29), (x + 8, y + 22), (x + 15, y + 36),
              (x + 21, y + 32), (x + 14, y + 19), (x + 25, y + 17)]
    shadow = [(px + 2, py + 3) for px, py in points]
    draw = ImageDraw.Draw(layer)
    draw.polygon(shadow, fill=(0, 0, 0, 65))
    draw.polygon(points, fill=(250, 252, 255, 255), outline=(32, 38, 50, 255))
    draw.line(points + [points[0]], fill=(32, 38, 50, 255), width=2, joint="curve")
    return layer


def render(scheme, output):
    colors = SCHEMES[scheme]
    desktop = background(colors)
    app_window = window_surface(colors)
    normal_x, y, _, _ = WINDOW
    frames = []

    for frame_index in range(FPS * SECONDS):
        t = frame_index / FPS
        docking = ramp(t, 0.8, 1.7)
        revealing = ramp(t, 2.8, 3.7)
        hiding = ramp(t, 5.2, 6.1)
        visibility = revealing * (1 - hiding)
        x = lerp(normal_x, DOCKED_X, docking * (1 - visibility))

        pointer_to_edge = ramp(t, 2.0, 2.8)
        pointer_away = ramp(t, 4.5, 5.2)
        pointer_amount = pointer_to_edge * (1 - pointer_away)
        pointer_x = lerp(690, 943, pointer_amount)
        pointer_y = lerp(510, 280, pointer_amount)

        frame = desktop.copy()
        frame.alpha_composite(app_window, (round(x) - 26, y - 26))

        if 2.72 < t < 3.85:
            glow = Image.new("RGBA", frame.size)
            glow_draw = ImageDraw.Draw(glow)
            alpha = round(180 * min(ramp(t, 2.72, 2.9), 1 - ramp(t, 3.65, 3.85)))
            glow_draw.rounded_rectangle((952, y + 8, 958, y + 402), radius=3,
                                        fill=colors["accent"][:3] + (alpha,))
            frame = Image.alpha_composite(frame, glow)

        frame = Image.alpha_composite(frame, cursor_layer(pointer_x, pointer_y))
        frames.append(frame.convert("RGB"))

    frames[0].save(
        output,
        save_all=True,
        append_images=frames[1:],
        duration=round(1000 / FPS),
        loop=0,
        optimize=True,
        disposal=2,
    )


def main():
    output_dir = Path(__file__).resolve().parents[1] / "docs" / "assets"
    output_dir.mkdir(parents=True, exist_ok=True)
    for scheme in SCHEMES:
        output = output_dir / f"demo-{scheme}.gif"
        render(scheme, output)
        print(output.relative_to(output_dir.parents[1]))


if __name__ == "__main__":
    main()
