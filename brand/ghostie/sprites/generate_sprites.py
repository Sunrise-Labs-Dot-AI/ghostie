#!/usr/bin/env python3
"""Ghostie pixel sprite generator.

Every sprite is an ASCII pixel map; one char = one logical pixel.
Renders crisp PNGs at integer scales (nearest neighbor by construction)
plus pixel-rect SVGs. Deterministic: no AI fuzz, no anti-aliasing.
"""
from PIL import Image
import pathlib

OUT = pathlib.Path(__file__).parent / "out"

PALETTE = {
    ".": None,                  # transparent
    "#": (20, 20, 22, 255),     # ink outline
    "w": (252, 250, 246, 255),  # body near-white warm
    "b": (199, 217, 238, 255),  # left highlight / shade blue
    "P": (88, 168, 232, 255),   # phone screen blue
    "p": (46, 111, 168, 255),   # phone dark edge
    "r": (224, 68, 56, 255),    # red accent (cap / heart)
    "g": (76, 175, 80, 255),    # green accent (headphones)
    "h": (255, 214, 109, 255),  # honey accent (approval badge)
    "H": (224, 163, 35, 255),   # honey deep (badge check)
    "c": (255, 142, 126, 255),  # coral cheek
    "o": (242, 140, 48, 255),   # orange knit (fisherman's beanie)
    "O": (198, 96, 24, 255),    # burnt orange (beanie folded cuff)
    "q": (255, 178, 92, 255),   # light orange (knit highlight / ribbing)
    "e": (40, 36, 46, 255),     # eye ink (slightly softer than outline)
    "n": (224, 122, 30, 255),   # mid orange (beanie shade between o and O)
}

# Canonical idle body v2: 18 wide x 22 tall (higher density per the approved
# reference). Outline 1px ink, blue strip hugging the inner left edge,
# 2x2 eyes rows 9-10, mouth row 13, four pointy drips rows 19-21.
IDLE = [
    "......######......",
    "....##wwwwww##....",
    "...#wwwwwwwwww#...",
    "..#wwwwwwwwwwww#..",
    ".#wwwwwwwwwwwwww#.",
    ".#bwwwwwwwwwwwww#.",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwww##wwww##wwww#",
    "#bwww##wwww##wwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwww##wwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwww#www#www#www#",
    "#www#.#w#.#w#.#ww#",
    ".###...#...#...##.",
]

def to_grid(rows, width):
    return [list(r.ljust(width, ".")) for r in rows]


def paint_diag_phone(grid, u0, v0, thickness, length):
    """Paint a 2:1-stair tilted phone (edge-connected steps, no diagonal gaps).
    u = x + 2y indexes the cross-section, v = 2x - y the long axis.
    Outer 2 u-units on each side are outline, the 2 units inside the lower
    outline are the dark edge, ends capped 2 v-units deep."""
    h, w = len(grid), len(grid[0])
    for y in range(h):
        for x in range(w):
            band = (x + 2 * y) - u0
            v = (2 * x - y) - v0
            if 0 <= band < thickness and 0 <= v < length:
                if band < 2 or band >= thickness - 2 or v < 2 or v >= length - 2:
                    ch = "#"
                elif band >= thickness - 4:
                    ch = "p"
                elif band < 4 and length - 8 <= v < length - 4:
                    ch = "w"  # screen glint near the top end
                else:
                    ch = "P"
                grid[y][x] = ch


# Hero pose v2: vertical phone held high beside the head (reference panel B),
# mitten gripping its lower-left edge through an arm at rows 11-12.
PHONE = [
    "......######......" + ".......",
    "....##wwwwww##...." + ".......",
    "...#wwwwwwwwww#..." + ".......",
    "..#wwwwwwwwwwww#.." + ".......",
    ".#wwwwwwwwwwwwww#." + "..###..",
    ".#bwwwwwwwwwwwww#." + ".#PPp#.",
    "#bwwwwwwwwwwwwwww#" + ".#wPp#.",
    "#bwwwwwwwwwwwwwww#" + ".#PPp#.",
    "#bwwwwwwwwwwwwwww#" + ".#PPp#.",
    "#bwww##wwww##wwww#" + ".#PPp#.",
    "#bwww##wwww##wwww#" + "##PPp#.",
    "#bwwwwwwwwwwwwwwww" + "w#PPp#.",
    "#bwwwwwwwwwwwwwwww" + "w#PPp#.",
    "#bwwwwww##wwwwwww#" + "#.###..",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwww#www#www#www#" + ".......",
    "#www#.#w#.#w#.#ww#" + ".......",
    ".###...#...#...##." + ".......",
]

