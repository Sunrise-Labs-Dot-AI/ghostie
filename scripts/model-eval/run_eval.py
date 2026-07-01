#!/usr/bin/env python3
"""Model eval for Messages for AI's AI-powered functions.

Runs each lab's REAL prompt shape (extracted from the app source) against
candidate models via the locally-authenticated CLIs (`claude -p` for
Anthropic, `codex exec` for OpenAI) and scores:
  - dont_ghost:     should-reply accuracy vs designed ground truth + JSON validity
  - work_personal:  label accuracy vs ground truth + JSON validity
  - eq:             judge-scored (insight, groundedness, no-invention)
  - texting_voice:  JSON validity + constraint compliance + judge-scored quality

Synthetic fixtures only — no real message data ever leaves the machine.
Latency includes CLI startup overhead (comparable across models).

Usage: python3 scripts/model-eval/run_eval.py [--models m1,m2] [--out results.json]
"""

import argparse
import concurrent.futures
import json
import re
import subprocess
import time
from pathlib import Path

CLAUDE_MODELS = ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"]
OPENAI_MODELS = ["gpt-5.5"]  # mini-tier not available via ChatGPT-account codex

# ---------------------------------------------------------------- fixtures

DONT_GHOST_THREADS = [
    {"id": 1, "person": "Priya", "last_inbound_at": "2026-06-08T19:04:00Z", "messages": [
        {"from": "them", "sent_at": "2026-06-08T19:02:00Z", "body": "hey! are you around the weekend of the 20th?"},
        {"from": "them", "sent_at": "2026-06-08T19:04:00Z", "body": "thinking of doing a small dinner for Dev's birthday, would love you there"},
    ]},
    {"id": 2, "person": "Mark", "last_inbound_at": "2026-06-09T08:30:00Z", "messages": [
        {"from": "me", "sent_at": "2026-06-09T08:28:00Z", "body": "package is on the porch"},
        {"from": "them", "sent_at": "2026-06-09T08:30:00Z", "body": "got it, thanks!"},
    ]},
    {"id": 3, "person": "Sam", "last_inbound_at": "2026-06-07T22:15:00Z", "messages": [
        {"from": "them", "sent_at": "2026-06-07T22:10:00Z", "body": "honestly this week has been really rough"},
        {"from": "them", "sent_at": "2026-06-07T22:15:00Z", "body": "the job stuff fell through again. idk."},
    ]},
    {"id": 4, "person": "Dentist Reminders", "last_inbound_at": "2026-06-09T15:00:00Z", "messages": [
        {"from": "them", "sent_at": "2026-06-09T15:00:00Z", "body": "Reminder: your cleaning appointment is Thursday 6/12 at 2:00 PM. Reply C to confirm."},
        {"from": "me", "sent_at": "2026-06-09T15:01:00Z", "body": "C"},
        {"from": "them", "sent_at": "2026-06-09T15:01:30Z", "body": "Confirmed. See you Thursday!"},
    ]},
    {"id": 5, "person": "Jess", "last_inbound_at": "2026-06-06T13:20:00Z", "messages": [
        {"from": "me", "sent_at": "2026-06-06T13:00:00Z", "body": "we should grab coffee soon!"},
        {"from": "them", "sent_at": "2026-06-06T13:20:00Z", "body": "yes!! how's tuesday or wednesday next week for you?"},
    ]},
    {"id": 6, "person": "Alex", "last_inbound_at": "2026-06-09T11:45:00Z", "messages": [
        {"from": "me", "sent_at": "2026-06-09T11:40:00Z", "body": "running 10 late"},
        {"from": "them", "sent_at": "2026-06-09T11:45:00Z", "body": "no worries, see you soon"},
    ]},
]
# Ground truth: threads that deserve a reply.
DONT_GHOST_TRUTH = {1: True, 2: False, 3: True, 4: False, 5: True, 6: False}

DONT_GHOST_PROMPT = """You are helping find text threads where the user may be unintentionally ghosting someone.

A deterministic local pass already selected threads where the other person sent the last substantive message and removed obvious transactional/business threads.

Your job: decide whether the conversation naturally concluded or whether a thoughtful person would still probably reply.
Do not flag clear acknowledgements, completed logistics, reactions that need no answer, stale threads where replying would be odd, spam, or threads where the last inbound message is informational and complete.
Prefer socially meaningful misses: invitations, questions, emotional bids, updates that invite care, loose plans, unresolved asks, or messages where silence could read as dropping the ball.

Return strict JSON only:
{"threads":[{"id":123,"should_reply":true,"reason":"short reason","confidence":0.0}]}

Threads:
""" + json.dumps(DONT_GHOST_THREADS, indent=1)

