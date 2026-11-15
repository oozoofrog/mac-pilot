"""Headless snapshot checks, frozen inputs, guarded console dispatch. No guest access."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import native_check_support as safety
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=False)
source=HERE.parents[1]/'skills/mac-computer-use/scripts/mac-cu-src/SimulatorViewHierarchy.swift'
model=source.with_name('SimulatorInspectorModel.swift')
inputs=[source,model,HERE/'main.swift']
for p in inputs:shutil.copy2(p,out/p.name)
(out/'source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},indent=2))
with (out/'check.log').open('w') as log:
    subprocess.run(['swiftc',str(out/source.name),str(out/model.name),str(out/'main.swift'),'-o',str(out/'check')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    safety.check_routes(out/'check',dict(os.environ),log,production_helper=False)
    status=safety.run_owned(out/'check',['--native-check'],environment=dict(os.environ),log=log,timeout=15,max_instances=1)
    assert status==0,status
    assert not safety.instances(out/'check')
print(out/'check.log')
