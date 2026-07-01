# texting-analytics

A Claude/ChatGPT skill that turns the iMessage MCP into a personal Texting Wrapped. Pulls your message history, runs reply-latency and group-contribution analysis, and ships a markdown report plus four shareable PNG charts.

Part of the [messagesfor.ai](https://messagesfor.ai) suite.

## What you get

Run this skill and you get a folder with:

- `report.md` — your findings, in PM-voice, with the receipts.
- `01-latency.png` — how fast you actually reply.
- `02-ball-in-court.png` — what % of your active threads are waiting on you.
- `03-gap.png` — the mean vs median reply-time gap (the part that hurts).
- `04-group-contribution.png` — your share of messages in group threads, with a substantive-vs-reactions split.

See `examples/` for what these look like with sample data.

## Requirements

- A Mac (this reads `chat.db`).
- The [iMessage MCP](https://github.com/Sunrise-Labs-Dot-AI/imessage-mcp) installed and granted Full Disk Access.
- Claude Desktop, Claude Code, ChatGPT Desktop, or any MCP-capable LLM client.
- Python 3.10+ with `matplotlib`. The skill installs `matplotlib` if missing.

## Install

```bash
git clone https://github.com/Sunrise-Labs-Dot-AI/messagesfor-ai-suite.git ~/Documents/messagesfor-ai-suite
ln -s ~/Documents/messagesfor-ai-suite/skills/texting-analytics ~/.claude/skills/texting-analytics
```

(ChatGPT and Codex install paths in the suite-level README.)

## Run

In your LLM client, just say:

> Run my texting analytics

The skill will pull data, run analysis, generate charts, and write the report.

You can customize:

- `--unbranded` to drop the brand stamp from charts.
- `--theme dark` for dark mode charts.
- `--only latency` to build just one chart at a time.

## How it works

Three phases:

1. **Pull** — the LLM uses the iMessage MCP to list and fetch your threads, locally.
2. **Analyze** — the LLM computes reply latency, ball-in-court rate, and group contribution. Writes `analysis.json`.
3. **Render** — `scripts/build_charts.py` reads `analysis.json` and renders the four PNGs.

All processing is local. Your `chat.db` doesn't leave your Mac. No cloud, no servers, no telemetry.

## What you can do with it

The analysis is the table-stakes. The interesting next moves are the other skills in the suite:

- **reply-queue** — surface threads that have been waiting on you and draft replies.
- **voice-cloned-draft** — draft replies in your texting voice, calibrated on your own corpus.
- **reconnect-agent** — find friends you haven't texted in 3+ months and suggest a check-in.
- **birthday-texts** — pull upcoming birthdays from contacts and write something specific based on conversation history.

## License

MIT. Fork it, branch it, build on it. If you ship a derivative, a credit is appreciated.
