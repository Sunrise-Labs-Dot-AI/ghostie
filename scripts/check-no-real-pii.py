#!/usr/bin/env python3
"""Fail if the tracked tree contains real (non-fictional) contact data.

This is a privacy guard for open-source safety. Real phone numbers and real
contacts' emails must never enter the repo: fixtures and docs use fictional
equivalents only. The guard exists because a prior scrub of real test data
regressed when later feature PRs reintroduced real numbers, and there was no
gate to catch it.

Allowed (fictional) conventions:
  * NANP phone numbers with area code 555 (e.g. +1 555 123 4567) OR exchange
    555 (the reserved 555-01xx range, e.g. +1 (215) 555-0172).
  * Toll-free numbers (area code 800/833/844/855/866/877/888).
  * A small, documented sentinel allowlist (invalid/edge-case test inputs).
  * Emails at example.com (and example.org/net) plus any non-personal domain.

Flagged (real-looking):
  * Any other +1 NANP number, in E.164, (NPA) NXX-XXXX, or NPA-NXX-XXXX form.
  * Any US NANP number embedded in a whatsapp user JID (<digits>@s.whatsapp.net).
  * Any email at a consumer-mailbox domain other than example.* .

Usage:
  scripts/check-no-real-pii.py           # scan the whole tracked tree
  scripts/check-no-real-pii.py <paths>   # scan only the given paths (pre-commit)

Exit code 0 = clean, 1 = violations found (each printed as file:line).
Portable: standard library only, runs on macOS and Linux CI.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

TOLL_FREE = {"800", "833", "844", "855", "866", "877", "888"}

# Deliberately invalid / structurally-mangled test inputs that are obviously
# not real numbers. Keep this list short and documented; do not add real values.
SENTINELS = {
    "+19998887777",   # "unknown / not-a-real-number" fixture
    "+19999999999",   # all-nines invalid-input fixture
    "+16780571484304",  # 14-digit over-long malformed-handle edge case
}

# Consumer mailbox providers. An address here at any domain other than the
# example.* reserved domains is treated as a real person's address.
PERSONAL_EMAIL = re.compile(
    r"[A-Za-z0-9._%+-]+@"
    r"(?:gmail|googlemail|icloud|me|mac|yahoo|ymail|hotmail|outlook|live|"
    r"msn|aol|proton|protonmail|pm|gmx|fastmail)\."
    r"(?:com|net|org|co\.uk|me|us|de|fr)",
    re.IGNORECASE,
)

E164 = re.compile(r"\+1(\d{10})(?!\d)")
US_PAREN = re.compile(r"\((\d{3})\)\s*(\d{3})-(\d{4})")
US_DASH = re.compile(r"(?<!\d)(\d{3})-(\d{3})-(\d{4})(?!\d)")
US_DOT = re.compile(r"(?<!\d)(\d{3})\.(\d{3})\.(\d{4})(?!\d)")
US_SPACE = re.compile(r"\+1 (\d{3}) (\d{3}) (\d{4})(?!\d)")
WA_JID = re.compile(r"(?<!\d)1(\d{10})@s\.whatsapp\.net")

# Extensions that are binary or otherwise never contain scannable text.
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".pdf",
    ".zip", ".gz", ".mov", ".mp4", ".woff", ".woff2", ".ttf", ".otf",
    ".lock", ".resolved", ".sqlite", ".db",
}

SELF = "scripts/check-no-real-pii.py"


def is_fictional(area: str, exchange: str, full: str) -> bool:
    """True when a NANP (area, exchange) pair is a reserved-fictional value."""
    if area == "555" or exchange == "555":
        return True
    if area in TOLL_FREE:
        return True
    # Structurally-invalid NANP (a valid area code or exchange never starts with
    # 0 or 1) can never be a real assigned number, so it is a placeholder, e.g.
    # (212) 000-0000.
    if area[0] in "01" or exchange[0] in "01":
        return True
    if full in SENTINELS:
        return True
    return False


def scan_line(line: str) -> list[str]:
    """Return a list of human-readable reasons this line is a violation."""
    reasons: list[str] = []

    for digits in E164.findall(line):
        full = "+1" + digits
        if not is_fictional(digits[0:3], digits[3:6], full):
            reasons.append(f"real phone number {full}")

    for area, exchange, last in US_PAREN.findall(line):
        if not is_fictional(area, exchange, f"({area}) {exchange}-{last}"):
            reasons.append(f"real phone number ({area}) {exchange}-{last}")

    for area, exchange, last in US_DASH.findall(line):
        if not is_fictional(area, exchange, f"{area}-{exchange}-{last}"):
            reasons.append(f"real phone number {area}-{exchange}-{last}")

    for area, exchange, last in US_DOT.findall(line):
        if not is_fictional(area, exchange, f"{area}.{exchange}.{last}"):
            reasons.append(f"real phone number {area}.{exchange}.{last}")

    for area, exchange, last in US_SPACE.findall(line):
        if not is_fictional(area, exchange, f"+1 {area} {exchange} {last}"):
            reasons.append(f"real phone number +1 {area} {exchange} {last}")

    for digits in WA_JID.findall(line):
        full = "+1" + digits
        if not is_fictional(digits[0:3], digits[3:6], full):
            reasons.append(f"real phone number in JID {digits}@s.whatsapp.net")

    for match in PERSONAL_EMAIL.finditer(line):
        addr = match.group(0)
        domain = addr.split("@", 1)[1].lower()
        if not domain.startswith("example."):
            reasons.append(f"real personal email {addr}")

    return reasons


def tracked_files(paths: list[str]) -> list[str]:
    args = ["git", "ls-files", "-z"] + paths
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return [f for f in out.split("\0") if f]


def main(argv: list[str]) -> int:
    files = tracked_files(argv[1:])
    violations: list[str] = []

    for rel in files:
        if rel == SELF:
            continue
        if Path(rel).suffix.lower() in SKIP_EXT:
            continue
        try:
            text = Path(rel).read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            for reason in scan_line(line):
                violations.append(f"{rel}:{lineno}: {reason}")

    if violations:
        print("PII guard FAILED: real contact data found in tracked files.")
        print("Replace with fictional equivalents (555 numbers, example.com).")
        print("")
        for v in violations:
            print("  " + v)
        print("")
        print(f"{len(violations)} violation(s).")
        return 1

    print("PII guard OK: no real phone numbers or personal emails in the tree.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
