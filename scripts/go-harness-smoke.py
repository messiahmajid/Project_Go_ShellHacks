#!/usr/bin/env python3
"""Harness smoke test: checks Go's action layer on Finder, with no AI or screenshots.

Run Go with --harness first. This opens one Finder window and leaves it open.
No files are created, edited, or deleted. The report excludes file names.
"""
import json
import os
from pathlib import Path
import socket

SOCKET = os.path.expanduser("~/Library/Application Support/Go/harness.sock")
REPORT = Path("/private/tmp/go-harness-smoke.json")


def send(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(SOCKET)
        connection.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("Harness closed without a response")
            data += chunk
        return json.loads(data.split(b"\n", 1)[0])


def main():
    records = []

    def check(request):
        request = dict(request, id=f"go-baseline-{len(records)}")
        if request["verb"] not in {"ping", "focus"}:
            request["expectApp"] = "com.apple.finder"
        response = send(request)
        record = {
            "verb": request["verb"], "ok": response.get("ok"),
            "error": response.get("error"),
            "kernel": response.get("kernel"),
            "verification": response.get("verification"),
            "nodeCount": response.get("nodeCount"),
            "actionableCount": response.get("actionableCount"),
        }
        records.append(record)
        REPORT.write_text(json.dumps(records, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        if not response.get("ok"):
            raise RuntimeError(f"{request['verb']} failed: {response.get('error')}")
        return response

    check({"verb": "ping"})
    check({"verb": "focus", "app": "com.apple.finder"})
    before = check({"verb": "windows", "app": "com.apple.finder"})
    action = check({"verb": "menu", "path": ["File", "New Finder Window"]})
    if (action.get("verification") or {}).get("status") != "confirmed":
        raise RuntimeError("New Finder Window was not verified")
    check({"verb": "snapshot"})
    check({"verb": "highlight", "target": "window", "seconds": 2, "label": "Go harness check"})
    after = check({"verb": "windows", "app": "com.apple.finder"})
    if len(after.get("windows", [])) != len(before.get("windows", [])) + 1:
        raise RuntimeError("Independent window count did not increase by one")
    print("PASS: ping, focus, safe action, verification, snapshot, highlight, independent window count")


if __name__ == "__main__":
    main()
