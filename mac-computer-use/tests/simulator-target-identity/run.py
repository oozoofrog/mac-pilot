"""Finite mock-only native identity checks. No process identity or Simulator query."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
tests = here.parent
sys.path.insert(0, str(tests))
from native_check_support import check_routes, run_owned, instances

parser = argparse.ArgumentParser()
parser.add_argument('--routing-only', action='store_true')
args = parser.parse_args()
source = tests.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
out = Path(tempfile.mkdtemp(prefix='mac-cu-native-identity-', dir='/tmp'))
print(out, flush=True)
inputs = [source/'SimulatorViews.swift', here/'routing.swift', here/'routing-main.swift',
          Path(__file__), tests/'native_check_support.py']
if not args.routing_only:
    inputs += [source/'SimulatorTargetIdentity.swift', here/'main.swift']
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(out/'sources.json').write_text(json.dumps(before, indent=2))

caller = (source/'SimulatorViews.swift').read_text().split('func simulatorViewCaptureTarget(', 1)[1]
caller = 'func simulatorViewCaptureTarget(' + caller.split('/// Production backend,', 1)[0]
(out/'Caller.swift').write_text('import Foundation\n' + caller)
cases = [('routing', [here/'routing.swift', out/'Caller.swift'], here/'routing-main.swift')]
if not args.routing_only:
    cases.append(('reader', [source/'SimulatorTargetIdentity.swift'], here/'main.swift'))
results = []
for name, sources, main in cases:
    case = out/name
    case.mkdir()
    (case/'main.swift').write_bytes(main.read_bytes())
    executable = case/'check'
    with (case/'compile.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', *map(str, sources), str(case/'main.swift'), '-o', str(executable)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    with (case/'watchdog.log').open('w') as log:
        check_routes(executable, dict(os.environ), log, production_helper=False)
        code = run_owned(executable, ['--native-check'], environment=dict(os.environ), log=log,
                         timeout=15, max_instances=1)
    remaining = instances(executable)
    results.append(dict(case=name, exit=code, remaining=remaining,
                        executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest()))
    (out/'results.json').write_text(json.dumps(results, indent=2))
    print((case/'watchdog.log').read_text(), flush=True)
    if code or remaining:
        raise SystemExit(code or 1)
after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
if before != after:
    raise RuntimeError('identity check sources changed during verification')
print('PASS current-source mock-only identity checks; no native target access claimed')
