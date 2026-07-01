#!/usr/bin/env python3
"""
build_charts.py — Texting Analytics chart generator

Reads analysis.json (produced by the LLM running the texting-analytics skill)
and emits four standardized PNG charts.

Usage:
    python3 build_charts.py --input <path>/analysis.json --output <output_dir>/

Optional flags:
    --unbranded         Drop the "sunriselabs.ai · messagesfor.ai" footer.
    --theme dark        Use dark mode instead of warm-off-white (default).
    --only <name>       Only build one chart. Choices: latency, ball, gap, group.

Output:
    <output_dir>/01-latency.png
    <output_dir>/02-ball-in-court.png
    <output_dir>/03-gap.png
    <output_dir>/04-group-contribution.png

Schema for analysis.json:
    See SCHEMA = {...} below for required fields.
"""

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
import numpy as np


SCHEMA = {
    "latency": {
        "required": [
            "total_reply_pairs",
            "pct_within_5min",
            "pct_within_30min",
            "pct_within_1hr",
            "pct_within_4hr",
            "mean_minutes",
            "median_minutes",
            "thread_count",
            "window_label",  # e.g. "past 12 months"
        ]
    },
    "ball_in_court": {
        "required": [
            "total_threads_sampled",
            "pct_ball_in_court",
            "live_conversations_estimate",
            "snapshot_label",  # e.g. "May 2026"
        ]
    },
    "group_contribution": {
        "required": [
            "total_groups_analyzed",
            "total_messages_in_groups",
            "user_contribution_pct",
            "user_reaction_rate_pct",
            "peer_reaction_rate_pct",
            "groups_where_user_silent",
            "per_thread",  # list of {thread_label, total, user_count, user_pct, user_reaction_pct}
        ]
    },
}


# --- Theme ---

THEMES = {
    "light": {
        "BG": "#FAFAF7",
        "INK": "#1A1A1A",
        "MUTED": "#6B6B6B",
        "ACCENT": "#0A84FF",
        "ACCENT_SOFT": "#D6EBFF",
        "HAIRLINE": "#E5E5E0",
    },
    "dark": {
        "BG": "#0F0F11",
        "INK": "#F5F5F2",
        "MUTED": "#9A9A95",
        "ACCENT": "#5EA8FF",
        "ACCENT_SOFT": "#1A3957",
        "HAIRLINE": "#26262A",
    },
}

BRAND_STAMP = "sunriselabs.ai · messagesfor.ai"


def register_inter_fonts():
    """Register Inter from common system locations, fall back to whatever's available."""
    candidates = [
        "/tmp/fonts/Inter-*.ttf",
        "/tmp/fonts/Inter-*.otf",
        os.path.expanduser("~/Library/Fonts/Inter-*.ttf"),
        os.path.expanduser("~/Library/Fonts/Inter-*.otf"),
        "/Library/Fonts/Inter-*.ttf",
        "/Library/Fonts/Inter-*.otf",
        "/usr/share/fonts/**/Inter-*.ttf",
    ]
    loaded = []
    for pattern in candidates:
        for path in glob.glob(pattern, recursive=True):
            try:
                fm.fontManager.addfont(path)
                family = fm.FontProperties(fname=path).get_name()
                loaded.append(family)
            except Exception:
                pass
    if loaded:
        return loaded[0]
    return "DejaVu Sans"


def base_setup(theme_name="light"):
    theme = THEMES[theme_name]
    family = register_inter_fonts()
    plt.rcParams.update(
        {
            "font.family": family,
            "font.size": 18,
            "axes.edgecolor": theme["INK"],
            "axes.linewidth": 0,
            "savefig.facecolor": theme["BG"],
        }
    )
    return theme


# --- Chart 1: Latency distribution ---


