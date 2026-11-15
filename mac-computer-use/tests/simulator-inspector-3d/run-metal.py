"""Real offscreen Metal frame verification under one exact process and a parent deadline."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
tests = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(tests))
from native_check_support import check_routes,run_owned,instances
source = tests.parent/'skills/mac-computer-use/scripts/mac-cu-src'
files = [source/'SimulatorInspectorModel.swift',source/'SimulatorInspectorRenderer.swift',Path(__file__).with_name('metal.swift')]
out = Path(tempfile.mkdtemp(prefix='mac-pilot-inspector-metal-',dir='/tmp'))
print(out,flush=True)
tracked = files + [Path(__file__), tests/'native_check_support.py']
before = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
(out/'inputs-before.json').write_text(json.dumps(before,indent=2))
frozen = out/'frozen'; frozen.mkdir()
for f in tracked:
    (frozen/f.name).write_bytes(f.read_bytes())
build_files = [frozen/f.name for f in files]
with (out/'compile.log').open('w') as log:
    subprocess.run(['xcrun','swiftc','-parse-as-library',*map(str,build_files),'-o',str(out/'check')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
with (out/'watchdog.log').open('w') as log:
    check_routes(out/'check',dict(os.environ),log,production_helper=False)
    code = run_owned(out/'check',['--native-check'],environment=dict(os.environ),log=log,timeout=20,max_instances=1)
after = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
assert before == after, 'Inputs changed during verification'
(out/'inputs-after.json').write_text(json.dumps(after,indent=2))
(out/'sources.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files+[Path(__file__),tests/'native_check_support.py']},indent=2))
(out/'result.json').write_text(json.dumps({'exit':code,'remaining':instances(out/'check')}))
print((out/'watchdog.log').read_text()); raise SystemExit(code)
