#!/usr/bin/env python3
"""Point Go at the local worker without printing keys or putting them in argv."""
import json
import plistlib
from pathlib import Path
import runpy
import secrets
import subprocess

ROOT = Path(__file__).resolve().parent.parent
values = runpy.run_path(str(ROOT / "scripts/go-voice-smoke.py"))["settings"]()
if not all(values.get(k) for k in ["GEMINI_API_KEY", "ELEVENLABS_API_KEY"]):
    raise SystemExit("Local configuration is incomplete.")
config_path = ROOT / "worker/.dev.vars"
text = config_path.read_text()
for key, default in [("GO_CLIENT_KEY", secrets.token_urlsafe(32)),
                     ("ELEVENLABS_VOICE_ID", "SAz9YHcvj6GT2YYXdXww")]:
    if not values.get(key):
        text = "\n".join(line for line in text.splitlines()
                         if line.split("=", 1)[0].strip() != key)
        text = text.rstrip() + "\n" + key + "=" + default + "\n"
        values[key] = default
config_path.write_text(text)
config_path.chmod(0o600)
def bundle_identifier():
    """GO_BUNDLE_ID from Signing.local.xcconfig, else the checked-in default."""
    for name in ["Signing.local.xcconfig", "Signing.xcconfig"]:
        path = ROOT / name
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "GO_BUNDLE_ID" and value.strip():
                return value.strip()
    raise SystemExit("GO_BUNDLE_ID is not set; see Signing.xcconfig.")
domain = bundle_identifier()
export = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True)
preferences = plistlib.loads(export.stdout)
preferences.update(GoWorkerBaseURL="http://127.0.0.1:8787",
                   GoWorkerClientKey=values["GO_CLIENT_KEY"])
subprocess.run(["defaults", "import", domain, "-"], input=plistlib.dumps(preferences),
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
print(json.dumps({"configured": True, "backend": "http://127.0.0.1:8787"}))
