#!/usr/bin/env bash
# install.sh — scaffold installer.
#
# TODO before v0.1.0:
#   1. `bun install --frozen-lockfile` (requires bun.lock committed)
#   2. `bun run build` → bin/whatsapp-mcp + bin/whatsapp-daemon
#   3. codesign --deep --sign "Developer ID Application: ..." bin/whatsapp-daemon
#   4. write ~/Library/LaunchAgents/ai.sunriselabs.whatsapp-mcp.plist
#      pointing at the signed daemon binary
#   5. launchctl bootstrap gui/$UID <plist>
#   6. run the installer smoke test (acceptance criteria from plan):
#      - launchctl list | grep whatsapp
#      - daemon refuses to start when LOGGED_OUT sentinel present
#      - peer-auth rejects unsigned peer
#      - stale-socket recovery: kill -9 daemon, kickstart, no EADDRINUSE
#      - session.db / session.db-wal / session.db-shm all mode 0600
#   7. exit non-zero on any failure
#
# Today: just create ~/.whatsapp-mcp/ and exit.

set -euo pipefail

ROOT="${HOME}/.whatsapp-mcp"
echo "Creating ${ROOT}/..."
mkdir -m 0700 -p "${ROOT}"
mkdir -m 0700 -p "${ROOT}/drafts"

echo "Done. Next steps (manual until installer is finished):"
echo "  1. bun install"
echo "  2. bun run build"
echo "  3. WHATSAPP_MCP_DEV=1 bun run dev:daemon       # in one terminal"
echo "  4. Configure the MCP client to point at bin/whatsapp-mcp"
