// One-shot legacy-directory migration. Runs at MCP server startup.
//
// Background: v0.1.x stored state under `~/.imessage-mcp/`. v0.2.0 renames
// the on-disk root to `~/.messages-mcp/` to make room for sibling MCPs
// (e.g. WhatsApp) under the same umbrella. On a user's first launch of the
// renamed binary, copy the legacy directory into the new location so they
// don't lose drafts / audit log / contacts cache / settings.
//
// ## Threat model (this file is a trust boundary)
//
// The legacy directory has been on disk for an unknown amount of time and
// is fully user-controlled. The naïve approach (`cpSync(old, new, {recursive:
// true})`) follows symlinks at LEAF FILES, which means an attacker who
// pre-positioned a symlink inside `~/.imessage-mcp/` (e.g. a malicious
// npm postinstall in an unrelated project) can hijack any file path the
// MCP later writes to — most importantly `send-audit.log` (which gates
// the daily-send-cap circuit breaker) and `settings.json` (which gates
// `requireApproval`).
//
// This implementation therefore:
//
// 1. **Rejects symlinks at the source ROOT.** If `~/.imessage-mcp/` is a
//    symlink, we refuse to migrate and warn the user.
// 2. **Rejects symlinks at the destination ROOT.** Even though we create
//    `~/.messages-mcp/` ourselves, an attacker could pre-create it as a
//    dangling symlink before our first run.
// 3. **Walks entries explicitly with `readdirSync({withFileTypes: true})`**
//    and rejects ANY symlink encountered (at any depth). Refusing to
//    propagate is safer than rewriting — a planted symlink is a hostile
//    signal and the user should investigate manually.
// 4. **Uses `mkdirSync` of the new dir as the linearization point.** Two
//    parallel MCP spawns (e.g. Claude Desktop + Claude Code starting
//    simultaneously) can both pass `existsSync(newDir) === false`; the
//    first `mkdirSync` wins, the second sees EEXIST and bails. This
//    prevents a concurrent partial copy.
// 5. **Skips when a sentinel exists.** Bare `existsSync(newDir)` is
//    insufficient because the Swift menu bar app may have created
//    `~/.messages-mcp/drafts/` first (it calls
//    `FileManager.default.createDirectory(...withIntermediateDirectories:
//    true)` on init). We check for a `.migration-complete` sentinel file
//    we wrote at the END of a previous successful migration. If the new
//    dir exists but the sentinel does not, treat as incomplete and retry.
// 6. **Sets 0o700 on the new dir** regardless of what the legacy dir's
//    permissions were.
// 7. **Best-effort, non-blocking.** Failures log to stderr but do NOT
//    halt startup. The storage layer recreates whatever's missing.
// 8. **stderr only.** Stdout is reserved for MCP JSON-RPC.

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LEGACY_DIR_NAME = ".imessage-mcp";
const CURRENT_DIR_NAME = ".messages-mcp";
const SENTINEL_NAME = ".migration-complete";
const TAG = "[imessage-drafts-mcp]";

/**
 * lstat without following symlinks. Returns null if the path doesn't exist
 * or stat itself fails (e.g. permission denied — fine, we'll treat as absent).
 */
