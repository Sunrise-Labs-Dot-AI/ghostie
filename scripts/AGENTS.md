# AGENTS.md: scripts/

Inherits the repo root AGENTS.md. Release and dev-install automation for the MCP binaries and the .app, plus the native launcher shim.

## What's here

- `release.sh` (one-command lockstep release orchestrator), `build-release.sh`, `build-dmg.sh`, `bump-version.sh`, `dev-install.sh`, `dev-link-skills.sh` (symlinks `skills/*` into `.claude/skills/`), `smoke-installed-app.sh`, `messages-for-ai-launcher.c`, `model-eval/`.

## Working rules

- `release.sh` is JAMES-only, run in his own Terminal: notarytool SIGBUSes under the Claude / Codex process coalition, App Management blocks `/Applications` writes, and Sparkle's `sign_update` needs his login keychain.
- An agent's job is prep code plus verify the result via `gh` / `curl`, not run the release. `bash scripts/release.sh vX.Y.Z --dry-run` preflights without changes.
- The release zip MUST use `zip -y` (Sparkle.framework `Versions/Current` is a symlink; dropping `-y` mangles it and `spctl` rejects the app).

## Don't

- Don't run `release.sh` (or notarization) from an automation host; it cannot succeed there.
- Don't add an `ANTHROPIC_API_KEY` to any script or env; the subscription bills Claude Code.

## Canonical doc

`RELEASE.md`, `scripts/README.md`, and repo `CLAUDE.md` (Build & dev loop).
