#!/usr/bin/env python3
"""Verify two consecutive XCTest commands on the selected physical Apple Watch."""
import argparse
import json
from pathlib import Path
import select
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, type=uuid.UUID, help="Apple Watch UUID from mac-cu device list")
    parser.add_argument("--dry-run", action="store_true", help="Print the requested operations without connecting")
    args = parser.parse_args()
    device = str(args.device).upper()
    if args.dry_run:
        print(json.dumps({"device": device, "actions": ["list", "allow", "xctestStart", "xctestStatus",
                                                       "xctestPing", "xctestPing", "xctestStop", "release"]}))
        return
    executable = Path.home() / "Library/Application Support/mac-cu/mac-cu.app/Contents/MacOS/mac-cu"
    with subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as client:
        sequence = 0

        def rpc(method, params):
            nonlocal sequence
            sequence += 1
            request = {"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}
            client.stdin.write(json.dumps(request) + "\n")
            client.stdin.flush()
            if not select.select([client.stdout], [], [], 100)[0]:
                raise TimeoutError(method)
            reply = json.loads(client.stdout.readline())
            if "error" in reply:
                raise RuntimeError(reply["error"])
            return reply["result"]

        def call(action):
            reply = rpc("tools/call", {"name": "device", "arguments": {"device": device, "action": action}})
            if reply.get("isError"):
                raise RuntimeError(reply["content"][0]["text"])
            return reply

        try:
            rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "MacPilot watch check", "version": "1"}})
            listing = call("list")["content"][0]["text"]
            if not any(row.startswith(device + " | ") and " | watchOS " in row for row in listing.splitlines()):
                raise ValueError("Select an Apple Watch UUID from device list.")
            call("allow")
            try:
                call("xctestStart")
                try:
                    deadline = time.monotonic() + 250
                    while call("xctestStatus")["structuredContent"]["state"] != "ready":
                        if time.monotonic() >= deadline:
                            raise TimeoutError("watch runner readiness")
                        time.sleep(1)
                    replies = [call("xctestPing")["structuredContent"]["state"] for _ in range(2)]
                    if replies != ["pong", "pong"]:
                        raise ValueError(replies)
                finally:
                    stopped = call("xctestStop")["structuredContent"]
                if not stopped["confirmedRunnerExit"]:
                    raise RuntimeError("Xcode did not confirm runner exit.")
                print(json.dumps({"device": device, "replies": replies, "confirmedRunnerExit": True}))
            finally:
                call("release")
        finally:
            client.stdin.close()


if __name__ == "__main__":
    main()