# Smile v2: corners one px up at cols 6/11, 4px bottom run at cols 7-10
# (rows 12-13), plus 2px coral cheeks tucked below-outside the eyes.
HAPPY = [
    "......######......",
    "....##wwwwww##....",
    "...#wwwwwwwwww#...",
    "..#wwwwwwwwwwww#..",
    ".#wwwwwwwwwwwwww#.",
    ".#bwwwwwwwwwwwww#.",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwww##wwww##wwww#",
    "#bwww##wwww##wwww#",
    "#bwccwwwwwwwwccww#",
    "#bwwww#wwww#wwwww#",
    "#bwwwww####wwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwww#www#www#www#",
    "#www#.#w#.#w#.#ww#",
    ".###...#...#...##.",
]

# One arm raised beside the head: 3x3 mitten (ink ring) at rows 2-6,
# 2px arm stepping down into the body wall opening at row 8, smiling mouth.
# Motion ticks arc over and right of the mitten.
WAVE = [
    "......######......" + "...##...",
    "....##wwwwww##...." + "........",
    "...#wwwwwwwwww#..." + "..###...",
    "..#wwwwwwwwwwww#.." + ".#www#..",
    ".#wwwwwwwwwwwwww#." + ".#www#.#",
    ".#bwwwwwwwwwwwww#." + ".#www#.#",
    "#bwwwwwwwwwwwwwww#" + "#ww##...",
    "#bwwwwwwwwwwwwwww#" + "ww#.....",
    "#bwwwwwwwwwwwwwwww" + "w#......",
    "#bwww##wwww##wwww#" + "#.......",
    "#bwww##wwww##wwww#" + "........",
    "#bwwwwwwwwwwwwwww#" + "........",
    "#bwwww#wwww#wwwww#" + "........",
    "#bwwwww####wwwwww#" + "........",
    "#bwwwwwwwwwwwwwww#" + "........",
    "#bwwwwwwwwwwwwwww#" + "........",
    "#wwwwwwwwwwwwwwww#" + "........",
    "#wwwwwwwwwwwwwwww#" + "........",
    "#wwwwwwwwwwwwwwww#" + "........",
    "#wwww#www#www#www#" + "........",
    "#www#.#w#.#w#.#ww#" + "........",
    ".###...#...#...##." + "........",
]

# Eyes shifted up-left (rows 7-8, cols 4-5 / 10-11), small mouth offset left,
# two thought bubbles stepping up-right: a ringed 3x3 dot then a ringed
# 5x4 ellipse (white centers keep them legible on dark cards).
THINKING = [
    "......######......" + "...###.",
    "....##wwwwww##...." + "..#www#",
    "...#wwwwwwwwww#..." + "..#www#",
    "..#wwwwwwwwwwww#.." + "...###.",
    ".#wwwwwwwwwwwwww#." + ".......",
    ".#bwwwwwwwwwwwww#." + ".###...",
    "#bwwwwwwwwwwwwwww#" + ".#w#...",
    "#bww##wwww##wwwww#" + ".###...",
    "#bww##wwww##wwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwww##wwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#bwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwwwwwwwwwwwwwww#" + ".......",
    "#wwww#www#www#www#" + ".......",
    "#www#.#w#.#w#.#ww#" + ".......",
    ".###...#...#...##." + ".......",
]

# Closed eyes as peaceful downward arcs (2px centers up, corners down),
# pixel "z Z" climbing up-right (both glyphs carry a real diagonal).
SLEEPY = [
    "......######......" + ".....######",
    "....##wwwwww##...." + ".........#.",
    "...#wwwwwwwwww#..." + "........#..",
    "..#wwwwwwwwwwww#.." + ".......#...",
    ".#wwwwwwwwwwwwww#." + "......#....",
    ".#bwwwwwwwwwwwww#." + ".....######",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + ".####......",
    "#bwwwwwwwwwwwwwww#" + "...#.......",
    "#bwww##wwww##wwww#" + "..#........",
    "#bww#ww#ww#ww#www#" + ".####......",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwww##wwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#wwwwwwwwwwwwwwww#" + "...........",
    "#wwwwwwwwwwwwwwww#" + "...........",
    "#wwwwwwwwwwwwwwww#" + "...........",
    "#wwww#www#www#www#" + "...........",
    "#www#.#w#.#w#.#ww#" + "...........",
    ".###...#...#...##." + "...........",
]

