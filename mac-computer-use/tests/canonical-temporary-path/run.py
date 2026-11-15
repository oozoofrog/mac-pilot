"""Actual frozen Swift producer -> unchanged nofollow Python reader/binder. Headless only.

Usage: python3 -B .../run.py /private/tmp/mac-cu-canonical-path-UNIQUE/red-or-green
Keeps complete frozen inputs/logs/receipts. Never executes target tools or helpers.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
SOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
sys.path[:0] = [str(TESTS), str(TESTS/'view-hierarchy-fixture'), str(TESTS/'view-hierarchy-prototype')]
import native_check_support as safety
import ui_capture_contract as contract
from test_ui_capture_contract import CaptureContract


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out/'command.json').write_text(json.dumps([sys.executable, '-B', *sys.argv], indent=2)+'\n')
    inputs = [SOURCE/n for n in ('SimulatorViews.swift', 'SimulatorViewHierarchy.swift', 'SimulatorTargetIdentity.swift')]
    inputs += [HERE/'entry.swift', HERE/'stubs.swift', HERE/'run.py', TESTS/'native_check_support.py',
               TESTS/'view-hierarchy-prototype/ui_capture_contract.py']
    hashes = {str(p): sha(p) for p in inputs}
    frozen = out/'source'; frozen.mkdir()
    for p in inputs:
        shutil.copy2(p, frozen/p.name)
    production = (frozen/'SimulatorViews.swift').read_bytes()
    (frozen/'SimulatorViews.swift').write_bytes(production + (frozen/'entry.swift').read_bytes())
    (out/'source-hashes.json').write_text(json.dumps(hashes, indent=2)+'\n')
    check = out/'check'
    receipts = []
    owned = []
    status = 1
    try:
        with (out/'check.log').open('w') as log:
            command = ['xcrun', 'swiftc', '-parse-as-library', *[str(frozen/n) for n in
                ('SimulatorViews.swift','SimulatorViewHierarchy.swift','SimulatorTargetIdentity.swift','stubs.swift')], '-o', str(check)]
            (out/'compile-command.json').write_text(json.dumps(command,indent=2)+'\n')
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            environment = dict(os.environ)
            # No entry runs until helper/unknown/inherited routes reject under budget=1.
            safety.check_routes(check, environment, log, production_helper=False)
            for kind in ('capture', 'edit', 'revert', 'release'):
                # Existing all-mocked canonical Python traces: no executable guest fixture,
                # Simulator query, process launch, target read or Engine entry.
                fixture = CaptureContract(); fixture.setUp()
                try:
                    fixture.fixture(kind)
                    payload = out/(kind+'-input.json')
                    payload.write_bytes(Path(fixture.argv[4]).read_bytes())
                    receipt = out/(kind+'-swift.json')
                    env = dict(environment, CANONICAL_PATH_INPUT=str(payload), CANONICAL_PATH_RECEIPT=str(receipt))
                    code = safety.run_owned(check, ['--native-check'], environment=env,
                                            log=log, timeout=10, max_instances=1)
                    assert code == 0, code
                    actual = json.loads(receipt.read_text())
                    path = Path(actual['request']); owned.append(path.parent)
                    canonical = path.resolve()
                    raw, pin = contract.read_file(canonical)
                    assert raw == payload.read_bytes()
                    assert stat.S_IMODE(canonical.parent.stat().st_mode) == 0o700
                    assert stat.S_IMODE(canonical.stat().st_mode) == 0o600
                    assert os.stat(path).st_ino == os.stat(canonical).st_ino
                    result = dict(kind=kind, **actual, canonical=str(canonical), sameInode=True,
                                  sha256=pin.sha256, folderMode='0700', fileMode='0600')
                    args = dict(fixture.capture_args, ui_temporary_root=path.parent.parent)
                    argv = fixture.argv[:-1]+[str(path)]
                    try:
                        raw, _ = contract.read_file(path)
                        binding = contract.bind_capture(argv, **args)
                    except contract.ContractError as error:
                        result.update(accepted=False, error=repr(error))
                        receipts.append(result)
                        (out/'results.json').write_text(json.dumps(receipts,indent=2)+'\n')
                        raise
                    assert raw == payload.read_bytes()
                    assert binding.folder == str(path.parent)
                    assert json.loads(binding.request_json) == fixture.expected
                    contract.revalidate(binding)
                    assert str(path) == str(canonical), 'producer must return canonical path'
                    # Preserve nofollow/private/replacement rejection on the actual Swift output.
                    def rejected(action):
                        try:
                            action()
                        except contract.ContractError:
                            return
                        raise AssertionError('unsafe artifact accepted')
                    path.chmod(0o644)
                    rejected(lambda: contract.read_file(path))
                    path.chmod(0o600)
                    moved = path.with_name('held-request.json')
                    path.rename(moved); path.symlink_to(moved)
                    rejected(lambda: contract.read_file(path))
                    path.unlink(); moved.rename(path)
                    directory = path.parent
                    held = directory.with_name(directory.name+'-held')
                    directory.rename(held); directory.symlink_to(held, target_is_directory=True)
                    rejected(lambda: contract.bind_capture(argv, **args))
                    directory.unlink(); held.rename(directory)
                    replacement = path.with_name('replacement.json')
                    replacement.write_bytes(raw); replacement.chmod(0o600); replacement.replace(path)
                    rejected(lambda: contract.revalidate(binding))
                    result['negatives'] = ['public file', 'file symlink', 'ancestor symlink', 'same-bytes inode replacement']
                    result['accepted'] = True
                    receipts.append(result)
                    print('PASS actual Swift path/bytes bound: '+kind, file=log, flush=True)
                finally:
                    fixture.doCleanups()
            status = 0
    finally:
        # Retain actual producer files and bytes inside evidence after all read/bind checks.
        for folder in owned:
            shutil.move(str(folder), out/folder.name)
        current = {p: sha(Path(p)) == value for p,value in hashes.items()}
        (out/'currentness.json').write_text(json.dumps(current,indent=2)+'\n')
        assert all(current.values()), 'inputs changed during check'
        (out/'results.json').write_text(json.dumps(receipts,indent=2)+'\n')
        (out/'exit.json').write_text(json.dumps(dict(exit=status,remainingInstances=safety.instances(check)))+'\n')
    print(out/'check.log')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