def chart_latency(data, theme, out_path, branded=True):
    d = data["latency"]
    fig, ax = plt.subplots(figsize=(10.8, 10.8), dpi=100)
    fig.patch.set_facecolor(theme["BG"])
    ax.set_facecolor(theme["BG"])

    buckets = ["within 5 min", "within 30 min", "within 1 hour", "within 4 hours"]
    pcts = [
        d["pct_within_5min"],
        d["pct_within_30min"],
        d["pct_within_1hr"],
        d["pct_within_4hr"],
    ]
    y_positions = np.arange(len(buckets))[::-1]
    bar_height = 0.55

    ax.barh(y_positions, [100] * len(buckets), height=bar_height, color=theme["HAIRLINE"], zorder=1)
    ax.barh(y_positions, pcts, height=bar_height, color=theme["ACCENT"], zorder=2)

    for y, label, pct in zip(y_positions, buckets, pcts):
        ax.text(-2, y, label, va="center", ha="right", fontsize=22, color=theme["INK"], fontweight="500")
        ax.text(pct + 1.5, y, f"{int(round(pct))}%", va="center", ha="left", fontsize=24, color=theme["INK"], fontweight="700")

    ax.set_xlim(-45, 110)
    ax.set_ylim(-0.8, len(buckets) - 0.2)
    ax.axis("off")

    fig.text(0.5, 0.94, "How fast I reply to texts", ha="center", fontsize=36, color=theme["INK"], fontweight="700")
    fig.text(
        0.5,
        0.89,
        f"{d['total_reply_pairs']:,} reply pairs across {d['thread_count']} threads, {d['window_label']}",
        ha="center",
        fontsize=18,
        color=theme["MUTED"],
    )
    fig.text(
        0.5,
        0.06,
        f"Mean: {int(round(d['mean_minutes']))} minutes. Sounds quick until you notice the tail.",
        ha="center",
        fontsize=18,
        color=theme["MUTED"],
        style="italic",
    )
    if branded:
        fig.text(0.5, 0.03, BRAND_STAMP, ha="center", fontsize=14, color=theme["MUTED"])

    plt.savefig(out_path, facecolor=theme["BG"], dpi=100, bbox_inches="tight", pad_inches=0.6)
    plt.close()


# --- Chart 2: Ball in court ---


def chart_ball(data, theme, out_path, branded=True):
    d = data["ball_in_court"]
    fig = plt.figure(figsize=(10.8, 10.8), dpi=100)
    fig.patch.set_facecolor(theme["BG"])

    pct = int(round(d["pct_ball_in_court"]))
    fig.text(0.5, 0.52, f"{pct}%", ha="center", va="center", fontsize=200, color=theme["ACCENT"], fontweight="800")

    fig.text(0.5, 0.34, "of my recent threads,", ha="center", fontsize=30, color=theme["INK"], fontweight="500")
    fig.text(0.5, 0.295, "they got the last word", ha="center", fontsize=30, color=theme["INK"], fontweight="500")

    fig.text(0.5, 0.82, "The last word", ha="center", fontsize=34, color=theme["INK"], fontweight="700")
    fig.text(0.5, 0.76, "How often the other person spoke last", ha="center", fontsize=18, color=theme["MUTED"])

    fig.text(
        0.5,
        0.17,
        f"Snapshot of {d['total_threads_sampled']} most recent threads, {d['snapshot_label']}",
        ha="center",
        fontsize=16,
        color=theme["MUTED"],
        style="italic",
    )
    fig.text(
        0.5,
        0.13,
        "Not every one is waiting on a reply,",
        ha="center",
        fontsize=16,
        color=theme["MUTED"],
    )
    fig.text(0.5, 0.10, "it just means they texted last.", ha="center", fontsize=16, color=theme["MUTED"])
    if branded:
        fig.text(0.5, 0.04, BRAND_STAMP, ha="center", fontsize=14, color=theme["MUTED"])

    plt.savefig(out_path, facecolor=theme["BG"], dpi=100, bbox_inches="tight", pad_inches=0.6)
    plt.close()


