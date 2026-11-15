#!/usr/bin/env python3
"""Offline all-view diagnostic replay. Does not modify captures or the original pass criterion."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'view-hierarchy-fixture'))
import compare
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('--capture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
if a.output.exists(): parser.error('output must be new; original evidence is never overwritten')
def read(name): return json.loads((a.capture / name).read_text())
report = compare.diagnose(read('capture-result.json'), read('snapshot.json'), read('oracle-after.json'), a.capture / 'device.png')
report['oracleBeforeAfterCleanupIdentical'] = read('oracle-before.json') == read('oracle-after.json') == read('oracle-cleanup.json')
report['originalFileHashes'] = {name: hashlib.sha256((a.capture/name).read_bytes()).hexdigest() for name in
    ('capture-result.json','snapshot.json','oracle-before.json','oracle-after.json','oracle-cleanup.json','device.png')}
a.output.write_text(json.dumps(report, indent=2))
print('Diagnostic replay written; strict gate passed:', report['strictGate']['passed'], '; fixture rows:', len(report['rows']))
