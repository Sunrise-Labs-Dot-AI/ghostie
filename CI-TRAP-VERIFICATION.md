# CI trap verification (throwaway)

This file exists only to open a **docs-only PR** that touches nothing but a
paths-ignored path (`**/*.md`). It verifies the fix from PR #5: the required
checks (`bun-test` ×2, `swift-build`, `pii-guard`, `site-metadata`) must all
post a result on this PR — `swift-build` as **skipped** (app=false) and
`bun-test` as **pass** — so branch protection reports the PR as mergeable
without `--admin`, instead of parking it at "Expected — waiting for status".

Delete this file / close this PR after verification.
