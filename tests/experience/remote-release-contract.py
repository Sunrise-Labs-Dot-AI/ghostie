#!/usr/bin/env python3
"""Exercise sidecar discovery and version bumping without building or releasing an app."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
release = (ROOT / "scripts/build-release.sh").read_text()
start = release.index("EXPECTED_SIDECARS=()")
end = release.index('for want in "${EXPECTED_SIDECARS[@]}"', start)
script = 'REPO_ROOT="$1"\nBACKEND_BIN_NAME=messages-for-ai-backend\n' + release[start:end]
script += '\nprintf "%s\\n" "${EXPECTED_SIDECARS[@]}"\n'
result = subprocess.run(["bash", "-s", "--", str(ROOT)], input=script, text=True, capture_output=True, check=True)
sidecars = set(result.stdout.splitlines())
assert "remote-relay-mcp" not in sidecars, "The cloud relay must not be packaged into the Mac app"
assert {"ghostie-mcp", "messages-for-ai-backend", "imessage-drafts-daemon", "whatsapp-drafts-daemon"} <= sidecars

with tempfile.TemporaryDirectory(prefix="ghostie-release-contract-") as temporary:
    fixture = Path(temporary)
    paths = ["scripts/bump-version.sh", ".claude-plugin/plugin.json", "mcps/ghostie/src/facade.ts",
             "mcps/imessage-drafts/src/index.ts", "mcps/whatsapp-drafts/src/index.ts"]
    paths += [f"mcps/{name}/package.json" for name in
              ["ghostie", "imessage-drafts", "whatsapp-drafts", "wrapped-generator", "birthday-generator"]]
    for relative in paths:
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)
    subprocess.run(["bash", str(fixture / "scripts/bump-version.sh"), "99.0.0"],
                   cwd=fixture, text=True, capture_output=True, check=True)
    assert 'name: "ghostie-mcp", version: "99.0.0"' in (fixture / "mcps/ghostie/src/facade.ts").read_text()
    assert json.loads((fixture / "mcps/ghostie/package.json").read_text())["version"] == "99.0.0"
    assert "mcps/ghostie/src/facade.ts" in (ROOT / "scripts/release.sh").read_text()
print("ok standalone relay packaging and extracted facade version bump")
