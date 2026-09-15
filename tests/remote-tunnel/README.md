# Railway client compatibility probe

Synthetic-only Stage 0. This is not the Ghostie messaging service and not evidence of end-to-end encryption against Railway. It exposes one fixed `ghostie_connection_check` result, with no messages, account data, files, commands, draft writes or arbitrary outbound requests.

Run `bun install --frozen-lockfile`, `bun run typecheck`, and `bun test` here. Tests use an ephemeral CA scoped to each client, never system-wide trust or disabled verification.

## Exact deployment boundary

Deploy **only this directory** as Railway's upload root, using `railway up . --path-as-root` from `tests/remote-tunnel`. Use the isolated `ghostie-compatibility-probe` project and `synthetic-status` service. Do not link a GitHub source or enable autodeploy. The Docker build copies only `probe.ts`, and sets `PROBE_BIND_HOST=0.0.0.0` and `PORT=9443` explicitly. Configure a raw TCP proxy to internal port 9443. Use a dedicated subdomain and disposable certificate; provide `PROBE_TLS_CERT` and `PROBE_TLS_KEY` through Railway variable stdin, never in command arguments or git. The fixture certificate is intentionally on Railway and never used for product traffic.

`railway.json` selects the Dockerfile, one replica and restart policy NEVER. The process exits after 30 minutes. Also remove the active deployment when measurement finishes, then verify it is offline. Delete only the probe's exact DNS records and revoke the disposable certificate. Do not touch the marketing site's DNS records.

## Evidence to collect

- A standard MCP SDK lists and calls the fixed tool through the live certificate-verified Railway URL including its assigned port.
- Claude and ChatGPT hosted connectors each list and call the same tool. Record exact URL/port, date, surface and observed result. A URL-format check, local test, desktop SDK success or connector being saved does not count as a hosted call.
- Record account or workspace limitations as unverified, not network failures. Do not weaken account security or broaden workspace permissions to get a pass.
- Only after both hosted clients pass should a separately reviewed encrypted reverse tunnel be built. The Mac must retain origin keys and enforce grants; the production relay must not gain message access by issuing its own grants.

References: [Railway TCP proxy](https://docs.railway.com/networking/tcp-proxy), [MCP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
