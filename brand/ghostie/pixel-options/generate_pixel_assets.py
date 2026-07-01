#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "assets"
LOOPS = ROOT / "loops"

GRID = 48
SCALE = 8
SPRITE_SIZE = GRID * SCALE

TRANSPARENT = (0, 0, 0, 0)
BLACK = (8, 10, 12, 255)
INK_SOFT = (34, 39, 45, 255)
OFF_WHITE = (248, 247, 239, 255)
WARM_WHITE = (255, 252, 244, 255)
GHOST_SHADE = (213, 226, 236, 255)
GHOST_BLUE = (143, 188, 219, 255)
GHOST_BLUE_DEEP = (92, 141, 178, 255)
GHOST_LOW = (226, 229, 222, 255)
MINT = (101, 220, 194, 255)
CORAL = (238, 82, 92, 255)
HONEY = (255, 207, 77, 255)
PLUM = (43, 33, 72, 255)
BLUE = (61, 166, 220, 255)
BLUE_DARK = (30, 89, 135, 255)
BLUE_LIGHT = (136, 218, 245, 255)
GREEN = (68, 188, 87, 255)
GREEN_DARK = (34, 109, 53, 255)
RED = (227, 45, 58, 255)
RED_DARK = (118, 28, 40, 255)
COFFEE = (136, 94, 58, 255)
STEAM = (177, 122, 79, 255)
GRID_LINE = (17, 17, 17, 34)


def body_pixels(frame: int = 0, jump: int = 0) -> set[tuple[int, int]]:
    rows: dict[int, list[tuple[int, int]]] = {
        5: [(21, 27)],
        6: [(19, 29)],
        7: [(18, 30)],
        8: [(16, 32)],
        9: [(15, 33)],
        10: [(14, 34)],
        11: [(13, 35)],
        12: [(12, 36)],
        13: [(11, 37)],
        14: [(11, 37)],
        15: [(11, 37)],
        16: [(11, 37)],
        17: [(11, 37)],
        18: [(11, 37)],
        19: [(11, 37)],
        20: [(11, 37)],
        21: [(11, 37)],
        22: [(11, 37)],
        23: [(11, 37)],
        24: [(11, 37)],
        25: [(11, 37)],
        26: [(11, 37)],
        27: [(11, 37)],
        28: [(11, 37)],
        29: [(11, 37)],
        30: [(11, 37)],
        31: [(11, 37)],
        32: [(11, 37)],
        33: [(11, 37)],
        34: [(11, 37)],
        35: [(11, 37)],
        36: [(11, 16), (18, 23), (25, 30), (32, 37)],
        37: [(11, 15), (19, 23), (26, 30), (33, 37)],
        38: [(12, 15), (20, 22), (27, 29), (34, 36)],
        39: [(12, 14), (20, 22), (27, 29), (35, 36)],
    }
    pixels: set[tuple[int, int]] = set()
    bob = 1 if frame == 1 else 0
    for y, spans in rows.items():
        yy = y - jump + (bob if y >= 33 else 0)
        for start, end in spans:
            for x in range(start, end + 1):
                if 0 <= x < GRID and 0 <= yy < GRID:
                    pixels.add((x, yy))
    return pixels


def outline_pixels(fill: set[tuple[int, int]], radius: int = 1) -> set[tuple[int, int]]:
    outline: set[tuple[int, int]] = set()
    for x, y in fill:
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                if dx == 0 and dy == 0:
                    continue
                p = (x + dx, y + dy)
                if 0 <= p[0] < GRID and 0 <= p[1] < GRID and p not in fill:
                    outline.add(p)
    return outline


def px(draw: ImageDraw.ImageDraw, x: int, y: int, color, scale: int = SCALE) -> None:
    draw.rectangle([x * scale, y * scale, (x + 1) * scale - 1, (y + 1) * scale - 1], fill=color)


def rect(draw: ImageDraw.ImageDraw, x0: int, y0: int, x1: int, y1: int, color, scale: int = SCALE) -> None:
    draw.rectangle([x0 * scale, y0 * scale, (x1 + 1) * scale - 1, (y1 + 1) * scale - 1], fill=color)


def line(draw: ImageDraw.ImageDraw, pts: list[tuple[int, int]], color) -> None:
    for x, y in pts:
        px(draw, x, y, color)


def draw_grid(draw: ImageDraw.ImageDraw, size: int, color=GRID_LINE) -> None:
    for i in range(GRID + 1):
        p = i * SCALE
        draw.line([p, 0, p, size], fill=color, width=1)
        draw.line([0, p, size, p], fill=color, width=1)


