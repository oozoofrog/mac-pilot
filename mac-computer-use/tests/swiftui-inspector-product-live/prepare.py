"""Fresh canonical resident/whole-host preparation; no experimental resident."""
import argparse, hashlib, importlib.util, json, plistlib, subprocess, sys, uuid
from pathlib import Path
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent

def prepare(out):
    source = TESTS/'swiftui-hierarchy-probe/Fixture.swift'
    inputs = [source, *HERE.glob('*.py')]
    before = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    subprocess.run([sys.executable, '-B', str(TESTS/'view-hierarchy-fixture/prepare.py'), str(out)], check=True, timeout=300)
    app = out/'SwiftUIProbe.app'; app.mkdir()
    info = plistlib.loads((TESTS/'view-hierarchy-fixture/Info.plist').read_bytes())
    info.update(CFBundleExecutable='SwiftUIProbe', CFBundleIdentifier='local.mac-pilot.swiftui-product.'+uuid.uuid4().hex, CFBundleName='SwiftUI Product Fixture')
    del info['UIApplicationSceneManifest']
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
    commands = [ ['xcrun','swiftc','-parse-as-library','-target','arm64-apple-ios17.0-simulator','-sdk',sdk,str(source),'-o',str(app/'SwiftUIProbe')], ['codesign','--force','--sign','-','--entitlements',str(out/'entitlements.plist'),str(app)], ['codesign','--verify','--strict',str(app)] ]
    with (out/'swiftui-fixture-build.log').open('w') as log:
        for command in commands:
            log.write(repr(command)+'\n'); log.flush()
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    ready=json.loads((out/'prepared.json').read_text())
    ready['ordinaryProductApp']=dict(entry='SwiftUI.App',bundleID=info['CFBundleIdentifier'],app=str(app),linksMacCU=False,launchFlag='287')
    files=[source,*HERE.glob('*.py'),*app.rglob('*')]
    for path, digest in before.items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
            raise RuntimeError('SwiftUI preparation input changed during build: ' + path)
    ready['hashes'].update({str(p.resolve()):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()})
    (out/'prepared.json').write_text(json.dumps(ready,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
    if not a.output.is_absolute() or a.output.exists():p.error('unique absolute output required')
    prepare(a.output)
