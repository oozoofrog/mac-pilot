#!/usr/bin/env python3
"""Execute the canonical edit expression in a Foundation-only host shim; never UIKit/LLDB."""
import hashlib
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
RESOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/view-capture'
sys.path.insert(0, str(TESTS))
import native_check_support as native


def main():
    out = Path(tempfile.mkdtemp(prefix='mac-cu-production-edit-'))
    print(out, flush=True)
    # Substitute ONLY the transport data/answer locations. Every admission,
    # registry, traversal, journal, setter and undo branch is canonical production.
    expression = (RESOURCE / 'edit.expr').read_text().replace('__OPERATION__', (RESOURCE / 'operation.inc').read_text())
    assert expression.count('@"__WIRE__"') == expression.count('@__ANSWER_PATH__') == 1
    expression = expression.replace('@"__WIRE__"', '[requestData base64EncodedStringWithOptions:0]').replace('@__ANSWER_PATH__', 'answerPath')
    main_source = (HERE / 'main.mm').read_text()
    spec = importlib.util.spec_from_file_location('production_capture', RESOURCE / 'capture.py')
    capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)
    texture_request = base64.b64encode(json.dumps(capture.hierarchy_request(True)).encode()).decode()
    main_source = '#define TEST_TEXTURE_REQUEST @"' + texture_request + '"\n' + main_source
    main_source += '\nstatic BOOL ExecuteExpression(NSData *requestData, NSString *answerPath) { return ' + expression + '; }\n'
    source = out / 'main.mm'; source.write_text(main_source)
    binary = out / 'production-edit'
    with (out / 'run.log').open('w') as log:
        command = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fobjc-exceptions', '-Wall', '-Wextra', '-Werror',
                   '-I', str(HERE), str(source), '-framework', 'Foundation', '-o', str(binary)]
        log.write('COMMAND ' + repr(command) + '\n'); log.flush()
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        for args, env in [([], dict(os.environ)), (['--check-screen-recording'], dict(os.environ)),
                          (['--daemon'], dict(os.environ)), (['--unknown'], dict(os.environ)),
                          (['--native-check', str(out / 'answer.json')], dict(os.environ, MAC_CU_NATIVE_CHECK_CHILD='1'))]:
            assert native.run_owned(binary, args, environment=env, log=log, timeout=5, max_instances=1) == 64
        code = native.run_owned(binary, ['--native-check', str(out / 'answer.json')], environment=dict(os.environ),
                                log=log, timeout=30, max_instances=1)
        assert not native.instances(binary)
        assert code == 0, f'production expression test failed: {out}/run.log'
    inputs = [RESOURCE / 'edit.expr', HERE / 'UIKitShim.h', HERE / 'main.mm', Path(__file__), source, binary]
    (out / 'sha256.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
    print((out / 'run.log').read_text(), end='')
    print('PASS native headless expression checks; exact executable leftovers: 0')
    subprocess.run([sys.executable, '-B', str(HERE / 'check-pool-lifetime.py')], check=True, timeout=180)


if __name__ == '__main__':
    main()