# The brand moment: smiling ghost holding a honey rounded badge with a
# white 2px pixel checkmark (white pops against the honey at sidebar
# sizes; deep-honey read as a smear). PHONE arm mechanics (wall opens
# rows 11-12, white hand col 18, ink caps above/below).
APPROVAL = [
    "......######......" + "..........",
    "....##wwwwww##...." + "..........",
    "...#wwwwwwwwww#..." + "..........",
    "..#wwwwwwwwwwww#.." + "..........",
    ".#wwwwwwwwwwwwww#." + "..#######.",
    ".#bwwwwwwwwwwwww#." + ".#hhhhhhh#",
    "#bwwwwwwwwwwwwwww#" + ".#hhhhhhh#",
    "#bwwwwwwwwwwwwwww#" + ".#hhhhhww#",
    "#bwwwwwwwwwwwwwww#" + ".#hhhhwwh#",
    "#bwww##wwww##wwww#" + ".#whhwwhh#",
    "#bwww##wwww##wwww#" + "##wwwwhhh#",
    "#bwwwwwwwwwwwwwwww" + "w#hwwhhhh#",
    "#bwwww#wwww#wwwwww" + "w#hhhhhhh#",
    "#bwwwww####wwwwww#" + "#.#######.",
    "#bwwwwwwwwwwwwwww#" + "..........",
    "#bwwwwwwwwwwwwwww#" + "..........",
    "#wwwwwwwwwwwwwwww#" + "..........",
    "#wwwwwwwwwwwwwwww#" + "..........",
    "#wwwwwwwwwwwwwwww#" + "..........",
    "#wwww#www#www#www#" + "..........",
    "#www#.#w#.#w#.#ww#" + "..........",
    ".###...#...#...##." + "..........",
]

# Tall open 2x3 shout mouth, speech bubble with pixel-text "boo" (4-tall
# letter rings, b keeps its ascender), tail tapering down-left so it
# points back at the ghost's mouth.
BOO = [
    "......######......" + "..................",
    "....##wwwwww##...." + "...#############..",
    "...#wwwwwwwwww#..." + "..#wwwwwwwwwwwww#.",
    "..#wwwwwwwwwwww#.." + "..#w#wwwwwwwwwww#.",
    ".#wwwwwwwwwwwwww#." + "..#w#wwwwwwwwwww#.",
    ".#bwwwwwwwwwwwww#." + "..#w###w###w###w#.",
    "#bwwwwwwwwwwwwwww#" + "..#w#w#w#w#w#w#w#.",
    "#bwwwwwwwwwwwwwww#" + "..#w#w#w#w#w#w#w#.",
    "#bwwwwwwwwwwwwwww#" + "..#w###w###w###w#.",
    "#bwww##wwww##wwww#" + "..#wwwwwwwwwwwww#.",
    "#bwww##wwww##wwww#" + "...#############..",
    "#bwwwwwwwwwwwwwww#" + "..##..............",
    "#bwwwwww##wwwwwww#" + ".##...............",
    "#bwwwwww##wwwwwww#" + "..................",
    "#bwwwwww##wwwwwww#" + "..................",
    "#bwwwwwwwwwwwwwww#" + "..................",
    "#wwwwwwwwwwwwwwww#" + "..................",
    "#wwwwwwwwwwwwwwww#" + "..................",
    "#wwwwwwwwwwwwwwww#" + "..................",
    "#wwww#www#www#www#" + "..................",
    "#www#.#w#.#w#.#ww#" + "..................",
    ".###...#...#...##." + "..................",
]

