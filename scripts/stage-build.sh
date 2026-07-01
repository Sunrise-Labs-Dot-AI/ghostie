#!/usr/bin/env bash
#
# stage-build.sh — assemble a throwaway `staging` branch from main + a set of
# WIP branches, then dev-install the result for hands-on testing.
#
# This is the Ghostie implementation of the cross-project /stage-build
# discipline. The global skill (~/.claude/skills/stage-build/SKILL.md) detects
# the project and calls this script; it is also fine to run by hand.
#
# Two phases, because of one hard macOS constraint:
#
#   PREP  (git fetch → reset staging to main → merge each branch → set flags)
#         is automation-safe. Claude Code can run it.
#
#   BUILD (the two dev-install.sh steps) writes into the Developer-ID-signed
#         /Applications/Ghostie.app. macOS App Management blocks the Claude
#         Code automation host from writing into that bundle ("Operation not
#         permitted" on the cp into Contents/MacOS) even with the Bash sandbox
#         off. The build MUST be run from a Terminal that holds App Management
#         permission — i.e. James's own Terminal. swift build / bun build
#         themselves work fine under automation; only the install write is
#         blocked.
#
# So the normal flow is: Claude runs `--prep-only`; James runs `--build-only`
# from his Terminal. Running with no phase flag does PREP then BUILD (use this
# when YOU are in your own Terminal).
#
# Usage:
#   scripts/stage-build.sh [options] [branch ...]
#
# Options:
#   --prep-only        git work + feature flags + manifest; skip the build.
#   --build-only       skip git work; run the two dev-install steps + finalize
#                      the manifest. Assumes staging is already prepared.
#   --flag NAME        enable a feature-flag override (kebab name, e.g.
#                      keep-tabs). Repeatable. Also: STAGE_FLAGS="a b c".
#   --clean            rm -rf menubar/.build before building. Fixes the stale
#                      PCH error after the repo dir has moved ("PCH was compiled
#                      with module cache path ..." / "missing required module
#                      'SwiftShims'"). Costs a full cold Swift build.
#   --base REF         base branch to reset staging onto (default: origin/main;
#                      or set STAGE_BASE).
#   --allow-dirty      proceed even if the working tree has uncommitted tracked
#                      changes (default: refuse, to protect your WIP). Also:
#                      STAGE_ALLOW_DIRTY=1.
#   -h, --help         show this help.
#
# Branch args are natural git refs. Each is resolved as origin/<name> first,
# then as-is (local branch / tag / sha). The skill does the natural-language
# → branch-name resolution before calling this script.
#
# Artifacts:
#   .staging-manifest          JSON record of the build (gitignored via
#                              .git/info/exclude). Reported back by the skill.
#   ~/.messages-mcp/feature-flags.json   overrides dict updated in place.

set -euo pipefail

# ─── Locate + identify the repo ──────────────────────────────────────────────

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

if [[ ! -d "$REPO_ROOT/menubar" || ! -d "$REPO_ROOT/mcps" ]]; then
  echo "✗ this does not look like the Ghostie repo (expected menubar/ + mcps/)." >&2
  echo "  cwd: $REPO_ROOT" >&2
  exit 1
fi

STAGING_BRANCH="staging"
BASE="${STAGE_BASE:-origin/main}"
MANIFEST="$REPO_ROOT/.staging-manifest"
FLAGS_FILE="$HOME/.messages-mcp/feature-flags.json"
APP_PATH="${INSTALL_ROOT:-/Applications}/Ghostie.app"

# ─── Parse args ──────────────────────────────────────────────────────────────

DO_PREP=1
DO_BUILD=1
CLEAN=0
ALLOW_DIRTY="${STAGE_ALLOW_DIRTY:-0}"
declare -a FLAGS=()
declare -a BRANCHES=()