def row_edges(fill: set[tuple[int, int]]) -> dict[int, tuple[int, int]]:
    rows: dict[int, list[int]] = {}
    for x, y in fill:
        rows.setdefault(y, []).append(x)
    return {y: (min(xs), max(xs)) for y, xs in rows.items()}


def draw_body(draw: ImageDraw.ImageDraw, frame: int = 0, jump: int = 0, sleeping: bool = False) -> None:
    fill = body_pixels(frame=frame, jump=jump)
    for x, y in outline_pixels(fill, radius=1):
        px(draw, x, y, BLACK)
    for x, y in sorted(fill):
        px(draw, x, y, OFF_WHITE)

    edges = row_edges(fill)
    for y, (left, right) in edges.items():
        for x in range(left, right + 1):
            if (x, y) not in fill:
                continue
            if x <= left + 1 and 13 - jump <= y <= 34 - jump:
                px(draw, x, y, GHOST_BLUE)
            elif x <= left + 3 and 11 - jump <= y <= 35 - jump:
                px(draw, x, y, GHOST_SHADE)
            elif x >= right - 1 and 12 - jump <= y <= 32 - jump:
                px(draw, x, y, WARM_WHITE)
            elif y >= 37 - jump:
                px(draw, x, y, GHOST_LOW)

    if not sleeping:
        for x, y in [(12, 13 - jump), (13, 12 - jump), (14, 11 - jump), (15, 10 - jump), (16, 9 - jump)]:
            if (x, y) in fill:
                px(draw, x, y, GHOST_SHADE)


def draw_face(draw: ImageDraw.ImageDraw, expression: str = "neutral", jump: int = 0, sleeping: bool = False) -> None:
    dy = -jump
    if sleeping:
        rect(draw, 17, 22 + dy, 20, 22 + dy, BLACK)
        rect(draw, 29, 22 + dy, 32, 22 + dy, BLACK)
        px(draw, 23, 28 + dy, BLACK)
        px(draw, 24, 29 + dy, BLACK)
        px(draw, 25, 29 + dy, BLACK)
        px(draw, 26, 28 + dy, BLACK)
        return

    if expression == "angry":
        line(draw, [(16, 20 + dy), (17, 21 + dy), (18, 22 + dy), (19, 23 + dy)], BLACK)
        line(draw, [(32, 20 + dy), (31, 21 + dy), (30, 22 + dy), (29, 23 + dy)], BLACK)
        rect(draw, 18, 23 + dy, 20, 26 + dy, BLACK)
        rect(draw, 28, 23 + dy, 30, 26 + dy, BLACK)
        rect(draw, 22, 31 + dy, 28, 32 + dy, BLACK)
    else:
        rect(draw, 17, 21 + dy, 20, 25 + dy, BLACK)
        rect(draw, 29, 21 + dy, 32, 25 + dy, BLACK)
        if expression == "happy":
            rect(draw, 22, 30 + dy, 28, 31 + dy, BLACK)
            rect(draw, 24, 32 + dy, 26, 33 + dy, BLACK)
        elif expression == "thinking":
            rect(draw, 23, 29 + dy, 26, 30 + dy, BLACK)
            px(draw, 27, 31 + dy, BLACK)
        elif expression == "confused":
            rect(draw, 23, 29 + dy, 25, 30 + dy, BLACK)
            rect(draw, 16, 19 + dy, 20, 20 + dy, BLACK)
            px(draw, 30, 18 + dy, BLACK)
            px(draw, 31, 19 + dy, BLACK)
        else:
            rect(draw, 23, 29 + dy, 27, 30 + dy, BLACK)