WP_BATCH = {
    "work_description": "I'm a freelance product designer. Work = client projects, invoices, Figma reviews, contracts, scheduling with clients, my design Slack community.",
    "messages": [
        {"id": "m1", "person_label": "unknown", "text": "Can you send the updated invoice for the May sprint?"},
        {"id": "m2", "person_label": "personal", "text": "mom's birthday dinner is saturday 7pm, don't forget"},
        {"id": "m3", "person_label": "work", "text": "lunch tomorrow? no work talk I promise lol"},
        {"id": "m4", "person_label": "unknown", "text": "The contract redlines came back, legal wants the IP clause changed"},
        {"id": "m5", "person_label": "unknown", "text": "ur package was delivered to the front desk"},
        {"id": "m6", "person_label": "personal", "text": "hey can you review my portfolio site? thinking of hiring you for our startup's redesign"},
        {"id": "m7", "person_label": "unknown", "text": "did you see the game last night???"},
        {"id": "m8", "person_label": "work", "text": "Figma file is ready for your pass, client review is thursday"},
    ],
}
WP_TRUTH = {"m1": "work", "m2": "personal", "m3": "personal", "m4": "work",
            "m5": "neither", "m6": "work", "m7": "personal", "m8": "work"}

WP_PROMPT = """Classify each message as work, personal, both, or neither.

Use the user's work description as the main definition of work. Person labels are hints only; message content wins when it clearly differs.

Return JSON only in this shape:
{"labels":[{"id":"...","label":"work|personal|both|neither","confidence":0.0,"reason":"short phrase"}]}

Do not include message text in the output.

Input:
""" + json.dumps(WP_BATCH, indent=1)

EQ_PROMPT = """You are a thoughtful relationship-reflection assistant. The user asked: "Where is Maya making bids for attention, support, play, repair, or help, and how am I responding?"

Relationship context: friend.

Recent conversation excerpts (most recent last):
[3 weeks ago] Maya: "saw this and thought of you" [link]
[3 weeks ago] Me: "ha nice"
[2 weeks ago] Maya: "I think I'm going to quit my job. like actually this time"
[2 weeks ago] Me: "whoa big! let's talk this weekend?"
[2 weeks ago] Maya: "yes please"
[12 days ago] Maya: "are we still on for this weekend?"
[12 days ago] Me: "ugh I'm slammed, rain check?"
[5 days ago] Maya: "how are youuu"
[4 days ago] Me: "good! busy! you?"
[5 hours ago] Maya: "guess who put in their two weeks notice 😬"

Ground your reflection ONLY in these excerpts. Identify the bids, characterize the response pattern honestly but kindly, and suggest 2-3 small concrete actions. Do not invent events or details not present in the excerpts. Keep it under 250 words."""

VOICE_GUIDE = """# Texting Style: Close Friends

## Rhythm
- Bursts of 2-3 short messages rather than one long one.
- Replies fast when engaged; gaps mean busy, not cold.

## Tone
- Lowercase, casual. "lol", "omg", occasional ALL CAPS for emphasis.
- Affection through teasing.

## Punctuation
- Rarely uses periods. Exclamation marks common. No emoji in serious moments.

_Privacy note: built from aggregate style patterns only; no message contents are stored._"""

VOICE_PROMPT = """Revise this local texting style guide using the user's instruction.

Privacy constraints:
- You are not receiving message bodies.
- You are not receiving contact names, phone numbers, emails, or raw recipient labels.
- Do not ask for message bodies.
- Do not invent specific events, memories, opinions, or relationships.
- Preserve the guide's practical drafting value.
- Keep the final privacy note.

Return strict JSON only:
{
  "profile_id": "close-friends",
  "markdown": "# ...\\n..."
}

Profile: Close Friends

User instruction:
Make the guide reflect that I want to come across as warmer and more emotionally available in serious moments, without losing the playful tone elsewhere. Add a short section on how to respond when a friend shares hard news.

Current guide:
""" + VOICE_GUIDE

TASKS = {
    "dont_ghost": DONT_GHOST_PROMPT,
    "work_personal": WP_PROMPT,
    "eq": EQ_PROMPT,
    "texting_voice": VOICE_PROMPT,
}

# ---------------------------------------------------------------- runners

