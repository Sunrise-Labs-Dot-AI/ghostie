# Verifying Ghostie runs on Intel Macs

Releases through **v0.13.0 shipped arm64-only**, so no Intel Mac could launch
Ghostie at all. `swift build` and `bun build --compile` both default to the host
architecture, and releases are cut on Apple Silicon. Rosetta cannot compensate:
it translates x86→ARM, never the reverse.

Ghostie now ships universal (arm64 + x86_64). Two guards keep it that way:
`verify_universal` in `scripts/build-release.sh` fails the release build if any
inner Mach-O is missing a slice, and `scripts/install-release.sh` refuses to
install onto a Mac whose architecture the bundle doesn't carry.

Neither guard can prove the x86_64 slice *runs*, because that needs real Intel
hardware. This document is the procedure for confirming that.

## Quick diagnosis (any Mac, no build required)

```bash
echo "CPU:   $(uname -m)"
echo "macOS: $(sw_vers -productVersion)"
file -b /Applications/Ghostie.app/Contents/MacOS/MessagesForAIMenu 2>/dev/null \
  || echo "Ghostie not installed at /Applications/Ghostie.app"
```

| `uname -m` | `sw_vers` | app reports | Meaning |
|---|---|---|---|
| `x86_64` | ≥ 14 | `arm64` only | The arm64-only bug. A universal build fixes it. |
| `x86_64` | < 14 | anything | Below the macOS 14 floor. A universal build does **not** help. |
| `arm64` | ≥ 14 | anything | Not an architecture problem. Capture the actual error. |

`x86_64` means an Intel Mac. A correct universal build reports
`Mach-O universal binary with 2 architectures ... x86_64 ... arm64`.

## Why macOS 14 is still the floor

Lowering it to Ventura costs 116 compile errors across 7 APIs, 94 of them
`onChange(of:initial:_:)`, plus `dismissWindow`, `onKeyPress`,
`defaultScrollAnchor`, and `AccessibilityNotification`. The payoff is small:
Macs that run 13 but not 14 are all 2017 models, and Ventura is past Apple's
security-update window. Every 2018-or-later Intel Mac is blocked by architecture
alone, which is what the universal build addresses.

---

## Protocol for an external tester

Everything below can be handed to someone else (or their coding agent) verbatim.
It is written to **stop early** when the diagnosis shows this isn't their problem,
so nobody burns an hour on an Xcode build that was never going to help.

### Step 1 — Diagnose first

Run the quick-diagnosis block above and read it against the table.

- **Intel + macOS 14+ + app reports `arm64` only** → continue to Step 2.
- **Intel + macOS below 14** → **stop.** Report the version. A universal build
  won't help; see the floor discussion above.
- **Apple Silicon** → **stop.** This isn't the architecture bug. Instead, launch
  `/Applications/Ghostie.app`, capture the exact error dialog, and run:
  `log show --predicate 'process == "MessagesForAIMenu"' --last 10m --info | tail -50`
- **Not installed** → note it and continue if this is an Intel Mac on macOS 14+.

### Step 2 — Prerequisites

Requires Xcode 15+ (Swift 5.9) and Bun.

```bash
swift --version    # need 5.9+
bun --version      # if missing: curl -fsSL https://bun.sh/install | bash
xcode-select -p    # must point at Xcode.app, not CommandLineTools
```

If `xcode-select` points at CommandLineTools, run
`sudo xcode-select -s /Applications/Xcode.app`. Report a blocker here rather
than working around it.

### Step 3 — Build

```bash
git clone https://github.com/Sunrise-Labs-Dot-AI/ghostie.git
cd ghostie
UNIVERSAL=1 bash menubar/scripts/dev-install.sh
UNIVERSAL=1 bash scripts/dev-install.sh
```

`UNIVERSAL=1` builds both architectures, matching what a release ships. Without
it, dev installs build native-only to keep the loop fast. Swift compiles twice,
so this takes a while.

This build is **ad-hoc signed** — it has no Apple Developer ID, which is expected
and fine for testing. Both scripts fall back to ad-hoc automatically; no Apple
developer account is needed. It installs to `/Applications/Ghostie.app`.

If a build step fails, **stop** and report the full error rather than editing the
build scripts.

### Step 4 — Confirm the build is universal

```bash
for f in /Applications/Ghostie.app/Contents/MacOS/*; do
  echo "$(basename "$f"): $(file -b "$f" | head -1)"
done
```

Every binary should report both `x86_64` and `arm64`. Flag any that don't.

### Step 5 — Does it launch? (the actual test)

Open `/Applications/Ghostie.app`.

- Gatekeeper will likely block an ad-hoc-signed app on first open. Right-click →
  Open, or allow it under System Settings → Privacy & Security. **That prompt is
  expected and is not the bug.**
- The bug looks like: *"You can't open the application because it is not
  supported on this type of Mac."*
- Success looks like a ghost icon in the menu bar.

If it launches on an Intel Mac, that is the headline result.

### Step 6 — Optional: does it function?

Grant Full Disk Access to **Ghostie** (System Settings → Privacy & Security →
Full Disk Access → `+` → /Applications/Ghostie → ON), then open the console from
the menu bar icon and see whether it lists iMessage threads.

**Known limitation of a self-built copy:** the daemon authenticates peers by
codesign Identifier **and** TeamIdentifier, and rejects any peer whose team is
null (`peer-auth.ts`: *"the daemon must be Developer-ID signed in production"*).
Ad-hoc signing produces exactly that, so message reading may fail. This is
expected for a local build and is **not** the architecture bug.

Dev mode bypasses peer-auth and is permitted on ad-hoc binaries. Quit Ghostie,
then relaunch from Terminal:

```bash
MESSAGES_MCP_DEV=1 WHATSAPP_MCP_DEV=1 \
  /Applications/Ghostie.app/Contents/MacOS/MessagesForAIMenu
```

Whether that env var reaches the daemon the app spawns is unconfirmed. If it
doesn't work, say so rather than digging. Step 5 is what matters.

### Report template

```
CPU (uname -m):
macOS version:
Pre-existing app architecture (Step 1):
Build succeeded:            yes / no / n-a   (error if no)
All binaries universal:     yes / no         (which failed)
App LAUNCHED:               yes / no         (exact error if no)
Menu bar icon appeared:     yes / no
Optional, read messages:    yes / no / didn't try
Anything surprising:
```

Paste the raw output of Step 1 and Step 4 verbatim.

### Where to send results

Comment on the pull request or open an issue at
https://github.com/Sunrise-Labs-Dot-AI/ghostie/issues — no repository access is
needed for either. Code contributions go through a fork: use the GitHub **Fork**
button, push a branch there, and open a pull request from it.
