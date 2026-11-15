"""Bounded command-line identity checks; no AppKit, service connection or guest input."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

tests = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(tests))
from native_check_support import check_routes, run_owned, instances
source = tests.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
owned = [source/'SimulatorInspectionLifecycle.swift', Path(__file__).with_name('Stubs.swift'), Path(__file__).with_name('main.swift')]
out = Path(tempfile.mkdtemp(prefix='mac-pilot-inspection-lifecycle-', dir='/tmp'))
with (out/'compile.log').open('w') as log:
    subprocess.run(['xcrun','swiftc',*map(str,owned),'-o',str(out/'check')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
with (out/'watchdog.log').open('w') as log:
    check_routes(out/'check',dict(os.environ),log,production_helper=False)
    code = run_owned(out/'check',['--native-check',*sys.argv[1:]],environment=dict(os.environ),log=log,timeout=20,max_instances=1)
(out/'sources.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in owned+[Path(__file__),tests/'native_check_support.py']},indent=2))
(out/'result.json').write_text(json.dumps({'exit':code,'remaining':instances(out/'check')}))
print(out); print((out/'watchdog.log').read_text())
raise SystemExit(code)