function lstatOrNull(path: string): ReturnType<typeof lstatSync> | null {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

/**
 * Recursively scan a directory for symlinks. Returns the first symlink
 * found (relative to root), or null if the tree is clean. Bounded
 * search — refuses to traverse symlinked directories.
 */
function findSymlink(root: string, relPath = ""): string | null {
  // `readdirSync(..., {withFileTypes: true})` returns Dirent<string>[] when
  // called with a string path, but `ReturnType<typeof readdirSync>` resolves
  // to the broader union including Dirent<Buffer> variants. Type the local
  // explicitly so .name is a string, not string | Buffer.
  let entries: import("fs").Dirent<string>[] = [];
  try {
    entries = readdirSync(join(root, relPath), {
      withFileTypes: true,
    }) as import("fs").Dirent<string>[];
  } catch {
    // Unreadable directory — treat as clean for migration purposes;
    // a deeper failure during cpSync will surface in the outer try/catch.
    return null;
  }
  for (const entry of entries) {
    const childRel = relPath ? join(relPath, entry.name) : entry.name;
    if (entry.isSymbolicLink()) return childRel;
    if (entry.isDirectory()) {
      const found = findSymlink(root, childRel);
      if (found) return found;
    }
  }
  return null;
}

export function migrateLegacyDir(): void {
  try {
    const home = homedir();
    const oldDir = join(home, LEGACY_DIR_NAME);
    const newDir = join(home, CURRENT_DIR_NAME);
    const sentinel = join(newDir, SENTINEL_NAME);

    // (a) Nothing to migrate.
    const oldStat = lstatOrNull(oldDir);
    if (!oldStat) return;

    // (b) Refuse if legacy root is a symlink — defends against attacker
    //     pointing `~/.imessage-mcp` at an unrelated tree.
    if (oldStat.isSymbolicLink()) {
      process.stderr.write(
        `${TAG} legacy directory at ${oldDir} is a symlink — refusing to migrate. ` +
          `Move/copy the data into ~/${CURRENT_DIR_NAME} manually and remove the symlink.\n`
      );
      return;
    }

    // (c) Refuse if destination root is a symlink — attacker may have
    //     pre-positioned it pointing elsewhere.
    const newStat = lstatOrNull(newDir);
    if (newStat?.isSymbolicLink()) {
      process.stderr.write(
        `${TAG} destination ${newDir} is a symlink — refusing to migrate. ` +
          `Remove the symlink and restart.\n`
      );
      return;
    }

    // (d) Already migrated (sentinel present as a regular file) —
    //     silent no-op. We use lstatOrNull rather than existsSync
    //     because existsSync follows symlinks: an attacker who
    //     pre-positions ~/.messages-mcp/.migration-complete as a
    //     symlink to any existing file (e.g. /etc/hosts) would
    //     otherwise cause migrateLegacyDir() to silently skip,
    //     leaving the user without their legacy state copied. The
    //     sentinel MUST be a regular file we wrote ourselves.
    if (newStat) {
      const sentinelStat = lstatOrNull(sentinel);
      if (sentinelStat?.isFile()) return;
      if (sentinelStat?.isSymbolicLink()) {
        process.stderr.write(
          `${TAG} sentinel ${sentinel} is a symlink — refusing to trust as a "migration complete" marker. ` +
            `Remove the symlink and restart.\n`
        );
        return;
      }
    }

    // (e) If newDir exists but no sentinel, the previous run was
    //     interrupted OR a sibling process (Swift menu bar) pre-created
    //     it. We can't safely merge into it because cpSync would overwrite
    //     anything the sibling already wrote. Refuse rather than guess.
    if (newStat) {
      process.stderr.write(
        `${TAG} destination ${newDir} exists but no ${SENTINEL_NAME} sentinel — ` +
          `previous migration may have been interrupted, or another process pre-created the directory. ` +
          `Inspect manually; if safe to migrate, remove ${newDir} and restart.\n`
      );
      return;
    }

    // (f) Reject migration if the source tree contains ANY symlink.
    //     Refusing to propagate is safer than rewriting — a planted
    //     symlink inside the legacy tree is a hostile signal.
    const offending = findSymlink(oldDir);
    if (offending) {
      process.stderr.write(
        `${TAG} legacy tree contains a symlink at ${join(oldDir, offending)} — ` +
          `refusing to migrate. Inspect and remove the symlink, then restart.\n`
      );
      return;
    }

    // (g) Linearize concurrent startups: mkdirSync(newDir, {recursive: false})
    //     succeeds for at most one process. A second simultaneous spawn
    //     hits EEXIST and bails — no half-copy race.
    try {
      mkdirSync(newDir, { mode: 0o700 });
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EEXIST") {
        // Lost the race to another process. Their migration may still
        // be in flight; backing off is safer than racing.
        process.stderr.write(
          `${TAG} another process created ${newDir} concurrently — yielding migration.\n`
        );
        return;
      }
      throw e;
    }

    // (h) Copy. With verbatimSymlinks:false + dereference:false, cpSync
    //     would still copy symlinks-as-symlinks at leaf level, but
    //     findSymlink above guaranteed there are none. cpSync is then
    //     equivalent to a plain regular-file/directory copy.
    cpSync(oldDir, newDir, { recursive: true, dereference: false });

    // (i) Lock down perms on the new tree root (in case the legacy dir
    //     had been mode 0o755 — propagate-with-replace).
    try {
      chmodSync(newDir, 0o700);
    } catch {
      // Non-fatal: if chmod fails, the storage layer will set perms on
      // individual writes anyway.
    }

    // (j) Write sentinel last so a crash between (h) and (j) is
    //     detected on the next run via the no-sentinel branch above.
    writeFileSync(sentinel, new Date().toISOString() + "\n", { mode: 0o600 });

    process.stderr.write(
      `${TAG} migrated state from ${oldDir} to ${newDir}. ` +
        `Old directory preserved; delete it manually after verifying the new install works.\n`
    );
  } catch (err) {
    // Best-effort — never throw. The storage layer recreates whatever's missing.
    process.stderr.write(
      `${TAG} migration check failed (non-fatal): ${(err as Error).message}\n`
    );
  }
}
