# Remote MCP implementation

Based on origin/main e515278, including merged PRs through #36. PR #22 (Intel build support) remains open and was not folded into this feature.

Implemented Advanced settings account/pairing/host controls, a Clerk-backed account page, per-Mac OAuth/PKCE capabilities, the outbound WSS local host, strict read/text-draft boundary, authentication-content filtering, Keychain credentials, local remote-draft provenance, standalone relay packaging exclusion, release configuration and version-bump maintenance.

Validation: Swift build plus 796 tests (2 skipped), 55 Ghostie Bun tests, 18 relay tests, Bun typechecks, experience suite, release packaging/version-bump fixture, and compiled shared backend. Synthetic data only. No personal message reads, account provisioning, relay deployment, installed-app replacement or signed release performed.

Review: independent gpt-5.5 found one packaging critical and four warnings. Dispositions and fixes are in docs/plans/clerk-remote-mcp.md.review.md; follow-up verification is in runs/reviews/clerk-remote-verification-codex.txt. Claude review was attempted but unavailable due to expired login.

Known launch boundary: configure Clerk and a persistent HTTPS/WSS relay, register real MCP client callbacks, and exercise browser/CAPTCHA, TLS, Keychain restart, two accounts/Macs and sleep/quit behavior before public enablement. TLS protects transport; relay sees in-memory content, and existing local stores are not newly encrypted. Authentication filtering is best-effort. Setup and deployment details: mcps/remote-relay/README.md.
