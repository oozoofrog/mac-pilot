#!/usr/bin/env python3
"""Execute both canonical expression pool modes in Foundation; not LLDB recovery evidence."""
import base64
import hashlib
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
    out = Path(tempfile.mkdtemp(prefix='mac-cu-expression-pool-'))
    print(out, flush=True)
    spec = importlib.util.spec_from_file_location('production_capture', RESOURCE / 'capture.py')
    capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)
    wire = base64.b64encode(json.dumps(capture.hierarchy_request(True)).encode()).decode()
    expression = (RESOURCE / 'edit.expr').read_text().replace('__OPERATION__', (RESOURCE / 'operation.inc').read_text())
    assert expression.count('@"__WIRE__"') == expression.count('@__ANSWER_PATH__') == 1
    expression = expression.replace('@"__WIRE__"', '[requestData base64EncodedStringWithOptions:0]').replace('@__ANSWER_PATH__', 'answerPath')
    source = out / 'main.mm'
    source.write_text('#define TEST_TEXTURE_REQUEST @"' + wire + '"\n#define main ExistingMain\n'
        + (HERE / 'main.mm').read_text() + '\n#undef main\n' + (HERE / 'pool-lifetime.mm').read_text()
        + '\nstatic BOOL ExecuteExpression(NSData *requestData, NSString *answerPath) { return ' + expression + '; }\n')
    inputs = [Path(__file__), HERE / 'pool-lifetime.mm', HERE / 'main.mm', HERE / 'UIKitShim.h', RESOURCE / 'edit.expr', source]
    try:
        with (out / 'run.log').open('w') as log:
            for mode, flag in [('no-exceptions', '-fno-objc-exceptions'), ('exceptions', '-fobjc-exceptions')]:
                binary = out / mode
                command = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', flag, '-Wall', '-Wextra', '-Werror',
                    '-I', str(HERE), str(source), '-framework', 'Foundation', '-o', str(binary)]
                log.write('COMMAND ' + repr(command) + '\n'); log.flush()
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
                inputs.append(binary)
                for args, env in [([], dict(os.environ)), (['--check-screen-recording'], dict(os.environ)),
                        (['--daemon'], dict(os.environ)), (['--unknown'], dict(os.environ)),
                        (['--native-check', str(out / 'answer.json')], dict(os.environ, MAC_CU_NATIVE_CHECK_CHILD='1'))]:
                    assert native.run_owned(binary, args, environment=env, log=log, timeout=5, max_instances=1) == 64
                result = native.run_owned(binary, ['--native-check', str(out / 'answer.json')],
                    environment=dict(os.environ), log=log, timeout=15, max_instances=1)
                assert not native.instances(binary)
                assert result == 0, f'{mode} lifetime assertion failed: {out}/run.log'
    finally:
        (out / 'sha256.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
        print((out / 'run.log').read_text(), end='')
    print('PASS both pool modes; exact executable leftovers: 0')


if __name__ == '__main__':
    main()
