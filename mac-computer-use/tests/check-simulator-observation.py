#!/usr/bin/env python3
"""Headless production observation bridge regression; no device or GUI is opened."""
from pathlib import Path
import os
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/mac-computer-use/scripts"))
from native_build import run_swift, native_inputs
import tempfile
from native_check_support import isolated_main, check_routes, run_owned

here = Path(__file__).resolve().parent
source = here.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
with tempfile.TemporaryDirectory(prefix='mac-cu-observation-check-') as directory:
    out = Path(directory)
    entry = out / 'main.swift'
    entry.write_text(isolated_main((source / 'main.swift').read_text(), 'runSimulatorObservationBridgeCheck()'))
    executable = out / 'observation-check'
    with (out / 'build.log').open('w') as log:
        compiled = run_swift(['swiftc', *[str(p) for p in sorted(source.glob('*.swift')) if p.name != 'main.swift'],
                        str(entry), str(here / 'simulator-observation-bridge-selfcheck.swift'), '-o', str(executable)],
                       stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if compiled.returncode:
        print((out / "build.log").read_text())
        raise SystemExit(compiled.returncode)
    with (out / 'run.log').open('w') as log:
        check_routes(executable, dict(os.environ), log)
        result = run_owned(executable, ['--native-check'], environment=dict(os.environ), log=log, timeout=20, max_instances=2)
    print((out / 'run.log').read_text())
    raise SystemExit(result)
