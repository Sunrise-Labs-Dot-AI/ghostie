#!/usr/bin/env python3
"""Exercise sidecar discovery and version bumping without building or releasing an app."""
import json
import os
import plistlib
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

    # Render the actual release plist fragment, including optional remote config.
    # A shell syntax check cannot detect Python accidentally placed INSIDE XML.
    app = fixture / "Ghostie.app"
    (app / "Contents").mkdir(parents=True)
    plist_start = release.index('cat > "$APP_PATH/Contents/Info.plist" <<EOF')
    plist_end = release.index("\n# ============================================================================", plist_start)
    fragment = release[plist_start:plist_end]
    env = {**os.environ, "APP_PATH": str(app), "EXE_NAME": "MessagesForAIMenu",
           "BUNDLE_ID": "com.sunriselabs.messages-for-ai", "APP_DISPLAY_NAME": "Ghostie",
           "VERSION": "v99.0.0", "CFBUNDLE_VERSION": "1", "SU_PUBLIC_ED_KEY": "fixture",
           "POSTHOG_PROJECT_TOKEN": "", "POSTHOG_HOST": "https://example.test"}
    for origin in ["", "https://relay.example.test", "https://relay.example.test/"]:
        subprocess.run(["bash", "-e"], input=fragment, env={**env, "GHOSTIE_RELAY_ORIGIN": origin},
                       text=True, capture_output=True, check=True)
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        assert info["CFBundleExecutable"] == "MessagesForAIMenu"
        assert info.get("GhostieRemoteRelayURL", "") == origin.rstrip("/")
    invalid = subprocess.run(["bash", "-e"], input=fragment,
                             env={**env, "GHOSTIE_RELAY_ORIGIN": "http://relay.example.test"},
                             text=True, capture_output=True)
    assert invalid.returncode != 0, "Release must reject a plaintext relay"
print("ok standalone relay packaging and extracted facade version bump")