def draw_default_arms(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    return


def draw_phone(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    phone_body = {
        18: (40, 45),
        19: (40, 46),
        20: (39, 46),
        21: (39, 46),
        22: (39, 46),
        23: (39, 46),
        24: (39, 45),
        25: (39, 45),
        26: (39, 45),
        27: (38, 44),
        28: (38, 44),
        29: (38, 44),
        30: (39, 43),
        31: (39, 43),
    }
    for y, (x0, x1) in phone_body.items():
        rect(draw, x0, y + dy, x1, y + dy, BLACK)

    phone_frame = {
        20: (40, 45),
        21: (40, 45),
        22: (40, 45),
        23: (40, 45),
        24: (40, 44),
        25: (40, 44),
        26: (40, 44),
        27: (39, 43),
        28: (39, 43),
        29: (39, 43),
    }
    for y, (x0, x1) in phone_frame.items():
        rect(draw, x0, y + dy, x1, y + dy, BLUE_DARK)

    phone_screen = {
        20: (42, 44),
        21: (41, 44),
        22: (41, 44),
        23: (41, 44),
        24: (40, 43),
        25: (40, 43),
        26: (40, 43),
        27: (39, 42),
        28: (39, 42),
    }
    for y, (x0, x1) in phone_screen.items():
        rect(draw, x0, y + dy, x1, y + dy, BLUE)

    line(draw, [(42, 20 + dy), (43, 20 + dy), (41, 21 + dy)], BLUE_LIGHT)
    rect(draw, 41, 29 + dy, 42, 29 + dy, BLACK)
    rect(draw, 37, 24 + dy, 40, 28 + dy, BLACK)
    rect(draw, 38, 25 + dy, 39, 27 + dy, OFF_WHITE)


def draw_wave_arm(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    rect(draw, 40, 21 + dy, 41, 27 + dy, BLACK)
    rect(draw, 42, 18 + dy, 43, 22 + dy, BLACK)
    rect(draw, 44, 16 + dy, 45, 18 + dy, BLACK)
    px(draw, 43, 17 + dy, OFF_WHITE)


def draw_thinking_hand(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    rect(draw, 20, 31 + dy, 22, 32 + dy, BLACK)
    rect(draw, 19, 33 + dy, 20, 35 + dy, BLACK)
    px(draw, 23, 30 + dy, BLACK)


def draw_thought(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    for x, y in [(37, 15), (38, 14), (39, 14), (40, 15), (40, 16), (39, 17), (38, 17), (37, 16)]:
        px(draw, x, y + dy, GHOST_BLUE)
    for x, y in [(42, 9), (43, 8), (44, 8), (45, 9), (46, 10), (46, 12), (45, 13), (44, 14), (42, 14), (41, 13), (40, 12), (40, 10), (41, 9)]:
        px(draw, x, y + dy, GHOST_BLUE)
    rect(draw, 42, 10 + dy, 44, 12 + dy, OFF_WHITE)
    px(draw, 43, 9 + dy, WARM_WHITE)


def draw_ribbons(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    ribbon_lines = [
        [(1, 23), (2, 23), (3, 23), (4, 23), (5, 24), (6, 24)],
        [(0, 29), (1, 29), (2, 29), (3, 30), (4, 30), (5, 30), (6, 31), (7, 31)],
        [(1, 36), (2, 36), (3, 35), (4, 35), (5, 34), (6, 34), (7, 33), (8, 33)],
        [(39, 23), (40, 23), (41, 24), (42, 24), (43, 24), (44, 25), (45, 25)],
        [(39, 29), (40, 29), (41, 30), (42, 30), (43, 31), (44, 31), (45, 32), (46, 32)],
        [(39, 35), (40, 35), (41, 35), (42, 34), (43, 34), (44, 34), (45, 33)],
        [(10, 29), (11, 29), (12, 29), (13, 29), (14, 29), (15, 29), (16, 29), (17, 29), (18, 29), (19, 29), (20, 29), (21, 29), (22, 29), (23, 29), (24, 29), (25, 29), (26, 29), (27, 29), (28, 29), (29, 29), (30, 29), (31, 29), (32, 29), (33, 29), (34, 29), (35, 29), (36, 29), (37, 29)],
    ]
    for pts in ribbon_lines:
        for x, y in pts:
            px(draw, x, y + dy, RED)
    rect(draw, 16, 30 + dy, 31, 31 + dy, RED_DARK)


def draw_hat(draw: ImageDraw.ImageDraw, kind: str, jump: int = 0) -> None:
    dy = -jump
    if kind == "top":
        rect(draw, 15, 11 + dy, 33, 13 + dy, BLACK)
        rect(draw, 18, 4 + dy, 29, 12 + dy, BLACK)
        rect(draw, 19, 5 + dy, 28, 10 + dy, PLUM)
        rect(draw, 19, 11 + dy, 28, 12 + dy, BLUE)
        rect(draw, 15, 13 + dy, 33, 13 + dy, BLUE_DARK)
    elif kind == "cap":
        rect(draw, 14, 12 + dy, 32, 15 + dy, BLACK)
        rect(draw, 16, 9 + dy, 30, 13 + dy, BLACK)
        rect(draw, 17, 10 + dy, 29, 13 + dy, RED)
        rect(draw, 30, 13 + dy, 39, 14 + dy, BLACK)
        rect(draw, 30, 14 + dy, 38, 15 + dy, RED)
        rect(draw, 25, 10 + dy, 27, 11 + dy, (255, 135, 138, 255))


def draw_headphones(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    rect(draw, 7, 20 + dy, 10, 30 + dy, BLACK)
    rect(draw, 38, 20 + dy, 41, 30 + dy, BLACK)
    rect(draw, 11, 14 + dy, 37, 16 + dy, BLACK)
    rect(draw, 13, 12 + dy, 35, 14 + dy, GREEN_DARK)
    rect(draw, 14, 13 + dy, 34, 14 + dy, GREEN)
    rect(draw, 8, 21 + dy, 10, 29 + dy, GREEN)
    rect(draw, 38, 21 + dy, 40, 29 + dy, GREEN)
    px(draw, 9, 22 + dy, MINT)
    px(draw, 39, 22 + dy, MINT)


def draw_coffee(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    rect(draw, 40, 24 + dy, 45, 36 + dy, BLACK)
    rect(draw, 41, 25 + dy, 44, 35 + dy, COFFEE)
    rect(draw, 41, 25 + dy, 44, 27 + dy, (235, 218, 181, 255))
    rect(draw, 45, 28 + dy, 47, 31 + dy, BLACK)
    rect(draw, 46, 29 + dy, 46, 30 + dy, OFF_WHITE)
    for pts in [[(41, 18), (42, 17), (42, 16)], [(44, 18), (45, 17), (45, 16)], [(43, 20), (44, 19), (44, 18)]]:
        for x, y in pts:
            px(draw, x, y + dy, STEAM)


def draw_sleep_marks(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    rect(draw, 34, 9 + dy, 38, 10 + dy, BLACK)
    px(draw, 38, 11 + dy, BLACK)
    px(draw, 37, 12 + dy, BLACK)
    rect(draw, 34, 13 + dy, 38, 14 + dy, BLACK)
    rect(draw, 30, 15 + dy, 33, 16 + dy, BLACK)
    px(draw, 33, 17 + dy, BLACK)
    rect(draw, 30, 18 + dy, 33, 19 + dy, BLACK)


def draw_glitch(draw: ImageDraw.ImageDraw, jump: int = 0) -> None:
    dy = -jump
    for x, y in [(5, 18), (6, 18), (42, 19), (43, 19), (3, 28), (4, 28), (5, 29), (42, 31), (43, 31), (44, 32), (7, 38), (8, 38), (38, 38), (39, 39)]:
        px(draw, x, y + dy, RED)
    for x, y in [(6, 19), (7, 19), (41, 20), (42, 20), (5, 30), (6, 30), (40, 37), (41, 37)]:
        px(draw, x, y + dy, BLUE)


def draw_sprite(
    name: str,
    expression: str = "neutral",
    phone: bool = False,
    wave: bool = False,
    hat: str | None = None,
    headphones: bool = False,
    thinking: bool = False,
    ribbons: bool = False,
    coffee: bool = False,
    sleeping: bool = False,
    frame: int = 0,
    jump: int = 0,
    grid: bool = False,
) -> Image.Image:
    size = GRID * SCALE
    img = Image.new("RGBA", (size, size), TRANSPARENT)
    draw = ImageDraw.Draw(img)
    if grid:
        draw_grid(draw, size)

    draw_body(draw, frame=frame, jump=jump, sleeping=sleeping)

    if wave:
        draw_wave_arm(draw, jump=jump)
    elif thinking:
        draw_thinking_hand(draw, jump=jump)
        px(draw, 41, 27 - jump, BLACK)
    elif phone:
        px(draw, 6, 27 - jump, BLACK)
        draw_phone(draw, jump=jump)
    elif coffee:
        px(draw, 6, 27 - jump, BLACK)
        draw_coffee(draw, jump=jump)
    else:
        draw_default_arms(draw, jump=jump)

    if hat:
        draw_hat(draw, hat, jump=jump)
    if headphones:
        draw_headphones(draw, jump=jump)
    if thinking:
        draw_thought(draw, jump=jump)
    if ribbons:
        draw_ribbons(draw, jump=jump)
    if expression == "angry":
        draw_glitch(draw, jump=jump)
    if sleeping:
        draw_sleep_marks(draw, jump=jump)

    draw_face(draw, expression, jump=jump, sleeping=sleeping)
    return img


def save_sprite(img: Image.Image, path: Path) -> None:
    img.save(path)


def save_gif(frames: list[Image.Image], path: Path, duration: int = 120) -> None:
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=duration, loop=0, disposal=2)


def make_app_icon() -> None:
    base = Image.new("RGBA", (1024, 1024), (255, 248, 241, 255))
    draw = ImageDraw.Draw(base)
    cell = 64
    for y in range(0, 1024, cell):
        draw.line([0, y, 1024, y], fill=(229, 220, 212, 255), width=4)
    for x in range(0, 1024, cell):
        draw.line([x, 0, x, 1024], fill=(229, 220, 212, 255), width=4)
    draw.rectangle([88, 88, 936, 936], outline=BLACK, width=18)
    draw.rectangle([110, 110, 958, 958], outline=(17, 17, 17, 255), width=8)
    sprite = draw_sprite("icon", expression="happy", phone=True)
    sprite = sprite.resize((704, 704), Image.Resampling.NEAREST)
    base.alpha_composite(sprite, (160, 182))
    base.save(ASSETS / "ghostie-pixel-app-icon.png")


def make_contact_sheet(sprites: list[Image.Image]) -> None:
    cols = 4
    rows = 3
    sheet = Image.new("RGBA", (SPRITE_SIZE * cols, SPRITE_SIZE * rows), TRANSPARENT)
    for i, sprite in enumerate(sprites):
        x = (i % cols) * SPRITE_SIZE
        y = (i // cols) * SPRITE_SIZE
        sheet.alpha_composite(sprite, (x, y))
    sheet.save(ASSETS / "ghostie-pixel-sprite-sheet.png")

    contact = Image.new("RGBA", sheet.size, (255, 248, 241, 255))
    cdraw = ImageDraw.Draw(contact)
    for y in range(0, contact.height + 1, SCALE):
        cdraw.line([0, y, contact.width, y], fill=GRID_LINE, width=1)
    for x in range(0, contact.width + 1, SCALE):
        cdraw.line([x, 0, x, contact.height], fill=GRID_LINE, width=1)
    contact.alpha_composite(sheet)
    contact.save(ASSETS / "ghostie-pixel-contact-sheet.png")


def make_assets() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    LOOPS.mkdir(parents=True, exist_ok=True)
    for path in list(ASSETS.glob("*.png")) + list(LOOPS.glob("*.gif")):
        path.unlink()

    variants = [
        ("ghostie-idle", dict(expression="neutral")),
        ("ghostie-happy", dict(expression="happy")),
        ("ghostie-wave", dict(expression="happy", wave=True)),
        ("ghostie-phone", dict(expression="neutral", phone=True)),
        ("ghostie-thinking", dict(expression="thinking", thinking=True)),
        ("ghostie-confused", dict(expression="confused", thinking=True)),
        ("ghostie-top-hat", dict(expression="neutral", hat="top")),
        ("ghostie-cap", dict(expression="neutral", hat="cap")),
        ("ghostie-ribbon", dict(expression="neutral", ribbons=True)),
        ("ghostie-headphones", dict(expression="neutral", headphones=True)),
        ("ghostie-approval", dict(expression="happy", ribbons=True)),
        ("ghostie-angry", dict(expression="angry")),
    ]
    sprites: list[Image.Image] = []
    for name, kwargs in variants:
        sprite = draw_sprite(name, **kwargs)
        save_sprite(sprite, ASSETS / f"{name}.png")
        sprites.append(sprite)

    save_sprite(draw_sprite("ghostie-sleepy", sleeping=True), ASSETS / "ghostie-sleepy.png")
    save_sprite(draw_sprite("ghostie-coffee", coffee=True), ASSETS / "ghostie-coffee.png")
    make_contact_sheet(sprites)

    idle_frames = [
        draw_sprite("idle", expression="neutral", frame=0),
        draw_sprite("idle", expression="neutral", frame=1),
        draw_sprite("idle", expression="neutral", frame=0),
        draw_sprite("idle", expression="happy", frame=0),
    ]
    save_gif(idle_frames, LOOPS / "ghostie-idle-bob.gif", duration=180)

    walk_frames = [
        draw_sprite("walk", expression="neutral", frame=0),
        draw_sprite("walk", expression="neutral", frame=1),
        draw_sprite("walk", expression="neutral", frame=0),
        draw_sprite("walk", expression="happy", frame=1),
    ]
    save_gif(walk_frames, LOOPS / "ghostie-walk-cycle.gif", duration=130)

    approve_frames = [
        draw_sprite("approve", expression="neutral"),
        draw_sprite("approve", expression="happy", jump=2, ribbons=True),
        draw_sprite("approve", expression="happy", jump=1, ribbons=True),
        draw_sprite("approve", expression="happy", jump=0, ribbons=True),
    ]
    save_gif(approve_frames, LOOPS / "ghostie-approval-pop.gif", duration=140)
    make_app_icon()


if __name__ == "__main__":
    make_assets()
