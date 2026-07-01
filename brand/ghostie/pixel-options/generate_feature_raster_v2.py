#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
RASTER = ROOT / "raster"
FEATURES = RASTER / "features"

BLACK = (18, 18, 18, 255)
PAPER = (255, 248, 241, 255)
TRANSPARENT = (255, 255, 255, 0)
BLUE = (70, 169, 223, 255)
BLUE_DARK = (39, 63, 82, 255)
CYAN = (76, 206, 235, 255)
MINT = (139, 232, 205, 255)
GREEN = (67, 204, 117, 255)
CORAL = (255, 93, 102, 255)
RED = (229, 48, 65, 255)
HONEY = (255, 207, 77, 255)
PLUM = (43, 33, 72, 255)
SHADOW = (201, 216, 226, 255)
COFFEE = (143, 92, 55, 255)


def is_barrier(px: tuple[int, int, int, int]) -> bool:
    r, g, b, a = px
    return (r < 80 and g < 90 and b < 100) or (b > 130 and g > 95 and r < 130)


def cutout_reference(src: Path, out: Path, padded: Path | None = None, pad: int = 56) -> Image.Image:
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    pix = im.load()

    seen: set[tuple[int, int]] = set()
    stack: list[tuple[int, int]] = []
    for x in range(w):
        stack.append((x, 0))
        stack.append((x, h - 1))
    for y in range(h):
        stack.append((0, y))
        stack.append((w - 1, y))

    while stack:
        x, y = stack.pop()
        if (x, y) in seen or x < 0 or y < 0 or x >= w or y >= h:
            continue
        if is_barrier(pix[x, y]):
            continue
        seen.add((x, y))
        stack.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    for x, y in seen:
        pix[x, y] = TRANSPARENT

    # Remove tiny grid remnants that are adjacent to transparency.
    for _ in range(3):
        to_clear: list[tuple[int, int]] = []
        for y in range(1, h - 1):
            for x in range(1, w - 1):
                r, g, b, a = pix[x, y]
                if a == 0:
                    continue
                gray_grid = abs(r - g) < 18 and abs(g - b) < 18 and 120 < r < 245
                pale_paper = r > 226 and g > 226 and b > 226
                if (gray_grid or pale_paper) and any(
                    pix[nx, ny][3] == 0 for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1))
                ):
                    to_clear.append((x, y))
        for x, y in to_clear:
            pix[x, y] = TRANSPARENT

    # Keep the largest connected foreground component.
    seen.clear()
    comps: list[list[tuple[int, int]]] = []
    for y in range(h):
        for x in range(w):
            if (x, y) in seen or pix[x, y][3] == 0:
                continue
            comp: list[tuple[int, int]] = []
            stack = [(x, y)]
            seen.add((x, y))
            while stack:
                cx, cy = stack.pop()
                comp.append((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in seen and pix[nx, ny][3] != 0:
                        seen.add((nx, ny))
                        stack.append((nx, ny))
            comps.append(comp)

    main = max(comps, key=len)
    clean = Image.new("RGBA", (w, h), TRANSPARENT)
    cp = clean.load()
    for x, y in main:
        cp[x, y] = pix[x, y]
    clean.save(out)

    if padded:
        xs = [x for x, _ in main]
        ys = [y for _, y in main]
        crop = clean.crop((min(xs), min(ys), max(xs) + 1, max(ys) + 1))
        canvas = Image.new("RGBA", (crop.width + pad * 2, crop.height + pad * 2), TRANSPARENT)
        canvas.alpha_composite(crop, (pad, pad))
        canvas.save(padded)

    return clean


def remove_top_center_artifact(path: Path) -> None:
    im = Image.open(path).convert("RGBA")
    bbox = im.getbbox()
    if not bbox:
        im.save(path)
        return
    left, top, right, _bottom = bbox
    center = (left + right) // 2
    pix = im.load()
    for y in range(top, min(top + 18, im.height)):
        for x in range(center - 3, center + 4):
            if 0 <= x < im.width:
                pix[x, y] = TRANSPARENT
    im.save(path)


def resize_base(im: Image.Image, height: int = 176) -> Image.Image:
    im = im.copy()
    bbox = im.getbbox()
    if bbox:
        im = im.crop(bbox)
    ratio = height / im.height
    return im.resize((round(im.width * ratio), height), Image.Resampling.NEAREST)


def new_card() -> Image.Image:
    return Image.new("RGBA", (360, 360), TRANSPARENT)


def paste_base(card: Image.Image, base: Image.Image, x: int = 96, y: int = 92) -> None:
    card.alpha_composite(base, (x, y))


def chunky_line(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], fill=BLACK, width: int = 6) -> None:
    draw.line(points, fill=fill, width=width, joint="curve")


def rect(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], fill, outline=BLACK, width: int = 5) -> None:
    draw.rectangle(xy, fill=fill, outline=outline, width=width)


