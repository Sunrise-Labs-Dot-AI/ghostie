# AGENTS.md: menubar/

Inherits the repo root AGENTS.md. The SwiftUI menu bar app (SwiftPM, macOS 14+): the UI, the draft-approval surface, and all health / walkthrough logic. It launches the daemons, so its grant is what carries Full Disk Access.

## What's here

- `Sources/MessagesForAIMenu/` (controllers, `DesignSystem/`), `Tests/`, `Assets/`, `Package.swift`, and `scripts/` (dev-install + entitlements for the .app).

## Working rules

- After Swift changes: `cd menubar && rm -f .build/build.db && swift build && swift test`. `Build complete!` plus passing tests is the real signal; the `accessing build database ... disk I/O error` is a known coalition artifact, not a failure.
- The app launches the daemons, so Full Disk Access is launcher-attributed to it; Claude / Codex never need FDA themselves.
- Codesign: one identifier (`com.sunriselabs.messages-for-ai`) per inner Mach-O, seal with NO `--deep`, sign each inner binary with its own `--entitlements` (Bun JIT needs them).

## Don't

- Never add an auto-send path: the scheduled-send surface only fires drafts explicitly approved in the GUI, and fails closed.
- Never surface raw message bodies; sanitize names/free-text into LLM prompts (see `BirthdayReviewPrompt.sanitize`).
- Don't trust the build exit code over the `Build complete!` line plus green tests.

## Canonical doc

Repo `CLAUDE.md` (Layout, Build & dev loop) and root `AGENTS.md` (Load-bearing gotchas).
