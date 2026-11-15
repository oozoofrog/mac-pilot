#!/usr/bin/env python3
"""Build ARC Foundation fixtures in unique /tmp; run only owned CLI processes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location('native_check_support', HERE.parent / 'native_check_support.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def main():
    output = Path(tempfile.mkdtemp(prefix='mac-cu-view-lifetime-', dir='/tmp'))
    print(output, flush=True)
    with (output / 'run.log').open('w', buffering=1) as log:
        def command(args):
            print('COMMAND ' + json.dumps([str(x) for x in args]), file=log)
            result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            print(f'EXIT {result.returncode}', file=log)
            result.check_returncode()
        command(['sw_vers'])
        command(['uname', '-a'])
        command(['xcrun', 'clang', '--version'])
        flags = ['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation', '-g', '-O0']
        for index in range(2):
            command(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation', '-dynamiclib', str(HERE / 'registry-module.c'), '-o', str(output / f'module{index}.dylib')])
        binary = output / 'lifetime-check'
        command(flags + [str(HERE / 'main.m'), str(HERE / 'Operation.m'), '-o', str(binary)])
        command(['xcrun', 'otool', '-L', str(binary)])
        sources = [*HERE.glob('*.c'), *HERE.glob('*.m'), *HERE.glob('*.h'), HERE / 'run.py', HERE.parent / 'native_check_support.py']
        evidence = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [binary, output / 'module0.dylib', output / 'module1.dylib']}
        (output / 'sha256.json').write_text(json.dumps(evidence, indent=2) + '\n')
        # Source dispatch verification precedes all launches, including rejected routes.
        source = (HERE / 'main.m').read_text().split('int main(int argc')[1]
        assert source.index('return 64;') < source.index('@autoreleasepool') < source.index('lifetime();')
        assert 'strcmp(argv[1], "--native-check")' in source and 'getenv("MAC_CU_NATIVE_CHECK_CHILD")' in source
        print('PASS source dispatch before autorelease/test entry', file=log)
        env = dict(os.environ, LIFETIME_MODULE_DIR=str(output))
        # Documented selfcheck API rejects production helpers (none linked here).
        support.check_routes(binary, env, log, production_helper=False)
        for args in [['--native-check', '--extra'], ['--guide'], ['--update'], ['--client']]:
            rc = support.run_owned(binary, args, environment=env, log=log, timeout=5, max_instances=1)
            print(f'EXTRA_ROUTE {args!r} EXIT {rc}', file=log)
            assert rc == 64
        rc = support.run_owned(binary, ['--native-check'], environment=env, log=log, timeout=30, max_instances=1)
        print(f'HARNESS EXIT {rc}', file=log)
        remaining = support.instances(binary)
        print(f'OWNED_LEFTOVERS {remaining}', file=log)
        assert rc == 0 and not remaining
        command(['python3', '-m', 'unittest', 'discover', '-s', str(ROOT / 'scripts/tests'), '-p', 'test_native_check_safety.py', '-v'])
        command(['python3', str(ROOT / 'scripts/validate_distribution.py')])
        command(['git', '-C', str(ROOT), 'diff', '--check', '--', str(HERE)])
    print((output / 'run.log').read_text())


if __name__ == '__main__':
    main()
