# AGENTS.md: skills/

Inherits the repo root AGENTS.md. Claude Code skills (model-invoked how-to plus Python / JSX), surfaced via the `.claude-plugin/` manifest and dev symlinks under `.claude/skills/`.

## What's here

- `texting-analytics/` (incl. `wrapped/`, the Texting Wrapped story-card generator: `build_wrapped.py` plus Claude-Design `.jsx`), `birthday-reminder/`, `birthday-text-voice/`, `texting-voice-skill-creator/`.

## Working rules

- Skills are NOT CI-gated. Verify Python locally from the skill dir: `python3 -m unittest`.
- `bash scripts/dev-link-skills.sh` symlinks `skills/*` into `.claude/skills/` so the plugin surface picks them up in dev.
- Analytics is metadata-only EXCEPT opt-in aggregate text passes (`emoji_stats.py`, `age_estimate.py`) that emit counts only, never message bodies (guard-enforced).

## Don't

- Never emit message bodies from a skill; counts / dates / aggregates only, guards enforced.
- Don't rely on CI to catch skill regressions; it does not run them.

## Canonical doc

Repo `CLAUDE.md` (Layout: `skills/`) and `.claude-plugin/` (`plugin.json`, `marketplace.json`).
