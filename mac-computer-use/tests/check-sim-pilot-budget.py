#!/usr/bin/env python3
"""sim-pilot budget: the CLI contract a hook builds on. Reads the simulator list of this Mac; boots and claims nothing.

usage: check-sim-pilot-budget.py <output folder>
"""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
tool = out / 'sim-pilot'
subprocess.run(['swiftc', '-O', str(root / 'simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift'), '-o', str(tool)], check=True)
count = 0


def expect(condition, message):
    global count
    count += 1
    if not condition:
        sys.exit(f'FAIL: {message}')


def budget(settings, *arguments):
    """(exit code, JSON) of `sim-pilot budget` with these settings (None: no settings file)."""
    file = out / 'budget.json'
    file.unlink(missing_ok=True)
    if settings is not None:
        file.write_text(json.dumps(settings))
    done = subprocess.run([str(tool), 'budget', *arguments], env=dict(os.environ, SIM_PILOT_BUDGET_FILE=str(file)),
                          capture_output=True, text=True, timeout=120)
    return done.returncode, json.loads(done.stdout)


code, plain = budget(None)
expect(code == 0, 'budget without --would-boot always exits 0')
expect(plain['configured'] is False and plain['limit']['mode'] == 'auto' and plain['autoShutdown'] == {'enabled': False, 'idleMinutes': 15},
       'no settings file: automatic limit, no automatic shutdown')
limit = plain['limit']
expect(limit['total'] == limit['automaticTotal'] >= 1 and limit['defaultSet'] == max(1, limit['total'] - 1) and limit['memoryGiB'] >= 1,
       'the automatic limit and its default-set part')
expect(set(plain) >= {'booted', 'canBoot', 'devices', 'over'} and 'wouldBoot' not in plain, 'top-level fields')
booted = plain['booted']
expect(booted['total'] == len(plain['devices']) == booted['defaultSet'] + booted['previews'], 'counts match the device rows')
for device in plain['devices']:
    expect(set(device) == {'udid', 'name', 'runtime', 'set', 'owners', 'owned', 'mine'} and device['set'] in ('default', 'previews')
           and device['owned'] == bool(device['owners']) and device['udid'] == device['udid'].upper(), f'device row {device}')
    for owner in device['owners']:
        expect(set(owner) == {'kind', 'by', 'pid'} and owner['kind'] in ('sim-pilot', 'agent-device', 'process', 'test-runner'), f'owner {owner}')
expect(plain['over'] == (booted['total'] > limit['total'] or booted['defaultSet'] > limit['defaultSet']), 'over')

for total in (1, 12):
    code, manual = budget({'schemaVersion': 1, 'limit': total, 'autoShutdown': {'enabled': True, 'idleMinutes': 20}}, '--would-boot')
    expect(manual['configured'] is True and manual['limit']['mode'] == 'manual' and manual['limit']['total'] == total
           and manual['limit']['automaticTotal'] == limit['automaticTotal'] and manual['autoShutdown'] == {'enabled': True, 'idleMinutes': 20},
           f'manual limit {total}')
    would, now = manual['wouldBoot'], manual['booted']
    fits = now['total'] < total and now['defaultSet'] < max(1, total - 1)
    expect(would['set'] == 'default' and would['alreadyBooted'] is False and would['allowed'] == fits == manual['canBoot']['default']
           and would['reason'], f'would-boot at limit {total}: {would}')
    expect(code == (0 if fits else 3), f'exit code {code} at limit {total}: 0 when allowed, 3 when full')
    code, preview = budget({'limit': total}, '--would-boot', '--set', 'previews')
    expect(preview['wouldBoot']['set'] == 'previews' and preview['wouldBoot']['allowed'] == (preview['booted']['total'] < total)
           and code == (0 if preview['wouldBoot']['allowed'] else 3), f'a Previews device only needs a free place in the total ({total})')

if plain['devices']:
    device = plain['devices'][0]
    code, same = budget({'limit': 1}, '--would-boot', '--udid', device['udid'].lower())
    expect(code == 0 and same['wouldBoot']['alreadyBooted'] is True and same['wouldBoot']['allowed'] is True
           and same['wouldBoot']['udid'] == device['udid'] and same['wouldBoot']['set'] == device['set'],
           'a booted device is always allowed, also at a full limit')
code, unknown = budget({'limit': 1}, '--would-boot', '--udid', '00000000-0000-0000-0000-000000000000')
expect(unknown['wouldBoot']['alreadyBooted'] is False and code == (0 if unknown['wouldBoot']['allowed'] else 3), 'an unknown device counts as a new default-set boot')

done = subprocess.run([str(tool), 'budget', '--would-boot', '--set', 'other'], capture_output=True, text=True, timeout=120)
expect(done.returncode == 1 and 'sim-pilot:' in done.stderr, 'a wrong --set is an error (exit 1), not a refusal')
done = subprocess.run([str(tool), 'acquire'], capture_output=True, text=True, timeout=120)
expect(done.returncode == 1, 'acquire needs --udid or --name')
done = subprocess.run([str(tool), 'acquire', '--name', 'no such simulator 7f3a'], capture_output=True, text=True, timeout=120)
expect(done.returncode == 1 and '없습니다' in done.stderr, 'acquire of a device that does not exist boots nothing')
print(f'PASS {count} sim-pilot budget assertions; nothing booted or claimed')
