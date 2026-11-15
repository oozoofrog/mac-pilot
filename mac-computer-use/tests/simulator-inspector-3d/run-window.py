"""Host-only real inspector/browser. Archived display and explicitly synthetic callbacks only."""
from pathlib import Path
import hashlib, json, os, subprocess, sys, tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from native_check_support import check_routes, run_owned, instances
here=Path(__file__).resolve().parent
src=here.parents[1]/'skills/mac-computer-use/scripts/mac-cu-src'
out=Path(tempfile.mkdtemp(prefix='mac-pilot-inspector-window-',dir='/tmp'))
print(out,flush=True)
# Compile the exact browser class in isolation, without Simulator transport or coordinator.
toolbox=src/'SimulatorToolbox.swift'
s=toolbox.read_text(); browser=out/'Browser.swift'
browser.write_text('import AppKit\n'+s[s.index('final class SimulatorElementBrowser:'):s.index('/// UIKit snapshots remain separate')])
files=[src/('SimulatorInspector'+n+'.swift') for n in ('Model','Renderer','Window')]+[src/'SimulatorAXUIModel.swift',browser,here.parent/'native-selfcheck-entry.swift',here/'window.swift']
with (out/'compile.log').open('w') as log:
    subprocess.run(['xcrun','swiftc','-parse-as-library',*map(str,files),'-o',str(out/'check')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
env=dict(os.environ, INSPECTOR_HOST_OUTPUT=str(out), INSPECTOR_ARCHIVE=sys.argv[1])
with (out/'watchdog.log').open('w') as log:
    check_routes(out/'check',env,log,production_helper=False)
    code=run_owned(out/'check',['--native-check'],environment=env,log=log,timeout=55,max_instances=1)
(out/'sources.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files+[toolbox,Path(__file__),Path(env['INSPECTOR_ARCHIVE'])]},indent=2))
(out/'result.json').write_text(json.dumps({'exit':code,'remaining':instances(out/'check'),'scope':'host archived display + mock callbacks; no guest runtime'}))
print((out/'watchdog.log').read_text());sys.exit(code)