# Holding a chunky solid-red pixel heart (9 wide) at arm height,
# hand gripping the left lobe through the rows 11-12 wall opening.
HEART = [
    "......######......" + "..........",
    "....##wwwwww##...." + "..........",
    "...#wwwwwwwwww#..." + "..........",
    "..#wwwwwwwwwwww#.." + "..........",
    ".#wwwwwwwwwwwwww#." + "..........",
    ".#bwwwwwwwwwwwww#." + "..........",
    "#bwwwwwwwwwwwwwww#" + "..........",
    "#bwwwwwwwwwwwwwww#" + "..........",
    "#bwwwwwwwwwwwwwww#" + "..........",
    "#bwww##wwww##wwww#" + "..rr...rr.",
    "#bwww##wwww##wwww#" + "#rrrr.rrrr",
    "#bwwwwwwwwwwwwwwww" + "wrrrrrrrrr",
    "#bwwwwwwwwwwwwwwww" + "wrrrrrrrrr",
    "#bwwwwww##wwwwwww#" + "#.rrrrrrr.",
    "#bwwwwwwwwwwwwwww#" + "...rrrrr..",
    "#bwwwwwwwwwwwwwww#" + "....rrr...",
    "#wwwwwwwwwwwwwwww#" + ".....r....",
    "#wwwwwwwwwwwwwwww#" + "..........",
    "#wwwwwwwwwwwwwwww#" + "..........",
    "#wwww#www#www#www#" + "..........",
    "#www#.#w#.#w#.#ww#" + "..........",
    ".###...#...#...##." + "..........",
]

# Holding a 12-wide white envelope with a V flap (drafts), gripped by its
# left edge through the rows 11-12 wall opening.
ENVELOPE = [
    "......######......" + ".............",
    "....##wwwwww##...." + ".............",
    "...#wwwwwwwwww#..." + ".............",
    "..#wwwwwwwwwwww#.." + ".............",
    ".#wwwwwwwwwwwwww#." + ".............",
    ".#bwwwwwwwwwwwww#." + ".............",
    "#bwwwwwwwwwwwwwww#" + ".............",
    "#bwwwwwwwwwwwwwww#" + ".............",
    "#bwwwwwwwwwwwwwww#" + ".############",
    "#bwww##wwww##wwww#" + ".##wwwwwwww##",
    "#bwww##wwww##wwww#" + "##w#wwwwww#w#",
    "#bwwwwwwwwwwwwwwww" + "w#ww#wwww#ww#",
    "#bwwwwwwwwwwwwwwww" + "w#www####www#",
    "#bwwwwww##wwwwwww#" + "##wwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#" + ".#wwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#" + ".############",
    "#wwwwwwwwwwwwwwww#" + ".............",
    "#wwwwwwwwwwwwwwww#" + ".............",
    "#wwwwwwwwwwwwwwww#" + ".............",
    "#wwww#www#www#www#" + ".............",
    "#www#.#w#.#w#.#ww#" + ".............",
    ".###...#...#...##." + ".............",
]

# Beside a 3-bar chart in brand colors (honey, phone blue, coral),
# 3px-wide bars on an ink baseline sharing the ghost's ground line.
CHART = [
    "......######......" + "..............",
    "....##wwwwww##...." + "..............",
    "...#wwwwwwwwww#..." + "..............",
    "..#wwwwwwwwwwww#.." + "..............",
    ".#wwwwwwwwwwwwww#." + "..............",
    ".#bwwwwwwwwwwwww#." + "..............",
    "#bwwwwwwwwwwwwwww#" + "..............",
    "#bwwwwwwwwwwwwwww#" + "..............",
    "#bwwwwwwwwwwwwwww#" + "..............",
    "#bwww##wwww##wwww#" + "..............",
    "#bwww##wwww##wwww#" + "..............",
    "#bwwwwwwwwwwwwwww#" + "..........ccc.",
    "#bwwwwwwwwwwwwwww#" + "..........ccc.",
    "#bwwwwww##wwwwwww#" + "..........ccc.",
    "#bwwwwwwwwwwwwwww#" + "......PPP.ccc.",
    "#bwwwwwwwwwwwwwww#" + "......PPP.ccc.",
    "#wwwwwwwwwwwwwwww#" + "......PPP.ccc.",
    "#wwwwwwwwwwwwwwww#" + "..hhh.PPP.ccc.",
    "#wwwwwwwwwwwwwwww#" + "..hhh.PPP.ccc.",
    "#wwww#www#www#www#" + "..hhh.PPP.ccc.",
    "#www#.#w#.#w#.#ww#" + "..hhh.PPP.ccc.",
    ".###...#...#...##." + ".#############",
]

