#!/usr/bin/env bash
# dev-link-skills.sh — ensure every skills/<name>/ is symlinked under .claude/skills/
# so `claude` running in this repo auto-loads them. Idempotent. Run after scaffolding
# a new skill, or just whenever .claude/skills/ feels stale.
#
# Plugin users get the same skills auto-loaded via the installed plugin (the plugin's
# skills/ dir is discovered by Claude Code's plugin loader). This script is the
# dev-time convenience path — it does NOT affect what plugin users see.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p .claude/skills

linked=0
skipped=0
removed=0

# Link every skills/<name>/SKILL.md into .claude/skills/<name>.
for skill_dir in skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  if [ ! -f "$skill_dir/SKILL.md" ]; then
    echo "  skip: skills/$name/ has no SKILL.md"
    skipped=$((skipped + 1))
    continue
  fi
  target=".claude/skills/$name"
  desired="../../skills/$name"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$desired" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  ln -snf "$desired" "$target"
  echo "  link: .claude/skills/$name -> $desired"
  linked=$((linked + 1))
done

# Prune symlinks under .claude/skills/ that no longer point at a real skill.
for link in .claude/skills/*; do
  [ -e "$link" ] || [ -L "$link" ] || continue
  name="$(basename "$link")"
  # Only ever remove symlinks — never a real file someone deliberately placed here.
  if [ -L "$link" ] && [ ! -d "skills/$name" ]; then
    echo "  prune: .claude/skills/$name (dangling symlink, no matching skills/$name/)"
    rm -f "$link"
    removed=$((removed + 1))
  fi
done

echo
echo "done — linked=$linked skipped=$skipped pruned=$removed"
