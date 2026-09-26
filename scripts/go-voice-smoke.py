#!/usr/bin/env python3
"""Check the local worker with fixed test text. Never print credentials or tokens.

Uses a small amount of ElevenLabs credit. Start worker with npm run dev first.
"""
import json
from pathlib import Path
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
BASE = "http://127.0.0.1:8787"


def settings():
    values = {}
    for line in (ROOT / "worker/.dev.vars").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def main():
    values = settings()
    client_key = values.get("GO_CLIENT_KEY")
    if not client_key:
        raise SystemExit("GO_CLIENT_KEY is missing from the local configuration.")
    report = []
    for route, body, authenticated in [
        ("/tts", {"text": "Go voice connection test.", "model_id": "eleven_flash_v2_5"}, False),
        ("/tts", {"text": "Go voice connection test.", "model_id": "eleven_flash_v2_5"}, True),
        ("/gemini-live-token", {}, True),
    ]:
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["X-Go-Client-Key"] = client_key
        request = urllib.request.Request(BASE + route, data=json.dumps(body).encode(), headers=headers)
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                status, data = response.status, response.read()
                content_type = response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as error:
            status, data = error.code, error.read()
            content_type = error.headers.get("Content-Type", "")
        row = {"route": route, "authenticated": authenticated, "httpStatus": status,
               "milliseconds": round((time.monotonic() - started) * 1000)}
        if not authenticated:
            row["passed"] = status == 401
        elif route == "/tts" and status == 200:
            row["passed"] = content_type.startswith("audio/") and len(data) > 100
            row["audioBytes"] = len(data)
            if row["passed"]:
                Path("/private/tmp/go-voice-smoke.mp3").write_bytes(data)
        elif route == "/gemini-live-token" and status == 200:
            row["passed"] = bool(json.loads(data).get("token"))
        else:
            row["passed"] = False
            message = data.decode(errors="replace")
            for secret in values.values():
                if secret:
                    message = message.replace(secret, "[redacted]")
            row["error"] = message[:800]
        report.append(row)
        print(json.dumps(row), flush=True)
    Path("/private/tmp/go-voice-smoke.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(row["passed"] for row in report) else 1


if __name__ == "__main__":
    raise SystemExit(main())