# --- Chart 3: Mean vs median gap ---


def chart_gap(data, theme, out_path, branded=True):
    d = data["latency"]
    fig = plt.figure(figsize=(10.8, 10.8), dpi=100)
    fig.patch.set_facecolor(theme["BG"])

    left_x, right_x = 0.27, 0.73
    median_str = f"{int(round(d['median_minutes']))} min"
    mean_str = f"{int(round(d['mean_minutes']))} min"

    fig.text(left_x, 0.55, median_str, ha="center", fontsize=92, color=theme["INK"], fontweight="800")
    fig.text(left_x, 0.46, "median reply", ha="center", fontsize=22, color=theme["MUTED"], fontweight="500")
    fig.text(left_x, 0.42, "(when I reply, I'm fast)", ha="center", fontsize=16, color=theme["MUTED"], style="italic")

    fig.text(right_x, 0.55, mean_str, ha="center", fontsize=92, color=theme["ACCENT"], fontweight="800")
    fig.text(right_x, 0.46, "mean reply", ha="center", fontsize=22, color=theme["MUTED"], fontweight="500")
    fig.text(right_x, 0.42, "(the tail tells a different story)", ha="center", fontsize=16, color=theme["MUTED"], style="italic")

    fig.text(0.5, 0.555, "vs", ha="center", fontsize=28, color=theme["HAIRLINE"], fontweight="600")

    fig.text(0.5, 0.82, "The gap", ha="center", fontsize=44, color=theme["INK"], fontweight="700")
    fig.text(0.5, 0.76, "I'm not slow. I'm slow sometimes, and that's the problem.", ha="center", fontsize=20, color=theme["MUTED"])

    # Derive 1-in-N stat: pct that take >1 hr (= 100 - pct_within_1hr), pct missing 30min
    pct_over_1hr = 100 - d["pct_within_1hr"]
    miss_30min = 100 - d["pct_within_30min"]
    one_in_n = max(2, round(100 / max(pct_over_1hr, 1)))

    fig.text(0.5, 0.26, f"1 in {one_in_n} replies takes more than an hour.", ha="center", fontsize=22, color=theme["INK"], fontweight="600")
    fig.text(0.5, 0.21, f"{int(round(miss_30min))}% of replies miss the 30-minute mark entirely.", ha="center", fontsize=20, color=theme["MUTED"])

    if branded:
        fig.text(0.5, 0.04, BRAND_STAMP, ha="center", fontsize=14, color=theme["MUTED"])

    plt.savefig(out_path, facecolor=theme["BG"], dpi=100, bbox_inches="tight", pad_inches=0.6)
    plt.close()


# --- Chart 4: Group thread contribution ---


