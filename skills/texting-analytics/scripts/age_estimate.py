#!/usr/bin/env python3
"""age_estimate.py — playful "texting age" estimate from style/emoji features.

Consumes the aggregate `style` + `emoji` blocks (from emoji_stats.py) plus
latency/volume, runs them through the weighted rubric in data/age_rubric.json,
and emits an `age` block to merge into analysis.json.

PROBABILISTIC, NOT DETERMINISTIC. This is an entertainment prior, not an
identity claim — frame the card playfully (the rubric's own disclaimer). Reads
only aggregates; no message bodies involved.

Usage:
  python3 age_estimate.py --analysis analysis.json [--total-sent N]

Output (stdout): { "age": { estimated_age, band, generation_band,
                            generation_scores, label, approx_age, confidence,
                            drivers, sample_size, active_days, evidence_count } }
                 merge into analysis.json.

Exit codes: 0 ok · 2 input/rubric malformed
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUBRIC_PATH = os.path.join(HERE, "..", "data", "age_rubric.json")

MIN_AGE_SAMPLE_SIZE = 500
MIN_ACTIVE_DAYS = 30
MIN_AGE_EVIDENCE = 3


def band_for_age(rubric, age, fallback):
    """The single band whose age range contains `age`. Keeps the band consistent
    with the headline number — no Gen-Z/Millennial bucketing."""
    for bid, b in rubric["age_bands"].items():
        rng = b["approx_age_2025"]
        if rng.endswith("+"):
            lo, hi = int(rng[:-1]), 200
        else:
            lo, hi = (int(x) for x in rng.split("-"))
        if lo <= age <= hi:
            return bid
    return fallback


def fired_features(analysis, total_sent):
    """Map observed aggregates → the rubric feature ids we can actually detect.
    Age uses style/emoji/volume signals only. Reply speed and slang are useful
    for archetype color, but too culturally volatile to drive an age number."""
    style = analysis.get("style", {})
    emoji = analysis.get("emoji", {})
    fired = []

    # Laughter — fire the single dominant laugh token.
    dom = (style.get("dominant_laugh") or "").lower()
    if dom in ("skull", "sob"):
        fired.append("laugh_skull_or_sob")
    elif dom == "joy":
        fired.append("laugh_joy_nonironic")
    elif dom == "lol":
        fired.append("laugh_lol_nonironic")
    elif dom in ("haha", "hehe"):
        fired.append("laugh_haha")

    # Capitalization.
    low = style.get("pct_all_lowercase")
    if low is not None:
        if low >= 40:
            fired.append("all_lowercase")
        elif low <= 12:
            fired.append("proper_caps")

    # End-of-message period.
    per = style.get("pct_end_period")
    if per is not None:
        if per >= 25:
            fired.append("period_end_short")
        elif per <= 12:
            fired.append("no_period")

    if (style.get("pct_ellipsis") or 0) >= 10:
        fired.append("ellipsis_connector")
    if (style.get("pct_repeated_exclaim") or 0) >= 8:
        fired.append("repeated_exclaim")
    if (style.get("pct_emoji_ending") or 0) >= 15:
        fired.append("emoji_as_punctuation")

    emoji_pct = emoji.get("pct_messages_with_emoji")
    if emoji_pct is not None:
        if emoji_pct >= 30:
            fired.append("inline_emoji_heavy")
        elif emoji_pct <= 5:
            fired.append("inline_emoji_sparse")

    active_days = style.get("active_days")
    if total_sent and active_days:
        per_day = total_sent / active_days
        if per_day < 10:
            fired.append("low_volume")
        elif per_day >= 45:
            fired.append("high_volume")

    return fired


def main():
    ap = argparse.ArgumentParser(description="Estimate a playful texting-age band.")
    ap.add_argument("--analysis", required=True)
    ap.add_argument("--total-sent", type=int, default=None)
    args = ap.parse_args()

    try:
        with open(args.analysis) as f:
            analysis = json.load(f)
        with open(RUBRIC_PATH) as f:
            rubric = json.load(f)
    except FileNotFoundError as e:
        print(json.dumps({"error": "file not found", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON", "detail": str(e)}), file=sys.stderr)
        sys.exit(2)

    weight_values = rubric["scoring_logic"]["weight_values"]
    by_id = {f["id"]: f for f in rubric["features"]}
    bands = list(rubric["age_bands"].keys())

    style = analysis.get("style", {})
    sample_size = style.get("sample_size")
    active_days = style.get("active_days")
    language = (style.get("language") or style.get("dominant_language") or "en").lower()
    if not language.startswith("en"):
        print(json.dumps({"error": "texting age calibrated for English-language corpora", "suppressed_reason": "non_english_corpus"}), file=sys.stderr)
        sys.exit(2)
    if sample_size is None or sample_size < MIN_AGE_SAMPLE_SIZE:
        print(json.dumps({"error": "not enough outbound texts for a playful age card", "suppressed_reason": "sample_size_too_small"}), file=sys.stderr)
        sys.exit(2)
    if active_days is None or active_days < MIN_ACTIVE_DAYS:
        print(json.dumps({"error": "not enough active texting days for a playful age card", "suppressed_reason": "active_days_too_small"}), file=sys.stderr)
        sys.exit(2)

    fired = [fid for fid in fired_features(analysis, args.total_sent) if fid in by_id]
    if len(fired) < MIN_AGE_EVIDENCE:
        print(json.dumps({"error": "not enough observable age features", "fired": fired}), file=sys.stderr)
        sys.exit(2)

    totals = {b: 0.0 for b in bands}
    sum_weights = 0.0
    for fid in fired:
        feat = by_id.get(fid)
        if not feat:
            continue
        w = weight_values.get(feat["weight"], 1)
        sum_weights += w
        for b in bands:
            totals[b] += feat["points"].get(b, 0) * w

    scores = {b: (totals[b] / sum_weights if sum_weights else 0) for b in bands}
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    (top_id, top_s), (second_id, second_s) = ranked[0], ranked[1]

    # A single whole-number age, even if it's a best-guess: blend the band
    # midpoints weighted by their normalized scores.
    MIDPOINTS = {"gen_z": 20, "millennial": 35, "gen_x": 51, "boomer_plus": 72}
    score_sum = sum(scores.values()) or 1
    estimated_age = round(sum(scores[b] * MIDPOINTS.get(b, 40) for b in bands) / score_sum)

    label_of = lambda b: rubric["age_bands"][b]["label"]
    # Single band, derived from the estimated NUMBER so the label and the number
    # never disagree (and Gen Z / Millennial never get bucketed together).
    num_band = band_for_age(rubric, estimated_age, top_id)
    # Confidence reflects how decisive the score spread is.
    if second_s == 0 or top_s >= 2 * second_s:
        confidence = "high"
    elif (top_s - second_s) / top_s <= 0.20:
        confidence = "low"
    else:
        confidence = "medium"

    # Drivers: the fired features, strongest weight first (top 3), human labels.
    # Drivers: the features that most SPECIFICALLY pulled this user toward
    # their predicted band — not just whatever has the heaviest static weight.
    # Score each fired feature by its weighted contribution to num_band minus
    # the average contribution across all bands. Drop drivers that net-pull
    # AWAY from num_band — they fired but confuse the "why" story (e.g. a
    # signal that points elsewhere shouldn't appear as the reason we landed
    # on Millennial). Top 3 by that contribution.
    band_keys = list(bands)
    def specificity(feat):
        w = weight_values.get(feat["weight"], 1)
        pts = feat["points"]
        target = pts.get(num_band, 0)
        avg = sum(pts.get(b, 0) for b in band_keys) / len(band_keys)
        return (target - avg) * w
    fired_feats = [by_id[f] for f in fired if f in by_id]
    driver_labels = [d["label"] for d in
                     sorted([f for f in fired_feats if specificity(f) > 0],
                            key=specificity, reverse=True)[:3]]
    if len(driver_labels) < MIN_AGE_EVIDENCE:
        print(json.dumps({"error": "not enough explainable age evidence", "fired": fired}), file=sys.stderr)
        sys.exit(2)

    age = {
        "estimated_age": estimated_age,
        "band": num_band,
        "generation_band": num_band,
        "generation_scores": scores,
        "label": label_of(num_band),
        "approx_age": rubric["age_bands"][num_band]["approx_age_2025"],
        "confidence": confidence,
        "drivers": driver_labels,
        "sample_size": sample_size,
        "active_days": active_days,
        "evidence_count": len(fired),
    }
    print(json.dumps({"age": age}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
