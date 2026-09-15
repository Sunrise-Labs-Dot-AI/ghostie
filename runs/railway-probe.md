# Railway compatibility probe, 2026-09-15

Status: local and live desktop SDK passed. Claude could not connect on the assigned TCP port; standard HTTPS comparison passed. ChatGPT is blocked by workspace role. Not a product release or encryption-against-relay claim.

## Provisioned temporary resources
- Railway project: ghostie-compatibility-probe, 17c8e223-d82b-4cf3-b5f0-b5cc2027be8f.
- Service: synthetic-status, ea8b09df-d6d3-4e51-85e4-7bf05baceca0.
- Environment: ae8471e9-0951-4704-bdfd-c2de21035df3 (default label production; contains only this synthetic experiment).
- TCP proxy: f72ea0ef-0908-49ae-8a98-1667bea2ec4b, trolley.proxy.rlwy.net:37763 -> 9443.
- Dedicated public URL: https://railway-probe.ghostie.app:37763/mcp.
- Disposable public certificate issued for that single probe subdomain. Key/config outside repo; never product credentials. ACME challenge TXT record rec_d040e396a092e4ac42a94490 removed after issuance.

## Evidence
- 7 local tests, 17 assertions, typecheck passed: SDK initialize/list/call over verified TLS and a nonstandard port; untrusted certificates and hostname mismatch refused; unknown tools/arguments, oversized and malformed input refused; no OAuth claims; incomplete TLS config refused.
- Live desktop SDK passed on https://railway-probe.ghostie.app:37763/mcp using default certificate validation: initialize, tools/list, tools/call, and exact synthetic result verified. Deployment 8f98ca0b-c32c-4ef2-80f3-563652e38e65.
- Claude hosted connector on the same live URL: preflight reported no server. Manual setup with No sign-in saved the connector, but Connect failed with "Couldn’t reach Ghostie compatibility probe", reference ofid_60535c8120b2a51e. Bounded server logs contained only the earlier SDK methods. This does not yet isolate a port restriction. Failed test connector was removed.
- Controlled comparison: same synthetic handler through Railway HTTPS edge, https://synthetic-status-production.up.railway.app/mcp -> internal 9444. Deployment c25a5551-a13c-4f7c-bf91-738716111a8a succeeded. Claude preflight, connection, tool discovery and one approved tool call all passed. Returned exactly "Ghostie synthetic connection works. No messages are available." Bounded server logs recorded control initialize, tools/list and tools/call. The desktop SDK again passed against TCP port 37763 while this control was live. Inference: the assigned-port path is incompatible with this hosted Claude configuration; this does not prove that every nonstandard port is blocked or exclude hostname-specific routing differences.
- Chrome ChatGPT account is currently a Sunrise Labs workspace Member. Owner is a separate Sunrise Labs login. Developer-mode switch is disabled; owner login requested. No security or permission settings changed.
- Plan review initially BLOCK; sequencing corrected to test hosted-client port compatibility before custom tunnel. Independent verification PASS for Stage 0 only.
- Code review found missing container bind override and ambiguous upload root. Dockerfile and README corrected; independent verification passed. Optional HTTPS-control delta, live check script and CI reviewed separately: MERGE-OK, no blockers.

## Cleanup verified
- Active deployment removed using Railway down. Project deletion accepted for the exact disposable project; project no longer appears in the account list. Railway schedules final deletion internally.
- Dedicated CNAME rec_4de92aea5fda588e276e304e removed. Disposable certificate revoked through ACME. Local account key, TLS key and certificate files removed.
- Control endpoint now returns 404; TCP endpoint has no successful connection (5-second timeout). No fixture remains serving.
- Both temporary Claude connectors removed. The synthetic chat contains only test instructions and fixed status output. No other connectors were called.

## Result and remaining gate
Stage 0 is **not passed**. Desktop SDK works on Railway TCP port 37763; hosted Claude failed there and succeeded with the same handler through Railway standard HTTPS. ChatGPT remains unverified due to workspace role. No permission changes were made. CI is green, including the dedicated synthetic-mcp job; final documentation commit is checked before merge.

Do not implement the proposed Railway encrypted reverse tunnel based on this result. A revised transport plan must satisfy both hosted clients while keeping origin TLS private keys on the Mac. Railway standard HTTPS success does not establish that privacy property because its edge terminates TLS. No messages, local daemons, Clerk secrets or real draft actions were exposed. No production service or app release was deployed.
