"""Disposable CLI fixture experiment; never points at a user app or production collector.

Run only in the agreed test window. Each case records evidence, not a safety certification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent

def inspect(binary, pid):
    parts = subprocess.check_output([str(binary), 'inspect', str(pid)], text=True, timeout=3).strip().split(maxsplit=6)
    return {'pid': int(parts[0]), 'start': parts[1] + ':' + parts[2],
            'state': int(parts[3]), 'parent': int(parts[5]), 'path': os.path.realpath(parts[6])}

class DebuggerAudit:
    """Record observed ancestry; sampling cannot prove an unobserved server never existed."""
    def __init__(self, process, binary, server_path):
        self.process, self.binary, self.server_path = process, binary, server_path
        self.anchor = inspect(binary, process.pid)
        self.seen = {process.pid: self.anchor}
        self.servers = {}
        self.audit_errors = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()

    def watch(self):
        while not self.stop.is_set():
            try:
                rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True, timeout=3).splitlines()
                pairs = [tuple(map(int, row.split())) for row in rows if len(row.split()) == 2]
                # Add a child only when its observed parent's current identity still matches.
                changed = True
                while changed:
                    changed = False
                    for pid, parent in pairs:
                        if pid in self.seen or parent not in self.seen:
                            continue
                        try:
                            current_parent = inspect(self.binary, parent)
                            child = inspect(self.binary, pid)
                        except (OSError, subprocess.SubprocessError, ValueError, IndexError):
                            continue
                        if current_parent['start'] != self.seen[parent]['start'] or child['parent'] != parent:
                            continue
                        self.seen[pid] = child
                        if child['path'] == self.server_path:
                            self.servers[pid] = child
                        changed = True
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                self.audit_errors.append(str(error))
            self.stop.wait(.05)

    def finish(self, output):
        self.stop.set()
        self.thread.join(timeout=5)
        errors = list(self.audit_errors)
        for pid, recorded in self.servers.items():
            try:
                current = inspect(self.binary, pid)
                if current['start'] != recorded['start'] or current['path'] != recorded['path']:
                    errors.append('server PID identity changed: ' + str(pid))
                    continue
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        current = inspect(self.binary, pid)
                    except (OSError, subprocess.SubprocessError, ValueError, IndexError) as error:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        errors.append('cannot verify server exit ' + str(pid) + ': ' + str(error))
                        break
                    if current['start'] != recorded['start'] or current['path'] != recorded['path']:
                        break
                    time.sleep(.05)
                else:
                    # The exact recorded server is still alive; never signal the target fixture.
                    os.kill(pid, signal.SIGKILL)
                    errors.append('server needed forced cleanup: ' + str(pid))
            except (OSError, subprocess.SubprocessError, ValueError, IndexError) as error:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                except OSError as permission:
                    errors.append('cannot verify server ' + str(pid) + ': ' + str(permission))
                else:
                    errors.append('cannot inspect live server ' + str(pid) + ': ' + str(error))
        output.write_text(json.dumps({'anchor': self.anchor, 'observed': list(self.seen.values()),
                                      'servers': list(self.servers.values()), 'errors': errors}, indent=2))
        return not self.thread.is_alive() and not errors

def stop_owned(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)

def launch_lldb(script, env, log):
    # LLDB receives a Python filename from this repository, not target-provided text.
    command = 'script exec(compile(open(' + repr(str(script)) + ').read(), ' + repr(str(script)) + ', "exec"))'
    return subprocess.Popen(['/usr/bin/xcrun', 'lldb', '--no-lldbinit', '--batch', '-o', command], env=env,
                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)

def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt('runner interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True, help='New, unique directory for evidence')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'source-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(HERE.iterdir()) if p.suffix in ('.c', '.py')}, indent=2))
    binary = out / 'owned-fixture'
    developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True, timeout=5).strip()).resolve()
    server_path = (developer.parent / 'SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver').resolve()
    if not server_path.is_file():
        raise RuntimeError('Xcode debugserver executable cannot be identified; refusing to run')
    subprocess.run(['/usr/bin/clang', '-g', '-O0', str(HERE / 'fixture.c'), '-o', str(binary)], check=True, timeout=30)
    entitlements = out / 'fixture-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(binary)], check=True, timeout=30)
    failures = 0
    for mode in ('success', 'error', 'timeout', 'cancel', 'exit', 'paused', 'traced'):
        fixture = collector = holder = None
        collector_audit = holder_audit = None
        result = out / (mode + '.json')
        ready, release = out / (mode + '.ready'), out / (mode + '.release')
        try:
            with (out / (mode + '.log')).open('w') as log:
                fixture = subprocess.Popen([str(binary), 'fixture'], stdout=subprocess.PIPE,
                                           stderr=log, start_new_session=True, text=True)
                if not select.select([fixture.stdout], [], [], 5)[0] or fixture.stdout.readline().strip() != 'ready':
                    raise RuntimeError('fixture failed to start')
                values = subprocess.check_output([str(binary), 'probe', str(fixture.pid)], text=True, timeout=3).split()
                identity = values[1] + ':' + values[2]
                env = dict(os.environ, MAC_CU_FIXTURE_PID=str(fixture.pid), MAC_CU_FIXTURE_ID=identity,
                           MAC_CU_FIXTURE_OWNER=str(os.getpid()), MAC_CU_FIXTURE_PATH=str(binary),
                           MAC_CU_FIXTURE_RESULT=str(result), MAC_CU_FIXTURE_MODE=mode,
                           MAC_CU_EXPRESSION_READY=str(out / (mode + '.expression-ready')),
                           MAC_CU_HOLDER_READY=str(ready), MAC_CU_HOLDER_RELEASE=str(release))
                if mode == 'paused':
                    os.kill(fixture.pid, signal.SIGSTOP)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        state = subprocess.check_output([str(binary), 'probe', str(fixture.pid)], text=True, timeout=3).split()
                        if state[3] == '4':
                            break
                        time.sleep(.05)
                    else:
                        raise RuntimeError('fixture did not enter stopped state')
                if mode == 'traced':
                    holder = launch_lldb(HERE / 'holder.py', env, log)
                    holder_audit = DebuggerAudit(holder, binary, str(server_path))
                    deadline = time.monotonic() + 15
                    while not ready.exists() and holder.poll() is None and time.monotonic() < deadline:
                        time.sleep(.1)
                    if not ready.exists() or ready.read_text() != 'attached':
                        raise RuntimeError('separate debugger failed to attach; traced case not exercised')
                collector = launch_lldb(HERE / 'collector.py', env, log)
                collector_audit = DebuggerAudit(collector, binary, str(server_path))
                if mode == 'cancel':
                    marker = Path(env['MAC_CU_EXPRESSION_READY'])
                    deadline = time.monotonic() + 20
                    while not marker.exists() and collector.poll() is None and time.monotonic() < deadline:
                        time.sleep(.1)
                    if not marker.exists():
                        raise RuntimeError('cancel case never reached expression')
                    if collector.poll() is None:
                        os.killpg(collector.pid, signal.SIGINT)
                try:
                    collector.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    raise RuntimeError('collector deadline exceeded; cleanup and ownership require review')
                if result.exists():
                    evidence = json.loads(result.read_text())
                    print(mode, json.dumps(evidence, sort_keys=True), flush=True)
                    if mode in ('paused', 'traced') and evidence.get('outcome') != 'preflight rejected':
                        raise RuntimeError('preflight did not reject fixture')
                    if mode not in ('paused', 'traced') and not evidence.get('attached'):
                        raise RuntimeError('collector did not attach')
                else:
                    raise RuntimeError('collector did not write a result')
        except Exception as error:
            failures += 1
            print(mode, 'NOT VERIFIED:', error, file=sys.stderr, flush=True)
        finally:
            if holder and holder.poll() is None:
                release.touch()
                try:
                    holder.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    print(mode, 'holder detach timed out; cleanup requires review', file=sys.stderr)
            if fixture and fixture.poll() is None:
                try:
                    final = subprocess.check_output([str(binary), 'probe', str(fixture.pid)], text=True, timeout=3).strip()
                    print(mode, 'final fixture identity/state:', final, flush=True)
                except Exception as error:
                    print(mode, 'final fixture state unavailable:', error, file=sys.stderr, flush=True)
            stop_owned(collector)
            stop_owned(holder)
            for label, audit in (('collector', collector_audit), ('holder', holder_audit)):
                if audit:
                    clean = audit.finish(out / (mode + '.' + label + '-ownership.json'))
                    expected_server = label == 'holder' or mode not in ('paused', 'traced')
                    if not clean or (expected_server and not audit.servers):
                        failures += 1
                        print(mode, label, 'debugserver ownership/cleanup NOT VERIFIED', file=sys.stderr, flush=True)
            stop_owned(fixture)
    print('Evidence is not a pass: inspect logs, final process state, and owned debugserver cleanup.')
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
