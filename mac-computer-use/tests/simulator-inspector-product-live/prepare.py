"""Headless whole-source UI build; requires a fresh ordinary UIKit product preparation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
SOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
sys.path[:0] = [str(TESTS), str(TESTS / 'view-hierarchy-fixture'), str(SOURCE.parent)]
import native_check_support as native
import session
import ui_tool_contract
from native_build import run_swift, native_inputs, build_view_capture_resources

def prepare(product, out, host_only=False):
    if product:
        session.verify_prepared(product)
        manifest = json.loads((product / 'prepared.json').read_text())
        assert manifest['wholeProbeVerified'] and manifest['ordinaryProductApp']['entry'] in ('UIKit C main', 'SwiftUI.App')
    out.mkdir(mode=0o700)
    app = out / 'InspectorProductCheck.app'
    binary = app / 'Contents/MacOS/check'
    binary.parent.mkdir(parents=True)
    resources = app / 'Contents/Resources'; resources.mkdir()
    if product:
        shutil.copytree(product / 'view-capture', resources / 'view-capture')
    else:
        build_view_capture_resources(resources / 'view-capture')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.mac-pilot.inspector-product-check', CFBundleExecutable='check', CFBundleName='Inspector Product Check', LSUIElement=True)))
    sources = sorted(p for p in SOURCE.glob('*.swift') if p.name != 'main.swift')
    tool_hashes = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                   for path in ui_tool_contract.required_paths()} if not host_only else None
    if tool_hashes is not None:
        ui_tool_contract.Configuration.read(ui_tool_contract.DEVELOPER, tool_hashes)
    inputs = [*sources, *native_inputs(SOURCE), SOURCE / 'main.swift', HERE / ('host.swift' if host_only else 'live.swift'), HERE / 'prepare.py', HERE / 'runner.py', HERE / 'evidence.py', TESTS / 'native_check_support.py', *([product / 'prepared.json'] if product else []), *(SOURCE.parent / 'view-capture').glob('*'), *(TESTS / 'view-hierarchy-prototype').glob('ui_*contract.py'), *map(Path, tool_hashes or {})]
    frozen = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    main = out / 'main.swift'
    main.write_text(native.isolated_main((SOURCE / 'main.swift').read_text(), 'runInspectorHostCheck()' if host_only else 'runInspectorProductLive()'))
    with (out / 'compile.log').open('w') as log:
        run_swift(['swiftc', *map(str, sources), str(HERE / ('host.swift' if host_only else 'live.swift')), str(main), '-o', str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, timeout=15)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, timeout=15)
    with (out / 'routes.log').open('w') as log:
        native.check_routes(binary, dict(os.environ), log)
    if product: session.verify_prepared(product)
    for path, digest in frozen.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest, 'changed during build: ' + path
    frozen.update({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in [main, *app.rglob('*')] if p.is_file()})
    (out / 'prepared.json').write_text(json.dumps(dict(hashes=frozen, product=str(product.resolve()) if product else None, binary=str(binary.resolve()), uiToolHashes=tool_hashes, dispatchPassed=True, liveVerified=False), indent=2))
    print('PASS headless UI build/sign/routes only: ' + str(out))

if __name__ == '__main__':
    p = argparse.ArgumentParser(allow_abbrev=False)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--product', type=Path); mode.add_argument('--headless-entry', action='store_true')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--host-only', action='store_true')
    a = p.parse_args()
    if not a.output.is_absolute() or a.output.exists(): p.error('unique absolute output required')
    prepare(a.product.resolve() if a.product else None, a.output, a.host_only)
