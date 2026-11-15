"""Serial owned-debugserver experiment. Never accepts an external target PID."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import signal
import socket
import subprocess
import sys
import time
from remote_watchdog import process_status

HERE = Path(__file__).resolve().parent
SERVERS = {}

def interrupt_worker(cleanup_state, signum):
    if not cleanup_state['active']:
        cleanup_state['active'] = True
        raise KeyboardInterrupt('runner interrupted by signal ' + str(signum))

def identity(binary, kind, pid):
    with open(str(binary) + '.probe.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        parts = subprocess.check_output([str(binary), kind, str(pid)], text=True, timeout=3).strip().split(maxsplit=6)
    return {'pid': int(parts[0]), 'start': parts[1] + ':' + parts[2], 'state': int(parts[3]),
            'traced': int(parts[4]), 'parent': int(parts[5]), 'path': os.path.realpath(parts[6])}

def wait_file(path, child, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and child.poll() is None:
        if path.exists():
            return
        time.sleep(.05)
    raise RuntimeError('missing marker: ' + str(path))

def wait_spin_marker(path, child, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and child.poll() is None:
        if path.exists() and path.read_text() == 'spinning\n':
            return
        time.sleep(.05)
    raise RuntimeError('fixture spin entry was not observed')

def request_cancel(collector, binary, developer, evidence, request_path, fixture_info, server_info):
    evidence['cancelRequest'] = {'markerConfirmed': {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}}
    recipient = identity(binary, 'inspect', collector.pid)
    if recipient['parent'] != os.getpid() or recipient['path'] != str((developer / 'usr/bin/lldb').resolve()):
        raise RuntimeError('collector request recipient identity not confirmed')
    if collector.poll() is not None:
        raise RuntimeError('collector exited before cancellation request')
    evidence['cancelRequest']['recipient'] = recipient
    request = {'collector': recipient, 'fixture': fixture_info, 'server': server_info,
               'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
    evidence['cancelRequest']['request'] = {'monotonicNs': request['monotonicNs'], 'unixNs': request['unixNs']}
    try:
        fd = os.open(request_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as marker:
            json.dump(request, marker)
    except Exception as error:
        evidence['cancelRequest']['result'] = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns(), 'error': repr(error)}
        raise
    evidence['cancelRequest']['result'] = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns(),
                                           'markerWritten': True, 'postWritePoll': collector.poll()}

def stop_child(child, label, stopped_fixture=False):
    if child is None:
        return {'status': 'not started'}
    if child.poll() is None:
        if stopped_fixture:
            child.kill()  # A deliberately SIGSTOPped disposable child cannot handle SIGTERM.
            child.wait(timeout=5)
            return {'status': 'disposed stopped fixture', 'returncode': child.returncode, 'label': label}
        child.terminate()  # Every child here was started by this runner.
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
            return {'status': 'forced', 'returncode': child.returncode, 'label': label}
    return {'status': 'exited', 'returncode': child.returncode, 'label': label}

def cleanup_children(children, mode):
    results = {}
    for name, child in children:
        try:
            results[name] = stop_child(child, name, stopped_fixture=(name == 'fixtureCleanup' and mode == 'paused'))
        except Exception as error:
            results[name] = {'status': 'error', 'label': name, 'error': repr(error)}
    return results

def fixture_terminal(fixture_pid, baseline):
    try:
        status = process_status(fixture_pid)
    except Exception:
        try:
            os.kill(fixture_pid, 0)
        except ProcessLookupError:
            return True
        raise
    if ':'.join(map(str, status['start'])) != baseline['start']:
        raise RuntimeError('fixture PID was reused')
    return status['state'] == 5

def observe_fixture(binary, fixture_pid, baseline):
    if not baseline:
        raise RuntimeError('fixture baseline identity unavailable')
    try:
        current = identity(binary, 'probe', fixture_pid)
    except Exception:
        if fixture_terminal(fixture_pid, baseline):
            return None
        raise
    if any(current.get(key) != baseline.get(key) for key in ('pid', 'start', 'path')):
        raise RuntimeError('fixture PID/start/path no longer matches baseline')
    return current

def wait_for_fixture_resume(binary, fixture_pid, baseline, observations, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            current = observe_fixture(binary, fixture_pid, baseline)
        except Exception as error:
            observations.append({'monotonicNs': time.monotonic_ns(), 'error': repr(error)})
            raise
        observations.append({'monotonicNs': time.monotonic_ns(), 'fixture': current})
        if current is None:
            raise RuntimeError('fixture exited before holder recovery')
        if (any(current.get(key) != baseline.get(key) for key in ('pid', 'start', 'path', 'parent'))
                or current.get('state') not in (2, 3, 4) or current.get('traced') not in (0, 1)):
            raise RuntimeError('fixture identity, parent or state changed during holder recovery')
        if current['state'] in (2, 3) and current['traced'] == 0:
            return current
        time.sleep(.05)
    raise TimeoutError('fixture running/untraced state not confirmed after holder detach')

def finalize_case_evidence(evidence, failures):
    if failures:
        evidence['preFinalizationCase'] = evidence.get('case', 'not completed')
        evidence['case'] = 'failed'
    elif 'case' not in evidence:
        evidence['case'] = 'interrupted'
    evidence['failureCount'] = failures

def cleanup_fixture(binary, fixture, baseline, *, stopped_fixture=False, details=None):
    details = details if details is not None else {}
    details['baseline'] = baseline
    if fixture is None:
        return {'status': 'not started'}
    current = observe_fixture(binary, fixture.pid, baseline)
    if current is None:
        return {'status': 'exited', 'exitStatus': 'not inferred from Popen'}
    if current['parent'] != baseline['parent'] or current['traced'] != 0:
        raise RuntimeError('fixture ownership or debugger state is not restored')
    if stopped_fixture and current['state'] != 4:
        raise RuntimeError('stopped fixture state changed before cleanup')
    chosen = signal.SIGKILL if stopped_fixture else signal.SIGTERM
    details['identityBeforeSignal'] = current
    details['signalRequest'] = {'signal': signal.Signals(chosen).name, 'monotonicNs': time.monotonic_ns(),
                                'unixNs': time.time_ns()}
    try:
        os.kill(fixture.pid, chosen)
        details['signalResult'] = {'returned': True, 'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
    except ProcessLookupError:
        details['signalResult'] = {'error': 'ESRCH', 'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        if fixture_terminal(fixture.pid, baseline):
            return {**details, 'status': 'exited', 'terminalConfirmation': 'kill ESRCH and OS disappearance',
                    'exitStatus': 'not inferred from Popen'}
        raise
    except OSError as error:
        details['signalResult'] = {'error': repr(error), 'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        raise
    deadline = time.monotonic() + 5
    details['observations'] = []
    waitpid_available = True
    while time.monotonic() < deadline:
        if waitpid_available:
            try:
                waited_pid, status = os.waitpid(fixture.pid, os.WNOHANG)
                if waited_pid == fixture.pid:
                    observation = {'kind': 'waitpid', 'rawStatus': status, 'monotonicNs': time.monotonic_ns()}
                    if os.WIFEXITED(status):
                        observation.update(terminal='exited', exitCode=os.WEXITSTATUS(status))
                    elif os.WIFSIGNALED(status):
                        observation.update(terminal='signaled', signal=os.WTERMSIG(status))
                    else:
                        observation.update(terminal=None, stopped=bool(os.WIFSTOPPED(status)))
                    details['observations'].append(observation)
                    if observation['terminal']:
                        return {**details, 'status': 'disposed stopped fixture' if stopped_fixture else 'exited',
                                'signal': signal.Signals(chosen).name, 'terminalConfirmation': observation,
                                'exitStatus': 'verified waitpid status'}
                elif waited_pid != 0:
                    raise RuntimeError('waitpid returned an unexpected PID')
            except ChildProcessError as error:
                if error.errno != errno.ECHILD:
                    raise
                waitpid_available = False
                details['observations'].append({'kind': 'waitpid', 'error': 'ECHILD; not exit evidence',
                                                'monotonicNs': time.monotonic_ns()})
        try:
            status = process_status(fixture.pid)
        except Exception as error:
            try:
                os.kill(fixture.pid, 0)
            except ProcessLookupError:
                confirmation = {'kind': 'kill0', 'result': 'ESRCH', 'monotonicNs': time.monotonic_ns()}
                details['observations'].append(confirmation)
                return {**details, 'status': 'disposed stopped fixture' if stopped_fixture else 'exited',
                        'signal': signal.Signals(chosen).name, 'terminalConfirmation': confirmation,
                        'exitStatus': 'not inferred from Popen'}
            details['observations'].append({'kind': 'status-unavailable', 'error': repr(error),
                                            'kill0': 'exists; retrying', 'monotonicNs': time.monotonic_ns()})
            time.sleep(.05)
            continue
        if ':'.join(map(str, status['start'])) != baseline['start']:
            raise RuntimeError('fixture PID was reused during cleanup')
        if status['state'] == 5:
            confirmation = {'kind': 'same-start-zombie', 'start': status['start'], 'monotonicNs': time.monotonic_ns()}
            details['observations'].append(confirmation)
            if waitpid_available:
                time.sleep(.05)
                continue  # Try to reap the specific child on the next waitpid call.
            return {**details, 'status': 'disposed stopped fixture' if stopped_fixture else 'exited',
                    'signal': signal.Signals(chosen).name, 'terminalConfirmation': confirmation,
                    'exitStatus': 'not inferred from Popen'}
        time.sleep(.05)
    raise TimeoutError('fixture termination was not confirmed after signal')

def start_server(binary, server_path, env, log, role):
    if role not in ('collector', 'holder') or any(p.poll() is None for p in SERVERS.get(role, [])):
        raise RuntimeError('debugserver role instance budget exceeded')
    if sum(p.poll() is None for group in SERVERS.values() for p in group) >= 2:
        raise RuntimeError('debugserver total instance budget exceeded')
    left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    server = None
    try:
        # Direct child, not LLDB's implicit server or a process found by name.
        server = subprocess.Popen([str(server_path), '--fd', str(right.fileno())], pass_fds=(right.fileno(),),
                                  env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        SERVERS.setdefault(role, []).append(server)
        right.close()
        info = identity(binary, 'inspect', server.pid)
        if (server.poll() is not None or info['parent'] != os.getpid()
                or info['path'] != str(server_path)):
            raise RuntimeError('debugserver identity/parent verification failed')
        return server, left, info
    except BaseException:
        left.close()
        right.close()
        stop_child(server, 'unverified direct server child')
        raise

def start_lldb(script, env, fd, log, engine_log=False):
    command = 'script exec(compile(open(' + repr(str(script)) + ').read(), ' + repr(str(script)) + ', "exec"))'
    arguments = ['/usr/bin/xcrun', 'lldb', '--no-lldbinit', '--batch']
    if engine_log:
        arguments += ['-o', 'log enable lldb expr process step']
    arguments += ['-o', command]
    return subprocess.Popen(arguments,
                            env=env, pass_fds=(fd,), stdin=subprocess.DEVNULL, stdout=log,
                            stderr=subprocess.STDOUT)

def confirmed_fixture_timeout(result, final, spin_entered, engine_log):
    lines = [line.strip() for line in engine_log.splitlines()]
    first = 'Running function with one thread timeout timed out.'
    second = re.compile(r'Restarting function with all threads enabled and timeout: [0-9]+ us timed out, abandoning execution\.')
    third = 'Process::RunThreadPlan(): running all threads timed out.'
    parse = '== [UserExpression::Evaluate] Parsing expression (int)fixture_spin() =='
    execute = '== [UserExpression::Evaluate] Executing expression =='
    markers = [i for i, line in enumerate(lines) if line == first and parse in lines[:i] and execute in lines[:i]]
    sequence = any(any(second.fullmatch(line) and third in lines[j + 1:]
                       for j, line in enumerate(lines[i + 1:], start=i + 1)) for i in markers)
    before = result.get('before', {})
    after = result.get('after', {})
    identity_keys = ('pid', 'start', 'parent', 'path')
    return (spin_entered is True and result.get('connected') is True and result.get('attached') is True
            and result.get('expressionSucceeded') is False
            and isinstance(result.get('expressionElapsedNs'), int) and result['expressionElapsedNs'] >= 500_000_000
            and isinstance(result.get('expressionErrorCode'), int) and result['expressionErrorCode'] != 0
            and isinstance(result.get('expressionErrorType'), int) and result['expressionErrorType'] != 0
            and result.get('detach') == 'success' and all(key in before for key in identity_keys)
            and all(final.get(key) == before[key] and after.get(key) == before[key] for key in identity_keys)
            and final.get('state') in (2, 3) and final.get('traced') == 0
            and after.get('state') in (2, 3) and after.get('traced') == 0 and sequence)

def confirmed_fixture_cancel(result, final, spin_entered, engine_log, request_evidence):
    control = result.get('cancelControl', {})
    req = control.get('request', {})
    observed = control.get('requestObserved', {})
    returned = control.get('callReturned', {})
    collector = control.get('collector', {})
    fixture = control.get('fixture', {})
    server = control.get('server', {})
    before = result.get('before', {})
    after = result.get('after', {})
    keys = ('pid', 'start', 'parent', 'path')
    observed_ns, requested_ns = observed.get('unixNs'), req.get('unixNs')
    return_ns, completed_ns = returned.get('monotonicNs'), result.get('expressionCompletedMonotonicNs')
    call_ns = control.get('callStarted', {}).get('monotonicNs')
    observed_mono = observed.get('monotonicNs')
    log_lines = engine_log.splitlines()
    markers = iter(('== [UserExpression::Evaluate] Parsing expression (int)fixture_spin() ==',
                    '== [UserExpression::Evaluate] Executing expression ==',
                    'woke up with an interrupt - Halting.',
                    'stopped due to an interrupt, state: stopped',
                    'The event is an Interrupt, returning true.',
                    'Process::RunThreadPlan(): execution interrupted:',
                    'Process::RunThreadPlan: ExecutionInterrupted - discarding thread plans'))
    wanted = next(markers, None)
    for line in log_lines:
        if wanted is not None and wanted in line:
            wanted = next(markers, None)
    interrupt_log = wanted is None
    return (spin_entered is True and request_evidence.get('result', {}).get('markerWritten') is True
            and control.get('outcome') == 'async interrupt call returned' and result.get('cancelControlThreadAlive') is False
            and result.get('connected') is True and result.get('attached') is True and result.get('expressionSucceeded') is False
            and requested_ns == request_evidence.get('request', {}).get('unixNs')
            and isinstance(observed_ns, int) and isinstance(requested_ns, int) and 0 <= observed_ns - requested_ns < 5_000_000_000
            and isinstance(observed_mono, int) and isinstance(call_ns, int) and isinstance(return_ns, int)
            and 0 <= call_ns - observed_mono < 5_000_000_000 and 0 <= return_ns - call_ns < 5_000_000_000
            and isinstance(return_ns, int) and isinstance(completed_ns, int) and 0 <= completed_ns - return_ns < 5_000_000_000
            and isinstance(result.get('expressionElapsedNs'), int) and result['expressionElapsedNs'] < 30_000_000_000
            and all(key in before for key in keys) and all(after.get(key) == before[key] and final.get(key) == before[key] for key in keys)
            and all(fixture.get(key) == before.get(key) for key in ('pid', 'start', 'path'))
            and all(collector.get(key) == req.get('collector', {}).get(key) for key in keys)
            and all(collector.get(key) == request_evidence.get('recipient', {}).get(key) for key in keys)
            and all(server.get(key) == result.get('serverBeforeAttach', {}).get(key) for key in ('pid', 'start', 'path'))
            and fixture.get('state') in (2, 3) and fixture.get('traced') == 1 and fixture.get('parent') == server.get('pid')
            and result.get('detach') == 'success' and after.get('state') in (2, 3) and after.get('traced') == 0
            and final.get('state') in (2, 3) and final.get('traced') == 0 and interrupt_log
            and not any('running all threads timed out' in line or 'timed out, abandoning execution' in line
                        or 'one thread timeout timed out' in line for line in log_lines))

def check_result(mode, result, final, *, spin_entered=False, engine_log='', cancel_request=None,
                 fixture_baseline=None, holder_server_pid=None):
    if mode == 'connect':
        before = result.get('before', {})
        after = result.get('after', {})
        if (result.get('connected') is not True or result.get('attached') is not False
                or result.get('attachRequested') is not False or result.get('outcome') != 'connected without attach'
                or any(final.get(key) != before.get(key) or after.get(key) != before.get(key)
                       for key in ('pid', 'start', 'parent', 'path'))
                or final.get('state') not in (2, 3) or final.get('traced') != 0
                or after.get('state') not in (2, 3) or after.get('traced') != 0):
            raise RuntimeError('connection-only result or unchanged fixture not confirmed')
        return
    if mode in ('paused', 'traced'):
        if (result.get('outcome') not in ('preflight rejected', 'preflight rejected before attach')
                or result.get('attachRequested') is not False or result.get('attached') is not False):
            raise RuntimeError('pre-existing stop/debugger was not refused')
        if mode == 'paused':
            if final.get('state') != 4:
                raise RuntimeError('stopped fixture did not remain stopped')
            return
        expected_parent = holder_server_pid
        for observed in (result.get('before', {}), result.get('after', {}), final):
            if (not fixture_baseline or any(observed.get(key) != fixture_baseline.get(key) for key in ('pid', 'start', 'path'))
                    or expected_parent is None or observed.get('parent') != expected_parent
                    or observed.get('state') != 4 or observed.get('traced') != 1):
                raise RuntimeError('pre-existing fixture stop/debugger ownership changed')
        return
    if not result.get('connected') or not result.get('attached'):
        raise RuntimeError('separate connect/attach not confirmed')
    if mode == 'exit':
        if 'unavailable' not in result.get('after', {}) or 'exited' not in final:
            raise RuntimeError('fixture exit was not observed')
        return
    if result.get('detach') != 'success' or final.get('state') not in (2, 3) or final.get('traced'):
        raise RuntimeError('detach and running state not confirmed')
    if mode == 'success' and (result.get('expressionSucceeded') is not True or result.get('expressionValue') != '2'):
        raise RuntimeError('success expression failed')
    if mode in ('error', 'timeout') and result.get('expressionSucceeded') is not False:
        raise RuntimeError('expected expression failure absent')
    if mode == 'timeout' and not confirmed_fixture_timeout(result, final, spin_entered, engine_log):
        raise RuntimeError('fixture timeout evidence or recovery was not confirmed')
    if mode == 'cancel' and not confirmed_fixture_cancel(result, final, spin_entered, engine_log, cancel_request or {}):
        raise RuntimeError('fixture cancellation evidence or recovery was not confirmed')

def main():
    if (os.environ.get('MAC_CU_REMOTE_WATCHDOG_PID') != str(os.getppid())
            or os.getpgrp() != os.getpid()):
        raise RuntimeError('run only through the parent watchdog')
    cleanup_state = {'active': False}
    def interrupted(signum, frame):
        interrupt_worker(cleanup_state, signum)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True, help='New unique output directory')
    parser.add_argument('--case', required=True, choices=('connect', 'success', 'error', 'timeout', 'cancel', 'exit', 'paused', 'traced'))
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    (out / 'source-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(HERE.iterdir()) if p.suffix in ('.c', '.py')}, indent=2))
    developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True, timeout=5).strip()).resolve()
    server_path = (developer.parent / 'SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver').resolve()
    if not server_path.is_file():
        raise RuntimeError('exact Xcode debugserver not found')
    binary = out / 'owned-fixture'
    subprocess.run(['/usr/bin/clang', '-g', '-O0', str(HERE / 'fixture.c'), '-o', str(binary)], check=True, timeout=30)
    entitlements = out / 'fixture-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(binary)], check=True, timeout=30)
    failures = 0
    for mode in (args.case,):
        (out / 'current-case').write_text(mode)
        fixture = collector = server = holder = holder_server = None
        transport = holder_transport = None
        final = {}
        before = None
        result_path = out / (mode + '.json')
        evidence = {'mode': mode}
        cleanup_incomplete = False
        try:
            with (out / (mode + '.log')).open('w') as log:
                spin_marker = out / (mode + '.fixture-spinning')
                fixture_env = dict(os.environ, MAC_CU_FIXTURE_SPIN_MARKER=str(spin_marker))
                fixture = subprocess.Popen([str(binary), 'fixture'], stdout=subprocess.PIPE, stderr=log,
                                           text=True, env=fixture_env)
                if not select.select([fixture.stdout], [], [], 5)[0] or fixture.stdout.readline().strip() != 'ready':
                    raise RuntimeError('fixture startup failed')
                before = identity(binary, 'probe', fixture.pid)
                if before['parent'] != os.getpid() or before['state'] not in (2, 3) or before['traced']:
                    raise RuntimeError('fixture identity/state invalid')
                evidence['fixtureBefore'] = before
                env = dict(os.environ, MAC_CU_FIXTURE_PID=str(fixture.pid), MAC_CU_FIXTURE_ID=before['start'],
                           MAC_CU_FIXTURE_OWNER=str(os.getpid()), MAC_CU_FIXTURE_PATH=str(binary),
                           MAC_CU_FIXTURE_RESULT=str(result_path), MAC_CU_FIXTURE_MODE=mode,
                           MAC_CU_EXPRESSION_READY=str(out / (mode + '.expression-ready')),
                           MAC_CU_HOLDER_READY=str(out / (mode + '.holder-ready')),
                           MAC_CU_HOLDER_RELEASE=str(out / (mode + '.holder-release')),
                           MAC_CU_HOLDER_DETACH=str(out / (mode + '.holder-detach')),
                           MAC_CU_CANCEL_REQUEST=str(out / (mode + '.cancel-request')),
                           MAC_CU_LLDB_PATH=str((developer / 'usr/bin/lldb').resolve()))
                env.pop('LLDB_DEBUGSERVER_PATH', None)
                for key in [key for key in env if key.startswith('DYLD_')]:
                    env.pop(key)
                if mode == 'paused':
                    os.kill(fixture.pid, signal.SIGSTOP)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline and identity(binary, 'probe', fixture.pid)['state'] != 4:
                        time.sleep(.05)
                    if identity(binary, 'probe', fixture.pid)['state'] != 4:
                        raise RuntimeError('fixture did not stop')
                if mode == 'traced':
                    holder_server, holder_transport, holder_info = start_server(binary, server_path, env, log, 'holder')
                    evidence['holderServer'] = holder_info
                    holder_env = dict(env, MAC_CU_SERVER_PID=str(holder_server.pid), MAC_CU_SERVER_ID=holder_info['start'],
                                      MAC_CU_SERVER_PATH=str(server_path), MAC_CU_SERVER_FD=str(holder_transport.fileno()))
                    holder = start_lldb(HERE / 'remote_holder.py', holder_env, holder_transport.fileno(), log)
                    holder_transport.close()
                    holder_transport = None
                    wait_file(Path(env['MAC_CU_HOLDER_READY']), holder, 20)
                    if not identity(binary, 'probe', fixture.pid)['traced']:
                        raise RuntimeError('holder did not establish traced state')
                server, transport, server_info = start_server(binary, server_path, env, log, 'collector')
                evidence['serverBefore'] = server_info
                collector_env = dict(env, MAC_CU_SERVER_PID=str(server.pid), MAC_CU_SERVER_ID=server_info['start'],
                                     MAC_CU_SERVER_PATH=str(server_path), MAC_CU_SERVER_FD=str(transport.fileno()))
                engine_log_requested = mode in ('timeout', 'cancel')
                evidence['engineLog'] = {'requested': engine_log_requested, 'path': str(out / (mode + '.log')) if engine_log_requested else None,
                                         'channels': ['expr', 'process', 'step'] if engine_log_requested else []}
                collector = start_lldb(HERE / 'remote_collector.py', collector_env, transport.fileno(), log,
                                       engine_log=engine_log_requested)
                transport.close()
                transport = None
                if mode == 'cancel':
                    wait_spin_marker(spin_marker, collector, 20)
                    request_cancel(collector, binary, developer, evidence, env['MAC_CU_CANCEL_REQUEST'], before, server_info)
                collector.wait(timeout=40)
                if mode in ('timeout', 'cancel'):
                    evidence['fixtureSpinEntered'] = spin_marker.exists() and spin_marker.read_text() == 'spinning\n'
                    if not evidence['fixtureSpinEntered']:
                        raise RuntimeError('fixture spin entry was not observed')
                if not result_path.exists():
                    raise RuntimeError('collector result missing')
                result = json.loads(result_path.read_text())
                evidence['collector'] = result
                final = observe_fixture(binary, fixture.pid, before)
                if final is None:
                    final = {'exited': 'OS confirmed gone or zombie; Popen status not used'}
                evidence['fixtureAfter'] = final
                engine_log = (out / (mode + '.log')).read_text(errors='replace') if engine_log_requested else ''
                check_result(mode, result, final, spin_entered=evidence.get('fixtureSpinEntered', False), engine_log=engine_log,
                             cancel_request=evidence.get('cancelRequest'), fixture_baseline=before,
                             holder_server_pid=holder_server.pid if holder_server else None)
                evidence['case'] = 'checks passed; see limitations'
        except Exception as error:
            failures += 1
            evidence['case'] = 'failed'
            evidence['error'] = str(error)
        finally:
            cleanup_state['active'] = True
            try:
                if holder and holder.poll() is None:
                    Path(env['MAC_CU_HOLDER_RELEASE']).touch()
                    holder.wait(timeout=8)
            except Exception as error:
                evidence['holderReleaseError'] = repr(error)
                failures += 1
            try:
                if mode == 'traced':
                    marker = out / (mode + '.holder-detach')
                    evidence['holderDetach'] = marker.read_text() if marker.exists() else 'missing'
                    if evidence['holderDetach'] != 'success':
                        raise RuntimeError('holder detach not confirmed')
                    observations = evidence.setdefault('holderRecoveryObservations', [])
                    evidence['fixtureAfterHolderDetach'] = wait_for_fixture_resume(binary, fixture.pid, before, observations)
            except Exception as error:
                evidence['holderVerificationError'] = repr(error)
                failures += 1
            cleanups = cleanup_children((('collectorCleanup', collector), ('serverCleanup', server),
                                         ('holderCleanup', holder), ('holderServerCleanup', holder_server)), mode)
            fixture_cleanup_details = {}
            try:
                cleanups['fixtureCleanup'] = cleanup_fixture(binary, fixture, before, stopped_fixture=(mode == 'paused'),
                                                            details=fixture_cleanup_details)
            except Exception as error:
                cleanups['fixtureCleanup'] = {**fixture_cleanup_details, 'status': 'error', 'error': repr(error)}
            for name, cleanup in cleanups.items():
                evidence[name] = cleanup
                if cleanup['status'] in ('forced', 'error'):
                    failures += 1
                    cleanup_incomplete = True
                    evidence['case'] = 'failed: cleanup incomplete'
            for label, endpoint in (('transport', transport), ('holderTransport', holder_transport)):
                if endpoint:
                    try:
                        endpoint.close()
                    except OSError as error:
                        evidence[label + 'CloseError'] = repr(error)
                        failures += 1
            finalize_case_evidence(evidence, failures)
            (out / (mode + '.evidence.json')).write_text(json.dumps(evidence, indent=2))
            print(mode, evidence.get('case', 'interrupted'), flush=True)
        if cleanup_incomplete:
            break
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