# Birthday: two-tier candled cake on the ghost's ground line, honey icing,
# red candle, coral flame with a honey glow.
CAKE = [
    "......######......" + "...........",
    "....##wwwwww##...." + "...........",
    "...#wwwwwwwwww#..." + "...........",
    "..#wwwwwwwwwwww#.." + "...........",
    ".#wwwwwwwwwwwwww#." + "...........",
    ".#bwwwwwwwwwwwww#." + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwww##wwww##wwww#" + "...........",
    "#bwww##wwww##wwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + ".....h.....",
    "#bwwwwwwwwwwwwwww#" + ".....c.....",
    "#bwwwwww##wwwwwww#" + ".....r.....",
    "#bwwwwwwwwwwwwwww#" + "...#####...",
    "#bwwwwwwwwwwwwwww#" + "..#hhhhh#..",
    "#wwwwwwwwwwwwwwww#" + "..#wwwww#..",
    "#wwwwwwwwwwwwwwww#" + ".#########.",
    "#wwwwwwwwwwwwwwww#" + "#hhhhhhhhh#",
    "#wwww#www#www#www#" + "#wwwwwwwww#",
    "#www#.#w#.#w#.#ww#" + "#wwwwwwwww#",
    ".###...#...#...##." + "###########",
]

# Texting Wrapped: 9-wide ribboned gift box with a honey bow on the
# ground line.
GIFT = [
    "......######......" + "...........",
    "....##wwwwww##...." + "...........",
    "...#wwwwwwwwww#..." + "...........",
    "..#wwwwwwwwwwww#.." + "...........",
    ".#wwwwwwwwwwwwww#." + "...........",
    ".#bwwwwwwwwwwwww#." + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwww##wwww##wwww#" + "...........",
    "#bwww##wwww##wwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + "...........",
    "#bwwwwwwwwwwwwwww#" + ".hhh...hhh.",
    "#bwwwwww##wwwwwww#" + ".hhhh.hhhh.",
    "#bwwwwwwwwwwwwwww#" + "....hhh....",
    "#bwwwwwwwwwwwwwww#" + ".#########.",
    "#wwwwwwwwwwwwwwww#" + ".#wwwhwww#.",
    "#wwwwwwwwwwwwwwww#" + ".#wwwhwww#.",
    "#wwwwwwwwwwwwwwww#" + ".#wwwhwww#.",
    "#wwww#www#www#www#" + ".#wwwhwww#.",
    "#www#.#w#.#w#.#ww#" + ".#wwwhwww#.",
    ".###...#...#...##." + ".#########.",
]

# Settings/utility: holding a classic 8-tooth honey cog (flat cardinal
# teeth, triangular diagonal teeth, open hub hole) by its west tooth
# through the rows 11-12 wall opening. Solid honey, no outline — the
# colored-accent grammar (heart, chart bars), so it stays legible on dark
# sidebar cards too.
GEAR = [
    "......######......" + "................",
    "....##wwwwww##...." + "................",
    "...#wwwwwwwwww#..." + "................",
    "..#wwwwwwwwwwww#.." + "................",
    ".#wwwwwwwwwwwwww#." + ".......hhh......",
    ".#bwwwwwwwwwwwww#." + "...h...hhh...h..",
    "#bwwwwwwwwwwwwwww#" + "..hhh.hhhhh.hhh.",
    "#bwwwwwwwwwwwwwww#" + "..hhhhhhhhhhhhh.",
    "#bwwwwwwwwwwwwwww#" + "...hhhhhhhhhhh..",
    "#bwww##wwww##wwww#" + "...hhhh...hhhh..",
    "#bwww##wwww##wwww#" + "#.hhhh.....hhhh.",
    "#bwwwwwwwwwwwwwwww" + "whhhhh.....hhhhh",
    "#bwwwwwwwwwwwwwwww" + "whhhhh.....hhhhh",
    "#bwwwwww##wwwwwww#" + "#.hhhh.....hhhh.",
    "#bwwwwwwwwwwwwwww#" + "...hhhh...hhhh..",
    "#bwwwwwwwwwwwwwww#" + "...hhhhhhhhhhh..",
    "#wwwwwwwwwwwwwwww#" + "..hhhhhhhhhhhhh.",
    "#wwwwwwwwwwwwwwww#" + "..hhh.hhhhh.hhh.",
    "#wwwwwwwwwwwwwwww#" + "...h...hhh...h..",
    "#wwww#www#www#www#" + ".......hhh......",
    "#www#.#w#.#w#.#ww#" + "................",
    ".###...#...#...##." + "................",
]

