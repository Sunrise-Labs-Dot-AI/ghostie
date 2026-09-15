# Trusted relay v1 acceptance, 2026-09-15

## Scope and release status

James approved the trusted-relay privacy model and instructed build and ship. He separately approved transfer of the existing Ghostie production Clerk secret to this dedicated Railway service. Clerk app rename to Ghostie is verified. No app release has been published in this rollout. Public launch still requires live identity/client acceptance and signed local-app QA; James runs the final notarized release from his Terminal.

## Production resources

- URL: https://connect.messagesfor.ai
- Railway project: ghostie-remote-relay, `29d738a2-efd5-4300-9df1-62fb91b27aa5`
- Production environment: `f2926fbf-e990-4175-8791-79e5b60b8373`
- Relay service: `2470b3b8-029d-4046-a7d0-bf7ba9687c9b`
- Metadata volume: `13daa279-1e0c-4a29-8f59-02757cc887d1`, `/data`
- First deployment: `1679cf1c-7fac-4d5c-ad78-7b8e30775da5`, initializing at last check
- One replica, US West California, Dockerfile builder, port 8080, `/health`, three failure retries. Serverless and CDN caching off.
- Clerk production Frontend API: https://clerk.messagesfor.ai, existing primary domain messagesfor.ai. No account security or login-method changes.
- Static Claude client: `ghostie-claude`, exact callback https://claude.ai/api/mcp/auth_callback, public client (no secret).
- DNS adds only `connect` CNAME and Railway verification TXT. Marketing and Clerk records unchanged.

Upload from `mcps/remote-relay`:

```sh
npx --yes @railway/cli@5.57.2 up . --path-as-root \
  --project 29d738a2-efd5-4300-9df1-62fb91b27aa5 \
  --environment f2926fbf-e990-4175-8791-79e5b60b8373 \
  --service 2470b3b8-029d-4046-a7d0-bf7ba9687c9b --detach --json
```

Never print raw Railway environment config or variables: production secrets are configured. Request only selected non-secret fields. Source upload contains only the relay directory; Docker context excludes tests and local state.

## Verification completed

- Relay: 18 tests, 57 assertions, typecheck pass.
- Mac remote facade: 56 tests, 168 assertions, typecheck pass.
- Swift: build complete; 796 tests, two skipped, zero failures.
- Remote release packaging contract: pass.
- Exact production image: local build and container smoke pass. Verified unauthenticated refusal, WSS upgrade forwarding, synthetic request/response, no-store, no raw credentials or bodies in SQLite/logs, disabled core dumps, offline 503, container failure when proxy dies.
- Independent deployment code review: no blockers for live acceptance, public release still gated. Claude Opus review attempt failed due expired OAuth; independent Codex gpt-5.5 substitute used. Review artifacts in `runs/reviews/trusted-relay-*`.
- Release preflight on feature branch correctly refused non-main. Repeat after merge, without bypassing branch check.

## Still required

Live Clerk and real hosted/desktop OAuth, live deployment log inspection, signed local app account/Keychain/offline/draft review, final CI/merge and James-run release. Keep the default public service unset until live acceptance supports enabling it.
