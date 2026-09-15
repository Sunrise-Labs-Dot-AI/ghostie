# Railway compatibility probe, 2026-09-15

Status: local fixture verified, live hosted-client checks pending. Not a product release or encryption-against-relay claim.

## Provisioned temporary resources
- Railway project: ghostie-compatibility-probe, 17c8e223-d82b-4cf3-b5f0-b5cc2027be8f.
- Service: synthetic-status, ea8b09df-d6d3-4e51-85e4-7bf05baceca0.
- Environment: ae8471e9-0951-4704-bdfd-c2de21035df3 (default label production; contains only this synthetic experiment).
- TCP proxy: f72ea0ef-0908-49ae-8a98-1667bea2ec4b, trolley.proxy.rlwy.net:37763 -> 9443.
- Dedicated public URL: https://railway-probe.ghostie.app:37763/mcp.
- Disposable public certificate issued for that single probe subdomain. Key/config outside repo; never product credentials. ACME challenge TXT record rec_d040e396a092e4ac42a94490 removed after issuance.

## Evidence
- 7 local tests, 17 assertions, typecheck passed: SDK initialize/list/call over verified TLS and a nonstandard port; untrusted certificates and hostname mismatch refused; unknown tools/arguments, oversized and malformed input refused; no OAuth claims; incomplete TLS config refused.
- Claude URL-format preflight reached connection validation for a nonstandard-port URL. No real server was running at the preliminary address; its unreachable result is not a port-compatibility verdict. No connector created during format preflight.
- Chrome ChatGPT account is currently a Sunrise Labs workspace Member. Owner is a separate Sunrise Labs login. Developer-mode switch is disabled; owner login requested. No security or permission settings changed.
- Plan review initially BLOCK; sequencing corrected to test hosted-client port compatibility before custom tunnel. Independent verification PASS for Stage 0 only.
- Code review found missing container bind override and ambiguous upload root. Dockerfile and README corrected; verification pending.

## Remaining gates
Live SDK and hosted-client calls, cleanup verification, independent code-review follow-up, CI and merge. Stage 1 encrypted reverse tunnel remains gated on both real hosted clients passing. No messages, local daemons, Clerk secrets or real draft actions are exposed.
