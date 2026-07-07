# Adversarial review — PR #5 (CI docs-only-PR required-check trap)

- **PR:** https://github.com/Sunrise-Labs-Dot-AI/ghostie/pull/5
- **Diff reviewed:** `3184d82..HEAD` (test.yml: `paths-ignore` pull_request→job-level `if`; swift-build gated + fail-safe; bun-test always-run)
- **Reviewer lane:** Codex (alternative model to the Claude authoring lane), review-only. Plan-review folded into this diff review, given the small, constrained change.
- **Local verification:** actionlint clean; PR #5 CI fully green (swift-build/swift-test ran for real; all 5 required checks + experience-evals passed).

## Core verdict

Approach sound. Codex independently confirmed the load-bearing GitHub semantic: **a job skipped via `if:` reports success and satisfies a required status check, whereas a workflow skipped by a path filter leaves the required context pending (blocking).** That is exactly the difference this PR exploits.

## Findings & dispositions

### 1. detect-changes failure could skip swift-build → skipped-as-pass without compiling — non-blocking → **FIXED**

If `detect-changes` fails (not skips), `swift-build` (`needs: detect-changes`) would be skipped, and a skipped required check counts as passed — so a broken compile could merge because the gate never ran.

- **Fix:** hardened swift-build's `if` to `${{ !cancelled() && (needs.detect-changes.outputs.app == 'true' || needs.detect-changes.result != 'success') }}` — it now runs a real build whenever detect-changes didn't cleanly report app=false, so a detect-changes failure fails safe (builds) instead of fail-open (skips). Docs-PR skip preserved (app=false + detect-changes success → skip). actionlint clean.

### 2. bun-test left always-run — non-blocking → **confirmed correct, no change**

Codex agreed: required contexts are per-matrix-cell (`bun-test (${{ matrix.mcp }})`); always running is safer than relying on per-cell skipped-check posting. Documented inline.

### 3. Docs PRs now run bun-test; `site/*.md` sets site=true so site jobs run — non-blocking → **accepted, no change**

By design: bun-test is cheap Linux and must always post; site jobs running on site-markdown changes is harmless.

### 4. App PRs now wait on detect-changes (extra job + failure point) — nit → **addressed by #1**

The #1 fail-safe makes a detect-changes failure build rather than silently pass, so the added dependency can't fail-open.

### 5. `paths-ignore` kept on push only — nit → **intentional**

Branch protection evaluates required checks on PR heads; push has no merge gate, so keeping its `paths-ignore` saves macOS minutes with no trap risk. Documented inline.

### 6. Codex couldn't confirm live branch protection via `gh api` (its network failed) — nit → **verified by orchestrator**

Confirmed earlier from a networked shell: required contexts are exactly `pii-guard`, `site-metadata`, `bun-test (mcps/imessage-drafts)`, `bun-test (mcps/whatsapp-drafts)`, `swift-build`.

## Post-merge verification (pending)

A `pull_request` evaluates the workflow from the merged tree, so docs-only behavior can only be exercised with the fix on `main`. After merge: open a throwaway docs-only PR, confirm all 5 required checks post (swift-build = skipped, bun-test ×2 = success) and it's mergeable without `--admin`.