def circle(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], fill, outline=BLACK, width: int = 5) -> None:
    draw.ellipse(xy, fill=fill, outline=outline, width=width)


def draw_phone_badge(draw: ImageDraw.ImageDraw) -> None:
    circle(draw, (253, 121, 273, 141), CORAL, BLACK, 4)


def draw_wave(draw: ImageDraw.ImageDraw) -> None:
    chunky_line(draw, [(85, 176), (60, 152), (55, 130)], BLACK, 8)
    chunky_line(draw, [(83, 176), (62, 153), (57, 132)], (248, 249, 250, 255), 4)


def draw_party_hat(draw: ImageDraw.ImageDraw) -> None:
    draw.polygon([(143, 74), (172, 76), (156, 35)], fill=CORAL, outline=BLACK)
    draw.line([(144, 74), (172, 76), (156, 35), (144, 74)], fill=BLACK, width=5)
    draw.polygon([(151, 57), (164, 58), (157, 43)], fill=CYAN)
    circle(draw, (149, 27, 164, 42), HONEY, BLACK, 4)


def draw_cupcake(draw: ImageDraw.ImageDraw) -> None:
    rect(draw, (244, 204, 284, 242), COFFEE, BLACK, 5)
    draw.polygon([(238, 204), (250, 181), (277, 181), (290, 204)], fill=(255, 169, 191, 255), outline=BLACK)
    draw.line([(264, 170), (264, 184)], fill=BLACK, width=4)
    draw.line([(264, 167), (271, 156)], fill=HONEY, width=5)


def draw_tone_meter(draw: ImageDraw.ImageDraw) -> None:
    rect(draw, (236, 156, 286, 206), (255, 255, 255, 255), BLACK, 5)
    circle(draw, (250, 166, 272, 188), CORAL, BLACK, 3)
    chunky_line(draw, [(246, 197), (255, 192), (264, 197), (275, 188)], CYAN, 4)


def draw_draft_card(draw: ImageDraw.ImageDraw) -> None:
    rect(draw, (233, 150, 287, 200), (255, 255, 255, 255), BLACK, 5)
    draw.line([(245, 166), (273, 166)], fill=SHADOW, width=4)
    draw.line([(245, 180), (266, 180)], fill=SHADOW, width=4)
    chunky_line(draw, [(278, 145), (300, 122)], HONEY, 8)
    chunky_line(draw, [(282, 148), (304, 125)], BLACK, 3)


def draw_approval(draw: ImageDraw.ImageDraw) -> None:
    rect(draw, (234, 150, 292, 205), (255, 255, 255, 255), BLACK, 5)
    chunky_line(draw, [(246, 180), (259, 193), (282, 162)], GREEN, 7)


def draw_ribbon(draw: ImageDraw.ImageDraw) -> None:
    chunky_line(draw, [(56, 211), (122, 197), (197, 201), (268, 179)], CORAL, 7)
    chunky_line(draw, [(58, 213), (122, 199), (197, 203), (270, 181)], RED, 3)
    draw.polygon([(84, 203), (60, 185), (55, 214), (79, 223)], fill=CORAL, outline=BLACK)
    draw.polygon([(92, 203), (117, 188), (113, 220), (89, 223)], fill=CORAL, outline=BLACK)
    for x, y in [(58, 143), (81, 130), (284, 135), (300, 221), (74, 258)]:
        rect(draw, (x, y, x + 7, y + 7), CORAL, None, 0)


def draw_magnifier(draw: ImageDraw.ImageDraw) -> None:
    circle(draw, (238, 148, 285, 195), (218, 236, 245, 255), BLACK, 5)
    chunky_line(draw, [(276, 187), (304, 215)], BLACK, 7)
    chunky_line(draw, [(277, 187), (301, 211)], BLUE_DARK, 3)


