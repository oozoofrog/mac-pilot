"""Bounded host-only focus regression; no guest install, attach, capture or edits."""
import argparse
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import native_check_support as native
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'view-hierarchy-fixture'))
import session

if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--log', required=True, type=Path)
    args = parser.parse_args()
    session.verify_prepared(args.build)
    manifest = json.loads((args.build / 'prepared.json').read_text())
    binary = Path(manifest['binary'])
    with args.log.open('x') as log:
        native.check_routes(binary, dict(os.environ), log)
        status = native.run_owned(binary, ['--native-check'], environment=dict(os.environ), log=log,
                                  timeout=30, max_instances=1)
        print('remaining owned instances:', native.instances(binary), file=log)
    raise SystemExit(status)