def chart_group(data, theme, out_path, branded=True):
    d = data["group_contribution"]
    fig, ax = plt.subplots(figsize=(10.8, 10.8), dpi=100)
    fig.patch.set_facecolor(theme["BG"])
    ax.set_facecolor(theme["BG"])

    per_thread = sorted(d["per_thread"], key=lambda x: x["user_pct"], reverse=True)
    top_n = per_thread[:12]
    labels = [(t["thread_label"][:32] + "…") if len(t["thread_label"]) > 32 else t["thread_label"] for t in top_n]
    pcts = [t["user_pct"] for t in top_n]
    rxn_pcts = [t.get("user_reaction_pct", 0) for t in top_n]

    y = np.arange(len(labels))[::-1]
    bar_height = 0.65

    # Background guide bars
    ax.barh(y, [max(pcts) + 5 for _ in pcts], height=bar_height, color=theme["HAIRLINE"], zorder=1)
    # Substantive portion
    substantive = [p * (1 - r / 100) for p, r in zip(pcts, rxn_pcts)]
    reactions = [p * (r / 100) for p, r in zip(pcts, rxn_pcts)]
    ax.barh(y, substantive, height=bar_height, color=theme["ACCENT"], zorder=2, label="substantive")
    ax.barh(y, reactions, left=substantive, height=bar_height, color=theme["ACCENT_SOFT"], zorder=3, label="just reactions")

    for yi, label, pct in zip(y, labels, pcts):
        ax.text(-1, yi, label, va="center", ha="right", fontsize=16, color=theme["INK"], fontweight="500")
        ax.text(pct + 1, yi, f"{pct:.0f}%", va="center", ha="left", fontsize=16, color=theme["INK"], fontweight="700")

    ax.set_xlim(-(max([len(l) for l in labels]) + 5) * 0.8, max(pcts) + 12)
    ax.set_ylim(-0.7, len(labels) - 0.3)
    ax.axis("off")

    fig.text(0.5, 0.94, "Group thread contribution", ha="center", fontsize=32, color=theme["INK"], fontweight="700")
    fig.text(
        0.5,
        0.90,
        f"My share of messages in {d['total_groups_analyzed']} group threads",
        ha="center",
        fontsize=16,
        color=theme["MUTED"],
    )

    # Legend chips using matplotlib patches for crisp color squares
    from matplotlib.patches import Rectangle
    legend_y = 0.08
    legend_size = 0.018
    # Substantive chip
    fig.patches.append(Rectangle((0.22, legend_y), legend_size, legend_size, transform=fig.transFigure, facecolor=theme["ACCENT"], edgecolor="none", figure=fig))
    fig.text(0.25, legend_y + 0.003, "substantive", color=theme["INK"], fontsize=14, fontweight="500")
    # Reactions chip
    fig.patches.append(Rectangle((0.43, legend_y), legend_size, legend_size, transform=fig.transFigure, facecolor=theme["ACCENT_SOFT"], edgecolor="none", figure=fig))
    fig.text(0.46, legend_y + 0.003, "just reactions", color=theme["INK"], fontsize=14, fontweight="500")

    fig.text(
        0.5,
        0.04,
        f"{d['user_contribution_pct']:.1f}% of all group messages. Silent in {d['groups_where_user_silent']} threads.",
        ha="center",
        fontsize=14,
        color=theme["MUTED"],
    )
    if branded:
        fig.text(0.5, 0.01, BRAND_STAMP, ha="center", fontsize=13, color=theme["MUTED"])

    plt.savefig(out_path, facecolor=theme["BG"], dpi=100, bbox_inches="tight", pad_inches=0.6)
    plt.close()


# --- Main ---


def validate(data):
    errs = []
    for section, spec in SCHEMA.items():
        if section not in data:
            errs.append(f"missing section: {section}")
            continue
        for field in spec["required"]:
            if field not in data[section]:
                errs.append(f"missing field: {section}.{field}")
    return errs


def main():
    parser = argparse.ArgumentParser(description="Generate Texting Wrapped charts.")
    parser.add_argument("--input", required=True, help="Path to analysis.json")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--unbranded", action="store_true", help="Drop brand stamp")
    parser.add_argument("--theme", choices=["light", "dark"], default="light")
    parser.add_argument("--only", choices=["latency", "ball", "gap", "group"], help="Only build one chart")
    args = parser.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    errs = validate(data)
    if errs:
        for e in errs:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    theme = base_setup(args.theme)
    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)
    branded = not args.unbranded

    targets = {
        "latency": (chart_latency, out_dir / "01-latency.png"),
        "ball": (chart_ball, out_dir / "02-ball-in-court.png"),
        "gap": (chart_gap, out_dir / "03-gap.png"),
        "group": (chart_group, out_dir / "04-group-contribution.png"),
    }
    if args.only:
        targets = {args.only: targets[args.only]}

    for name, (fn, path) in targets.items():
        fn(data, theme, str(path), branded=branded)
        print(f"  built {path.name}")

    print(f"\nDone. Wrote {len(targets)} chart(s) to {out_dir}/")


if __name__ == "__main__":
    main()
