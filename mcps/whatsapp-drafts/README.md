# whatsapp-mcp

> **Status:** pre-v0.1.0 — scaffolding stage. Not ready for use.

Local MCP server for **WhatsApp on macOS**. Sibling to
[`imessage-mcp`](https://github.com/Sunrise-Labs-Dot-AI/imessage-mcp); shares
the same draft-first / hold-to-fire safety model.

Built on:

- **[Baileys](https://github.com/WhiskeySockets/Baileys)** for the WhatsApp
  Multi-Device protocol (you pair this Mac as a linked device, same as
  WhatsApp Desktop)
- **[Bun](https://bun.sh)** runtime + `bun:sqlite` for storage
- **[Model Context Protocol](https://modelcontextprotocol.io)** stdio
  transport for Claude integration

## How it differs from imessage-mcp

| | imessage-mcp | whatsapp-mcp |
|---|---|---|
| Source of truth | macOS `chat.db` (local SQLite) | Baileys WebSocket to Meta servers |
| Process model | stdio fork on demand | Persistent daemon + thin stdio MCP |
| Credentials | Apple's (OS-managed) | Ours (Keychain-wrapped session.db) |
| Account ban risk | None | Real — Meta polices automated clients |
| Setup | Grant Full Disk Access | Scan a QR code (once) |

## Status by phase

- [ ] **Phase 1** — daemon + read-only MCP tools
- [ ] **Phase 2** — draft staging + send with full rate-limit/audit stack
- [ ] **Phase 3** — menu bar app integration (in `imessage-mcp` repo)
- [ ] **Phase 4** — docs + SECURITY.md + first release

See [`docs/architecture.md`](docs/architecture.md) and the planning doc
(internal) for the full design.

## ⚠️ WhatsApp Terms of Service

This project uses **Baileys**, a reverse-engineered implementation of
WhatsApp's Multi-Device protocol. Using third-party WhatsApp clients
**may violate WhatsApp's Terms of Service**. Bans target the **phone
number itself** — a banned number cannot be recovered on any device.

The defaults in this project are conservative for single-user personal-
reply use. **Use at your own risk.** See [`SECURITY.md`](SECURITY.md) for
the full threat model and risk disclosure once it's written.

## Architecture (TL;DR)

```
launchd
  └── whatsapp-daemon (persistent, code-signed)
        ├── Baileys WebSocket ←→ Meta servers
        ├── Unix socket: ~/.whatsapp-mcp/daemon.sock (peer-authed)
        ├── session.db    (AES-GCM wrapped via Keychain)
        ├── messages.db   (live message cache)
        ├── audit.db      (atomic cap + send log)
        └── drafts/       (staged but not yet sent)

Claude forks: whatsapp-mcp (stdio MCP) → talks to daemon.sock

iMessage Drafts.app (in imessage-mcp repo, extended) watches both
~/.imessage-mcp/drafts/ and ~/.whatsapp-mcp/drafts/
```

## Thread priorities

Agents can tag a conversation as priority via `set_whatsapp_thread_priority`
(level 1 = urgent, 2 = high, 3 = elevated — lower is more urgent), clear it
with `clear_whatsapp_thread_priority`, and list with
`list_whatsapp_thread_priorities`. Priorities are stored at
`~/.whatsapp-mcp/thread-priorities.json` (schema_version 1, keyed by
`thread_jid`), written atomically at mode 0600 by the MCP process itself (no
daemon involvement). The menu bar app reads this file directly to render its
priority queue, so the JSON shape is a shared contract — see
`src/storage/priorities.ts`.

## License

[MIT](LICENSE)