# seed flags from STAGE_FLAGS env (space-separated)
if [[ -n "${STAGE_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  FLAGS=($STAGE_FLAGS)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prep-only)   DO_BUILD=0 ;;
    --build-only)  DO_PREP=0 ;;
    --clean)       CLEAN=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --flag)        shift; [[ $# -gt 0 ]] || { echo "✗ --flag needs a name" >&2; exit 2; }; FLAGS+=("$1") ;;
    --base)        shift; [[ $# -gt 0 ]] || { echo "✗ --base needs a ref" >&2; exit 2; }; BASE="$1" ;;
    -h|--help)     sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)            shift; while [[ $# -gt 0 ]]; do BRANCHES+=("$1"); shift; done; break ;;
    -*)            echo "✗ unknown option: $1" >&2; exit 2 ;;
    *)             BRANCHES+=("$1") ;;
  esac
  shift
done

log() { printf '\033[1;36m›\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Keep build artifacts out of `git status` without touching the tracked .gitignore.
ensure_exclude() {
  # Resolve via git so this works from a linked worktree too (where `.git` is a
  # gitdir-pointer FILE, not a directory). info/exclude lives in the common dir.
  local ex line
  ex="$(git rev-parse --git-path info/exclude)"
  for line in ".staging-manifest"; do
    grep -qxF "$line" "$ex" 2>/dev/null || echo "$line" >> "$ex"
  done
}

# Resolve a ref → "<display-ref> <sha>". Prefer the fetched origin/ ref.
resolve_ref() {
  local arg="$1" sha
  if sha=$(git rev-parse --verify --quiet "origin/${arg}^{commit}"); then
    echo "origin/${arg} ${sha}"; return 0
  fi
  if sha=$(git rev-parse --verify --quiet "${arg}^{commit}"); then
    echo "${arg} ${sha}"; return 0
  fi
  return 1
}

ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo DETACHED)"

# ─── PREP ────────────────────────────────────────────────────────────────────

declare -a REQ=() REF=() SHA=()
BASE_SHA=""

if [[ "$DO_PREP" == 1 ]]; then
  ensure_exclude

  if [[ "$ALLOW_DIRTY" != 1 ]]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "✗ working tree has uncommitted changes on '$ORIG_BRANCH'." >&2
      echo "  Commit or stash them first (staging-build resets the tree to $BASE)," >&2
      echo "  or pass --allow-dirty / STAGE_ALLOW_DIRTY=1 to override." >&2
      git status --short >&2
      exit 1
    fi
  fi

  log "fetching origin"
  git fetch origin --prune --quiet

  # Resolve every branch up front so an unknown name fails before we touch HEAD.
  for b in "${BRANCHES[@]:-}"; do
    [[ -n "$b" ]] || continue
    if ! read -r rref rsha < <(resolve_ref "$b"); then
      die "branch not found as origin/$b or $b — fetch may be stale, or check the name."
    fi
    REQ+=("$b"); REF+=("$rref"); SHA+=("$rsha")
  done

  if ! BASE_SHA=$(git rev-parse --verify --quiet "${BASE}^{commit}"); then
    die "base ref '$BASE' not found."
  fi

  log "resetting $STAGING_BRANCH → $BASE ($(git rev-parse --short "$BASE_SHA"))"
  git checkout -B "$STAGING_BRANCH" "$BASE" --quiet

  for ((i = 0; i < ${#REF[@]}; i++)); do
    log "merging ${REF[$i]} ($(git rev-parse --short "${SHA[$i]}"))"
    if ! git merge --no-ff --no-edit "${SHA[$i]}" >/tmp/stage-merge.$$ 2>&1; then
      cat /tmp/stage-merge.$$ >&2; rm -f /tmp/stage-merge.$$
      echo >&2
      echo "✗ merge conflict introducing '${REQ[$i]}' (${REF[$i]})." >&2
      echo "  Conflicted files:" >&2
      git diff --name-only --diff-filter=U | sed 's/^/    /' >&2
      echo >&2
      echo "  --- conflict diff ---" >&2
      git --no-pager diff >&2 || true
      git merge --abort
      echo >&2
      echo "  Aborted the merge; staging is back at the last clean state." >&2
      echo "  Resolve by dropping that branch, reordering, or rebasing it on main." >&2
      exit 1
    fi
    rm -f /tmp/stage-merge.$$
  done

  # ── Feature-flag overrides ────────────────────────────────────────────────
  if [[ "${#FLAGS[@]}" -gt 0 ]]; then
    log "enabling feature-flag overrides: ${FLAGS[*]}"
    mkdir -p "$(dirname "$FLAGS_FILE")"
    FF_FILE="$FLAGS_FILE" python3 - "${FLAGS[@]}" <<'PY'
import json, os, sys
path = os.environ["FF_FILE"]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data.setdefault("schema_version", 1)
ov = data.setdefault("overrides", {})
for name in sys.argv[1:]:
    ov[name] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  wrote", path)
PY
  fi
fi

# ─── BUILD ───────────────────────────────────────────────────────────────────

BUILD_STATUS="skipped"
BUILD_SHA=""
BUILT_AT=""

if [[ "$DO_BUILD" == 1 ]]; then
  cur="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$cur" != "$STAGING_BRANCH" ]]; then
    echo "⚠ current branch is '$cur', not '$STAGING_BRANCH'." >&2
    echo "  --build-only builds whatever is checked out. Run prep first, or checkout $STAGING_BRANCH." >&2
  fi

  if [[ "$CLEAN" == 1 ]]; then
    log "cleaning menubar/.build (stale-PCH fix)"
    rm -rf "$REPO_ROOT/menubar/.build"
  fi

  echo
  echo "  NOTE: the install steps write into $APP_PATH (Developer-ID signed)." >&2
  echo "  macOS App Management blocks this from the Claude Code automation host." >&2
  echo "  If you see 'Operation not permitted', re-run --build-only from your own Terminal." >&2
  echo

  set +e
  log "build 1/2 — menubar .app  (cd menubar && bash scripts/dev-install.sh)"
  ( cd "$REPO_ROOT/menubar" && bash scripts/dev-install.sh ); rc=$?
  if [[ $rc -ne 0 ]]; then
    set -e
    echo "✗ menubar dev-install failed (exit $rc)." >&2
    echo "  If this is an 'Operation not permitted' write into $APP_PATH, run from" >&2
    echo "  your own Terminal (App Management). If it's a stale PCH error, re-run with --clean." >&2
    BUILD_STATUS="failed"
  else
    log "build 2/2 — MCP backends  (bash scripts/dev-install.sh)"
    bash "$REPO_ROOT/scripts/dev-install.sh"; rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "✗ MCP dev-install failed (exit $rc)." >&2
      BUILD_STATUS="failed"
    else
      BUILD_STATUS="installed"
      BUILT_AT="$(date -u +%FT%TZ)"
    fi
  fi
  set -e
  BUILD_SHA="$(git rev-parse --short HEAD)"
fi

# ─── Manifest ────────────────────────────────────────────────────────────────

# Re-read base/staging from the manifest if we only did --build-only.
if [[ "$DO_PREP" != 1 && -f "$MANIFEST" ]]; then
  : # keep prior prep fields; python below merges build fields in
fi

STAGING_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# branches TSV for python
BRANCHES_TSV="$(mktemp)"
for ((i = 0; i < ${#REF[@]}; i++)); do
  printf '%s\t%s\t%s\n' "${REQ[$i]}" "${REF[$i]}" "${SHA[$i]}" >> "$BRANCHES_TSV"
done

FLAGS_TSV="$(mktemp)"
for f in "${FLAGS[@]:-}"; do [[ -n "$f" ]] && echo "$f" >> "$FLAGS_TSV"; done

MANIFEST="$MANIFEST" \
PROJECT="ghostie" \
DID_PREP="$DO_PREP" \
BASE_REF="$BASE" BASE_SHA="${BASE_SHA:-}" \
STAGING_SHA="$STAGING_SHA" ORIG_BRANCH="$ORIG_BRANCH" \
BUILD_STATUS="$BUILD_STATUS" BUILD_SHA="$BUILD_SHA" BUILT_AT="$BUILT_AT" \
APP_PATH="$APP_PATH" \
BRANCHES_TSV="$BRANCHES_TSV" FLAGS_TSV="$FLAGS_TSV" \
NOW="$(date -u +%FT%TZ)" \
python3 <<'PY'
import json, os
m = os.environ["MANIFEST"]
did_prep = os.environ["DID_PREP"] == "1"

data = {}
if os.path.exists(m):
    try:
        with open(m) as f: data = json.load(f)
    except json.JSONDecodeError:
        data = {}

if did_prep:
    branches = []
    with open(os.environ["BRANCHES_TSV"]) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line: continue
            req, ref, sha = line.split("\t")
            branches.append({"requested": req, "resolved": ref, "sha": sha[:12]})
    flags = [l.strip() for l in open(os.environ["FLAGS_TSV"]) if l.strip()]
    data.update({
        "project": os.environ["PROJECT"],
        "base": {"ref": os.environ["BASE_REF"], "sha": os.environ["BASE_SHA"][:12]},
        "branches": branches,
        "feature_flags": flags,
        "staging_sha": os.environ["STAGING_SHA"][:12],
        "original_branch": os.environ["ORIG_BRANCH"],
        "prepared_at": os.environ["NOW"],
    })

data["build"] = {
    "status": os.environ["BUILD_STATUS"],
    "sha": os.environ.get("BUILD_SHA", "")[:12],
    "built_at": os.environ.get("BUILT_AT", ""),
    "app": os.environ["APP_PATH"],
}
data["staging_sha"] = os.environ["STAGING_SHA"][:12]

with open(m, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
PY
rm -f "$BRANCHES_TSV" "$FLAGS_TSV"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
log "staging manifest → $MANIFEST"
cat "$MANIFEST"
echo

if [[ "$DO_PREP" == 1 && "$DO_BUILD" == 0 ]]; then
  echo "Prepared '$STAGING_BRANCH'. To finish the build, run from YOUR OWN Terminal:"
  echo "    cd \"$REPO_ROOT\""
  echo "    bash scripts/stage-build.sh --build-only"
  echo "(App Management blocks the install write from the automation host.)"
elif [[ "$BUILD_STATUS" == "installed" ]]; then
  echo "Installed staging build → $APP_PATH"
  echo "Launch:  open \"$APP_PATH\"   (restart MCP clients to pick up new backends)"
fi
echo "Return to your branch:  git checkout $ORIG_BRANCH"