def run_claude(model: str, prompt: str) -> tuple[str, float]:
    start = time.monotonic()
    proc = subprocess.run(
        ["claude", "-p", "--model", model, "--strict-mcp-config",
         "--mcp-config", '{"mcpServers":{}}', "--max-turns", "1"],
        input=prompt, capture_output=True, text=True, timeout=600, cwd="/tmp",
    )
    return proc.stdout.strip(), time.monotonic() - start


def run_codex(model: str, prompt: str) -> tuple[str, float]:
    start = time.monotonic()
    proc = subprocess.run(
        ["codex", "exec", "--skip-git-repo-check", "-m", model,
         "--sandbox", "read-only", prompt],
        capture_output=True, text=True, timeout=600, cwd="/tmp",
    )
    # codex prints token count on the penultimate line sometimes; take the
    # final message block (everything after the last blank line is fragile —
    # codex exec's last stdout line(s) are the agent's final message).
    return proc.stdout.strip(), time.monotonic() - start


def run_one(model: str, task: str, prompt: str) -> dict:
    try:
        if model.startswith("claude"):
            output, seconds = run_claude(model, prompt)
        else:
            output, seconds = run_codex(model, prompt)
        return {"model": model, "task": task, "output": output,
                "latency_s": round(seconds, 1), "error": None}
    except Exception as error:  # timeout, CLI failure
        return {"model": model, "task": task, "output": "",
                "latency_s": None, "error": str(error)}

# ---------------------------------------------------------------- scoring

def extract_json(text: str):
    """Pull the first JSON object out of possibly-chatty output."""
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    candidates = [fenced.group(1)] if fenced else []
    brace = text.find("{")
    if brace >= 0:
        candidates.append(text[brace:text.rfind("}") + 1])
    for candidate in candidates:
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, ValueError):
            continue
    return None


def score_dont_ghost(output: str) -> dict:
    parsed = extract_json(output)
    if not parsed or "threads" not in parsed:
        return {"json_valid": False, "accuracy": 0.0}
    decisions = {row.get("id"): bool(row.get("should_reply")) for row in parsed["threads"]}
    # The app keeps only should_reply=true rows; an omitted thread counts as False.
    correct = sum(1 for tid, truth in DONT_GHOST_TRUTH.items()
                  if decisions.get(tid, False) == truth)
    return {"json_valid": True, "accuracy": round(correct / len(DONT_GHOST_TRUTH), 2)}


def score_work_personal(output: str) -> dict:
    parsed = extract_json(output)
    if not parsed or "labels" not in parsed:
        return {"json_valid": False, "accuracy": 0.0}
    labels = {row.get("id"): row.get("label") for row in parsed["labels"]}
    correct = sum(1 for mid, truth in WP_TRUTH.items() if labels.get(mid) == truth)
    return {"json_valid": True, "accuracy": round(correct / len(WP_TRUTH), 2)}


def score_texting_voice(output: str) -> dict:
    parsed = extract_json(output)
    if not parsed or "markdown" not in parsed:
        return {"json_valid": False, "constraints": 0.0}
    markdown = parsed["markdown"]
    checks = [
        "privacy note" in markdown.lower(),                  # kept the privacy note
        "hard news" in markdown.lower() or "serious" in markdown.lower(),  # new section
        parsed.get("profile_id") == "close-friends",
        len(markdown) > 300,                                 # didn't gut the guide
    ]
    return {"json_valid": True, "constraints": round(sum(checks) / len(checks), 2)}

# ---------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", default=",".join(CLAUDE_MODELS + OPENAI_MODELS))
    parser.add_argument("--out", default="model-eval-raw.json")
    args = parser.parse_args()
    models = [m.strip() for m in args.models.split(",") if m.strip()]

    jobs = [(model, task, prompt) for model in models for task, prompt in TASKS.items()]
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(run_one, *job) for job in jobs]
        for future in concurrent.futures.as_completed(futures):
            row = future.result()
            scorer = {"dont_ghost": score_dont_ghost,
                      "work_personal": score_work_personal,
                      "texting_voice": score_texting_voice}.get(row["task"])
            row["scores"] = scorer(row["output"]) if (scorer and not row["error"]) else {}
            results.append(row)
            print(f"done: {row['model']} / {row['task']} "
                  f"({row['latency_s']}s) {row['scores'] or ''} "
                  f"{('ERROR: ' + row['error']) if row['error'] else ''}")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(results, indent=1))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
