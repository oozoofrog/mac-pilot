"""Compile owned modules; run model/math only, strict entry, one executable, parent deadline."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_check_support import check_routes, run_owned
root = Path(__file__).resolve().parents[3]
source = root / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src'
out = Path(tempfile.mkdtemp(prefix='mac-pilot-inspector-headless-'))
parser_path = source.parent / 'view-capture/swiftui_graph.py'
spec = importlib.util.spec_from_file_location('inspector_graph_fixture_parser', parser_path)
parser = importlib.util.module_from_spec(spec); sys.modules[spec.name] = parser; spec.loader.exec_module(parser)
fixture_files = sorted(Path(__file__).with_name('fixtures').glob('*-sanitized.json'))
for fixture in fixture_files:
    parsed = parser.classify(fixture.read_bytes())
    assert parsed['status'] == 'rootArray', parsed
    (out / (fixture.stem + '-normalized.json')).write_text(json.dumps(parsed))
files = [source / ('SimulatorInspector' + name + '.swift') for name in ('Model','Renderer','Window')]
tracked = files + [Path(__file__).with_name('main.swift'), Path(__file__), parser_path, *fixture_files]
before = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked}
(out/'inputs-before.json').write_text(json.dumps(before, indent=2))
print(out, flush=True)
frozen = out/'frozen'; frozen.mkdir()
for f in tracked:
    (frozen/f.name).write_bytes(f.read_bytes())
build_files = [frozen/f.name for f in files]
with (out / 'compile.log').open('w') as log:
    subprocess.run(['xcrun','swiftc','-typecheck',*map(str,build_files)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
    subprocess.run(['xcrun','swiftc',str(build_files[0]),str(frozen/'main.swift'),'-o',str(out/'model-check')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
(out/'sources.sha256').write_text('\n'.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+str(f) for f in files + [Path(__file__).with_name('main.swift'),Path(__file__)])+'\n')
with (out/'headless.log').open('w') as log:
    env = dict(os.environ, INSPECTOR_FIXTURE_DIR=str(out))
    check_routes(out/'model-check',env,log,production_helper=False)
    code = run_owned(out/'model-check',['--native-check',*sys.argv[1:]],environment=env,log=log,timeout=20,max_instances=1)
after = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked}
(out/'inputs-after.json').write_text(json.dumps(after, indent=2))
assert before == after, 'Inputs changed during verification'
(out/'artifacts.json').write_text(json.dumps({str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.is_file()}, indent=2))
print((out/'headless.log').read_text())
raise SystemExit(code)
