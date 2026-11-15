#!/usr/bin/env python3
"""Run one explicit-device headless action; inspect every screenshot before a tap."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'mac-computer-use/tests'))
from native_check_support import run_owned, check_routes

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True, type=uuid.UUID)
p.add_argument('--name', default=os.environ.get('MAC_CU_LIVE_DEVICE_NAME'), help='Expected device name (or MAC_CU_LIVE_DEVICE_NAME); the run stops unless it matches')
p.add_argument('--model', default=os.environ.get('MAC_CU_LIVE_DEVICE_MODEL'), help='Expected marketing name (or MAC_CU_LIVE_DEVICE_MODEL)')
p.add_argument('--build-dir', required=True, type=Path)
p.add_argument('--action', required=True, choices=['audit', 'list', 'allow', 'release', 'screenshot', 'tap', 'swipe', 'button', 'key', 'type', 'view'])
p.add_argument('--args', default='{}', help='JSON action parameters')
p.add_argument('--image', type=Path, help='Screenshot destination inside build directory')
a = p.parse_args()
d = a.build_dir.resolve()
if not d.is_dir() or not d.is_relative_to(Path('/Volumes/eyedisk/build')):
    p.error('build directory must already exist under /Volumes/eyedisk/build')
if a.image and not a.image.resolve().is_relative_to(d): p.error('image must be inside build directory')
params = json.loads(a.args)
if not isinstance(params, dict) or 'device' in params or 'action' in params: p.error('invalid action parameters')
# Inventory only; filter locally before displaying anything. Never inspect another device.
listing = subprocess.run(['/usr/bin/xcrun', 'devicectl', 'list', 'devices', '--json-output', '-', '--quiet', '--timeout', '15'], capture_output=True, text=True, timeout=20, check=True).stdout
inventory = json.loads(listing[listing.index('{'):])['result']['devices']
matches = [x for x in inventory if x.get('identifier', '').upper() == str(a.device).upper()]
if len(matches) != 1: sys.exit('Explicit identifier not present exactly once')
x = matches[0]
c = x.get('connectionProperties', {})
wired = c.get('transportType') == 'wired' and c.get('tunnelState') == 'connected'
network = c.get('transportType') not in (None, 'wired') and c.get('pairingState') == 'paired'
if (not a.name or x.get('deviceProperties', {}).get('name') != a.name or (a.model and x.get('hardwareProperties', {}).get('marketingName') != a.model) or not (wired or network)):
    sys.exit('Device identity or connection (USB connected, or paired on the network) does not match the approved target')
print(f"transport {c.get('transportType')}, tunnel {c.get('tunnelState')}", file=sys.stderr)
env = dict(os.environ, TMPDIR=str(d), CLANG_MODULE_CACHE_PATH=str(d / 'cache'))
exe = d / 'device-live-harness'
if not exe.is_file(): sys.exit('Build the harness first; see docs/physical-device-validation.md')
args = dict(params, device=str(a.device), action=a.action)
log = d / 'harness-output.json'
with log.open('w+') as f:
    check_routes(exe, env, f, production_helper=False)
    status = run_owned(exe, ['--live', json.dumps(args)], environment=env, log=f, timeout=90, max_instances=1)
    f.seek(0); lines = f.read().splitlines()
if status: sys.exit('\n'.join(lines[-3:]))
result = json.loads(lines[-1])
if a.action == 'audit':
    print(json.dumps(result))
    sys.exit(0)
for content in result['result'].get('content', []):
    if content.get('type') == 'image':
        if not a.image: sys.exit('screenshot requires --image')
        a.image.write_bytes(base64.b64decode(content.pop('data')))
        content['path'] = str(a.image)
    if a.action == 'list' and content.get('type') == 'text':
        content['text'] = '\n'.join(line for line in content['text'].splitlines() if str(a.device).upper() in line.upper())
print(json.dumps(result, ensure_ascii=False))
