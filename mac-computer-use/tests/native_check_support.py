"""Bounded, owned native checks. No registration, global process names or Dock reset."""
from __future__ import annotations
import os
import argparse
import math
from pathlib import Path
import signal
import subprocess
import time
import sys

CHILD_MARKER = 'MAC_CU_NATIVE_CHECK_CHILD'
DISPATCH_MARKER = '// Chrome starts mac-cu as the native messaging host'


def isolated_main(production: str, entry: str) -> str:
    if production.count(DISPATCH_MARKER) != 1:
        raise ValueError('Inspect changed production dispatch before generating a native test.')
    definitions, dispatch = production.split(DISPATCH_MARKER)
    if 'if CommandLine.arguments.contains("--check-screen-recording")' not in dispatch:
        raise ValueError('The production permission helper route must be present.')
    return definitions + '''
// Test entry is explicit. Permission helper children retain production dispatch below;
// all other helper/client/daemon routes fail before any test UI is initialized.
let nativeCheckArguments = Array(CommandLine.arguments.dropFirst())
if nativeCheckArguments != ["--check-screen-recording"] {
    guard nativeCheckArguments == ["--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
    setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
    ''' + entry + '\n}\n' + DISPATCH_MARKER + dispatch


def instances(executable: Path) -> list[int]:
    target = str(executable.resolve())
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=3).splitlines()
    result = []
    for row in rows:
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and os.path.realpath(parts[1]) == target:
            result.append(int(parts[0]))
    return result


def _signal(pid: int, sig: int):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


def cleanup(executable: Path, group: int):
    # Freeze before killing to stop a recursive app from outrunning the snapshot.
    try:
        for _ in range(3):
            owned = instances(executable)
            for pid in owned:
                _signal(pid, signal.SIGSTOP)
            for pid in owned:
                _signal(pid, signal.SIGKILL)
            if not owned:
                break
    finally:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin can return EPERM for a group containing only unreaped zombies.
            # Do not hide a real signaling failure while a live group member remains.
            rows = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True, timeout=3).splitlines()
            if any(len(parts := row.split()) == 2 and int(parts[0]) == group and not parts[1].startswith('Z') for row in rows):
                raise


def run_owned(executable: Path, arguments: list[str], *, environment: dict[str, str],
              log, timeout: float, max_instances: int = 2) -> int:
    if not math.isfinite(timeout) or timeout <= 0 or max_instances < 1:
        raise ValueError('Every native run needs a positive deadline and instance budget.')
    if instances(executable):
        raise RuntimeError('This exact test executable already runs; stop its owning check first.')
    process = subprocess.Popen([str(executable), *arguments], env=environment, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + timeout
    def interrupted(signum, frame):
        raise InterruptedError(f'Native check interrupted by signal {signum}.')
    previous_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in previous_handlers:
            signal.signal(sig, interrupted)
        while True:
            count = len(instances(executable))
            if count > max_instances:
                raise RuntimeError(f'Native check exceeded its instance budget ({count} > {max_instances}).')
            status = process.poll()
            if status is not None:
                # An exited root with surviving app copies is a failed run, even on exit 0.
                if instances(executable):
                    raise RuntimeError('Native check left owned application instances after root exit.')
                return status
            if time.monotonic() >= deadline:
                raise TimeoutError(f'Native check exceeded its {timeout:g}s deadline.')
            time.sleep(0.1)
    finally:
        try:
            for sig in previous_handlers:
                signal.signal(sig, signal.SIG_IGN)
            try:
                cleanup(executable, process.pid)
            finally:
                process.wait(timeout=5)
            for _ in range(20):
                if not instances(executable):
                    break
                time.sleep(0.05)
            if instances(executable):
                raise RuntimeError('Owned native app instances remain after cleanup.')
        finally:
            for sig, handler in previous_handlers.items():
                signal.signal(sig, handler)


def check_routes(executable: Path, environment: dict[str, str], log, *, production_helper: bool = True):
    cases = [(['--check-screen-recording'], environment, {0, 1} if production_helper else {64}),
             (['--native-check'], dict(environment, **{CHILD_MARKER: '1'}), {64}),
             (['--daemon'], environment, {64}), ([], environment, {64}),
             (['--unknown-native-check'], environment, {64})]
    for arguments, env, expected in cases:
        status = run_owned(executable, arguments, environment=env, log=log, timeout=5, max_instances=1)
        if status not in expected:
            raise RuntimeError(f'Native dispatch guard failed for {arguments}: exit {status}.')
        print(f'PASS native dispatch {arguments}: exit {status}', file=log, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selfcheck', type=Path, required=True, help='An independent UI selfcheck using native-selfcheck-entry.swift.')
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    env = dict(os.environ)
    check_routes(args.selfcheck, env, sys.stdout, production_helper=False)
    raise SystemExit(run_owned(args.selfcheck, ['--native-check'], environment=env, log=sys.stdout, timeout=args.timeout))