# Work/office: phone-blue top hat (crown + overhanging brim) seated on
# the dome; the brim underside replaces the dome's top outline row.
TOPHAT = [
    ".....########.....",
    ".....#PPPPPP#.....",
    ".....#PPPPPP#.....",
    ".....#PPPPPP#.....",
    "..####PPPPPP####..",
    "..##############..",
    "....##wwwwww##....",
    "...#wwwwwwwwww#...",
    "..#wwwwwwwwwwww#..",
    ".#wwwwwwwwwwwwww#.",
    ".#bwwwwwwwwwwwww#.",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwww##wwww##wwww#",
    "#bwww##wwww##wwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwww##wwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwww#www#www#www#",
    "#www#.#w#.#w#.#ww#",
    ".###...#...#...##.",
]

# Automations: green headphones — thick band arcs over the dome, hugs the
# head curve down both sides, and lands in ear cups (ink caps top/bottom,
# green pads replacing the body wall) at eye height.
HEADPHONES = [
    "........gggggg........",
    "......gggggggggg......",
    "......gg######gg......",
    "....gg##wwwwww##gg....",
    "...gg#wwwwwwwwww#gg...",
    "..gg#wwwwwwwwwwww#gg..",
    ".gg#wwwwwwwwwwwwww#gg.",
    ".gg#bwwwwwwwwwwwww#gg.",
    "gg#bwwwwwwwwwwwwwww#gg",
    "###bwwwwwwwwwwwwwww###",
    "#ggbwwwwwwwwwwwwwwwgg#",
    "#ggbwww##wwww##wwwwgg#",
    "#ggbwww##wwww##wwwwgg#",
    "#ggbwwwwwwwwwwwwwwwgg#",
    "###bwwwwwwwwwwwwwww###",
    "..#bwwwwww##wwwwwww#..",
    "..#bwwwwwwwwwwwwwww#..",
    "..#bwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwww#..",
    "..#wwww#www#www#www#..",
    "..#www#.#w#.#w#.#ww#..",
    "...###...#...#...##...",
]

# Keep Tabs: an orange fisherman's beanie — a snug knit dome (orange) replacing
# the head crown, with a deep-orange folded cuff band across the brow. Hugs the
# idle head's taper so it reads as worn, not stacked; face/body below are idle.
BEANIE = [
    "......######......",
    "....##oooooo##....",
    "...#oooooooooo#...",
    "..#oooooooooooo#..",
    ".#oooooooooooooo#.",
    ".#OOOOOOOOOOOOOO#.",
    "#OOOOOOOOOOOOOOOO#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwww##wwww##wwww#",
    "#bwww##wwww##wwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwww##wwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#bwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwwwwwwwwwwwwwww#",
    "#wwww#www#www#www#",
    "#www#.#w#.#w#.#ww#",
    ".###...#...#...##.",
]

# Keep Tabs, high-density (≈1.8× the 18×22 idle): a more expressive Ghostie in a
# Life Aquatic / Steve Zissou orange knit beanie — rounded crown with a light
# knit highlight, a deep folded cuff, round eyes with glints, a small smile and
# cheeks. 30 wide × 36 tall.
BEANIE_HD = [
    "...........########...........",
    ".........##oooooooooo##.......",
    "........#oooooooooooooo#......",
    ".......#qoooooooooooooooo#....",
    "......#qqoooooooooooooooo#....",
    "......#qooooooooooooooooo#....",
    ".....#qoooooooooooooooooo#....",
    ".....#oooooooooooooooooooo#...",
    ".....#nnnnnnnnnnnnnnnnnnnn#...",
    "....#OOOOOOOOOOOOOOOOOOOOOO#..",
    "....#OOOOOOOOOOOOOOOOOOOOOO#..",
    "...#OOOOOOOOOOOOOOOOOOOOOOOO#.",
    "...#bwwwwwwwwwwwwwwwwwwwwww#..",
    "..#bwwwwwwwwwwwwwwwwwwwwwwww#.",
    "..#bwwwwwwwwwwwwwwwwwwwwwwww#.",
    "..#bwwwwwwwwwwwwwwwwwwwwwwww#.",
    "..#bwwwww####wwwwww####wwwww#.",
    "..#bwwww#eeee#wwww#eeee#wwww#.",
    "..#bwwww#ewwe#wwww#ewwe#wwww#.",
    "..#bwwww#eeee#wwww#eeee#wwww#.",
    "..#bwwwww####wwwwww####wwwww#.",
    "..#bwwwwwwwwwwwwwwwwwwwwwwww#.",
    "..#bwwwwwccwwwwwwwwwwccwwwww#.",
    "..#bwwwwwwww#wwww#wwwwwwwwww#.",
    "..#bwwwwwwww######wwwwwwwww#..",
    "..#bwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#bwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#wwwwwwwwwwwwwwwwwwwwwwww#..",
    "..#wwwww#wwwww#wwwww#wwwwww#..",
    "..##www#.#www#.#www#.#wwww##..",
    "....###...###...###...####....",
]