def draw_voice(draw: ImageDraw.ImageDraw) -> None:
    circle(draw, (239, 158, 270, 189), BLUE_DARK, BLACK, 5)
    chunky_line(draw, [(276, 174), (286, 166), (286, 194), (276, 186)], BLUE, 5)
    for i, h in enumerate([14, 24, 34]):
        x = 300 + i * 12
        chunky_line(draw, [(x, 176 - h // 2), (x, 176 + h // 2)], CYAN, 4)


def draw_clock_gear(draw: ImageDraw.ImageDraw) -> None:
    circle(draw, (239, 130, 286, 177), (255, 255, 255, 255), BLACK, 5)
    chunky_line(draw, [(263, 153), (263, 139), (275, 153)], BLUE_DARK, 4)
    rect(draw, (238, 201, 291, 244), (255, 255, 255, 255), BLACK, 5)
    chunky_line(draw, [(249, 224), (260, 235), (280, 209)], GREEN, 6)


def draw_headphones_key(draw: ImageDraw.ImageDraw) -> None:
    chunky_line(draw, [(104, 132), (118, 93), (166, 80), (212, 93), (228, 132)], GREEN, 9)
    rect(draw, (83, 130, 111, 184), GREEN, BLACK, 5)
    rect(draw, (222, 130, 250, 184), GREEN, BLACK, 5)
    rect(draw, (252, 173, 316, 214), (24, 35, 43, 255), BLACK, 5)
    circle(draw, (266, 184, 280, 198), MINT, None, 0)
    chunky_line(draw, [(280, 191), (304, 191)], MINT, 4)
    chunky_line(draw, [(298, 191), (298, 184)], MINT, 4)


FEATURES_DEF = [
    ("dont-ghost", "Don't Ghost", "Quiet-thread nudges", "phone", (draw_wave, draw_phone_badge)),
    ("birthday", "Birthdays", "Remember the day", "idle", (draw_party_hat, draw_cupcake)),
    ("tone-check", "Tone Check", "Read the room", "idle", (draw_tone_meter,)),
    ("drafts", "Drafts", "Ghostwrites replies", "idle", (draw_draft_card,)),
    ("approval", "Approval", "Nothing sends alone", "idle", (draw_approval,)),
    ("wrapped", "Wrapped", "Your texting recap", "idle", (draw_ribbon,)),
    ("deep-read", "Deep Read", "Patterns with context", "idle", (draw_magnifier,)),
    ("texting-voice", "Style", "Your style profile", "idle", (draw_voice,)),
    ("automations", "Automations", "Scheduled, approved", "idle", (draw_clock_gear,)),
    ("power-byok", "Power BYOK", "Your key, your rules", "idle", (draw_headphones_key,)),
]


def save_feature_assets() -> None:
    FEATURES.mkdir(parents=True, exist_ok=True)
    idle_clean = RASTER / "ghostie-idle-reference-cutout-clean.png"
    idle_padded = RASTER / "ghostie-idle-reference-cutout-padded.png"
    cutout_reference(ROOT / "reference" / "idle-reference.png", idle_clean, idle_padded)
    remove_top_center_artifact(idle_clean)
    remove_top_center_artifact(idle_padded)

    idle_base = resize_base(Image.open(idle_padded).convert("RGBA"), 176)
    phone_base = resize_base(Image.open(RASTER / "ghostie-idle-phone-reference-cutout-padded.png").convert("RGBA"), 176)
    bases = {"idle": idle_base, "phone": phone_base}

    for slug, _title, _caption, base_key, drawers in FEATURES_DEF:
        card = new_card()
        base = bases[base_key]
        paste_base(card, base, x=94, y=92)
        draw = ImageDraw.Draw(card)
        for drawer in drawers:
            drawer(draw)
        card.save(FEATURES / f"ghostie-feature-{slug}-v2.png")


def contact_sheet() -> None:
    items = [(title, caption, f"ghostie-feature-{slug}-v2.png") for slug, title, caption, *_ in FEATURES_DEF]
    thumb = 220
    pad = 28
    label_h = 56
    cols = 5
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (thumb + pad) + pad, rows * (thumb + label_h + pad) + pad), PAPER)
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 18)
        small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
    except Exception:
        font = None
        small = None

    for i, (title, caption, file) in enumerate(items):
        row = i // cols
        col = i % cols
        x = pad + col * (thumb + pad)
        y = pad + row * (thumb + label_h + pad)
        draw.rectangle([x, y, x + thumb, y + thumb], fill=(255, 255, 255), outline=BLACK, width=3)
        im = Image.open(FEATURES / file).convert("RGBA")
        im.thumbnail((thumb - 26, thumb - 26), Image.Resampling.LANCZOS)
        sheet.paste(im, (x + (thumb - im.width) // 2, y + (thumb - im.height) // 2), im)
        draw.text((x, y + thumb + 10), title, fill=BLACK, font=font)
        draw.text((x, y + thumb + 34), caption, fill=(81, 73, 93), font=small)

    sheet.save(FEATURES / "ghostie-feature-contact-sheet-v2.png")


def main() -> None:
    save_feature_assets()
    contact_sheet()


if __name__ == "__main__":
    main()