SPRITES = {
    "idle": IDLE,
    "beanie": BEANIE,
    "beanie_hd": BEANIE_HD,
    "phone": PHONE,
    "happy": HAPPY,
    "wave": WAVE,
    "thinking": THINKING,
    "sleepy": SLEEPY,
    "approval": APPROVAL,
    "boo": BOO,
    "heart": HEART,
    "envelope": ENVELOPE,
    "chart": CHART,
    "cake": CAKE,
    "gift": GIFT,
    "gear": GEAR,
    "tophat": TOPHAT,
    "headphones": HEADPHONES,
}


def normalize(rows):
    w = max(len(r) for r in rows)
    return [r.ljust(w, ".") for r in rows]


def lint(name, rows):
    """Outline lint: body white/blue must never touch transparent — every 'w'/'b'
    needs ink (or another interior pixel) on all four sides. Colored accents
    (props like hearts, chart bars, hat) may touch background by design."""
    rows = normalize(rows)
    h, w = len(rows), len(rows[0])
    problems = []
    for y in range(h):
        for x in range(w):
            if rows[y][x] not in ("w", "b"):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    if rows[ny][nx] == ".":
                        problems.append((x, y))
                else:
                    problems.append((x, y))
    for x, y in problems:
        print(f"  LINT {name}: white leaks to background at ({x},{y})")
    return not problems


def render(name, rows, scale, path):
    rows = normalize(rows)
    h, w = len(rows), len(rows[0])
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            color = PALETTE.get(ch)
            if color:
                px[x, y] = color
    im = im.resize((w * scale, h * scale), Image.NEAREST)
    im.save(path)
    return im


def sprite_image(rows, scale):
    rows = normalize(rows)
    h, w = len(rows), len(rows[0])
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            color = PALETTE.get(ch)
            if color:
                px[x, y] = color
    return im.resize((w * scale, h * scale), Image.NEAREST)


CREAM = (255, 248, 241, 255)
MINT = (230, 248, 244, 255)
INK = (20, 20, 22, 255)


def app_icon(size=1024):
    """macOS icon: rounded-rect tile on the Apple grid (~824/1024), flat mint,
    chunky ink border, crisp pixel ghost centered. No baked shadow."""
    from PIL import ImageDraw
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    tile = int(size * 824 / 1024)
    off = (size - tile) // 2
    radius = int(tile * 0.2237)
    border = max(4, size // 86)  # ~12px at 1024: pixel-art chunk
    d.rounded_rectangle([off, off, off + tile, off + tile], radius=radius, fill=INK)
    d.rounded_rectangle(
        [off + border, off + border, off + tile - border, off + tile - border],
        radius=radius - border, fill=MINT)
    ghost = normalize(PHONE)
    gw, gh = len(ghost[0]), len(ghost)
    scale = int(tile * 0.74) // max(gw, gh)
    g = sprite_image(ghost, scale)
    # optical centering: phone pose is right-heavy, nudge left a touch
    gx = (size - g.width) // 2 - scale
    gy = (size - g.height) // 2
    im.alpha_composite(g, (gx, gy))
    return im


def menubar_template(scale):
    """Template image: pure black silhouette + alpha, eyes punched out."""
    rows = normalize(IDLE)
    h, w = len(rows), len(rows[0])
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            px[x, y] = (0, 0, 0, 255)
    # punch the eyes back out so the face reads as pure shape
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if 9 <= y <= 10 and ch == "#" and 4 < x < 13:
                px[x, y] = (0, 0, 0, 0)
    return im.resize((w * scale, h * scale), Image.NEAREST)


def favicon(size):
    """Filled idle ghost, no outline-thinning: sprite scaled to fit."""
    rows = normalize(IDLE)
    w = len(rows[0])
    scale = max(1, size // w)
    g = sprite_image(rows, scale)
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    im.alpha_composite(g, ((size - g.width) // 2, (size - g.height) // 2))
    return im


# Sidebar assets consumed by GhostieSidebarAsset in
# menubar/Sources/MessagesForAIMenu/Views/ConsoleView.swift.
# Filenames are load-bearing: the Swift enum looks these up verbatim.
APP_ASSETS = {
    "ghostie-shell-mark-polished-v4": "phone",        # Messages (brand row)
    "ghostie-macos-icon-classic-clean-v3": "happy",   # default tool
    "ghostie-macos-icon-classic-bubble-v3": "thinking",
    "ghostie-macos-icon-classic-utility-v3": "gear",  # History + Settings
    "ghostie-feature-approval-v2": "approval",        # Scheduled
    "ghostie-feature-keep-tabs-v2": "beanie_hd",      # Keep Tabs (HD Zissou beanie)
    "ghostie-feature-automations-v2": "headphones",   # Automations
    "ghostie-feature-birthday-v2": "cake",            # Birthdays
    "ghostie-feature-dont-ghost-v2": "wave",          # Don't Ghost
    "ghostie-feature-drafts-v2": "envelope",          # Drafts
    "ghostie-feature-texting-voice-v2": "boo",        # Texting Voice
    "ghostie-feature-tone-check-v2": "heart",         # Tone Check (eq)
    "ghostie-feature-wrapped-v2": "gift",             # Texting Wrapped
    "ghostie-macos-icon-office-v1": "tophat",         # Work/Personal
    "ghostie-macos-icon-analytics-v1": "chart",       # Texting Analytics
}


def app_asset(rows, size=256, margin=0.09):
    """Sprite centered on a transparent square canvas with a small baked
    margin so non-inset sidebar marks don't kiss the card edge."""
    rows = normalize(rows)
    h, w = len(rows), len(rows[0])
    scale = max(1, int(size * (1 - 2 * margin)) // max(w, h))
    g = sprite_image(rows, scale)
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    im.alpha_composite(g, ((size - g.width) // 2, (size - g.height) // 2))
    return im


def pixel_svg(rows, px=8):
    """Pixel-rect SVG: one <rect> per run of same-color pixels, crisp forever."""
    rows = normalize(rows)
    h, w = len(rows), len(rows[0])
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w * px} {h * px}" shape-rendering="crispEdges">']
    for y, row in enumerate(rows):
        x = 0
        while x < w:
            ch = row[x]
            if PALETTE.get(ch) is None:
                x += 1
                continue
            x2 = x
            while x2 < w and row[x2] == ch:
                x2 += 1
            r, g, b, _ = PALETTE[ch]
            parts.append(
                f'<rect x="{x * px}" y="{y * px}" width="{(x2 - x) * px}" height="{px}" fill="#{r:02x}{g:02x}{b:02x}"/>')
            x = x2
    parts.append("</svg>")
    return "\n".join(parts)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    clean = True
    for name, rows in SPRITES.items():
        clean &= lint(name, rows)
        render(name, rows, 24, OUT / f"{name}@24x.png")
        (OUT / f"{name}.svg").write_text(pixel_svg(rows))
        app_asset(rows).save(OUT / f"{name}@256.png")
        print(name, "ok")
    if not clean:
        raise SystemExit("lint failures above")
    app_dir = OUT / "app"
    app_dir.mkdir(exist_ok=True)
    for asset_name, sprite in APP_ASSETS.items():
        app_asset(SPRITES[sprite]).save(app_dir / f"{asset_name}.png")
    # NOTE: the SHIPPED app icon is the rasterized "Approval" tile
    # (brand/ghostie/pixel-options/raster/logos/ghostie-macos-icon-classic-approval-v3.png,
    # padded to the macOS 824/1024 grid), committed at out/app-icon-1024.png and
    # consumed by menubar/scripts/generate-app-icon.swift. The pixel-generated
    # icon below is kept for reference only and must NOT overwrite the raster.
    app_icon(1024).save(OUT / "app-icon-pixel-1024.png")
    app_icon(256).save(OUT / "app-icon-pixel-256.png")
    menubar_template(2).save(OUT / "menubar-template@2x.png")
    menubar_template(1).save(OUT / "menubar-template@1x.png")
    favicon(32).save(OUT / "favicon-32.png")
    favicon(180).save(OUT / "apple-touch-icon-180.png")
    print("derivatives ok")
