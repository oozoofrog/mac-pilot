"""Owned, already-connected debugserver experiment; evaluated inside LLDB."""
import json
import fcntl
import os
import socket
import subprocess
import threading
import time
import lldb

pid = int(os.environ['MAC_CU_FIXTURE_PID'])
fixture = os.environ['MAC_CU_FIXTURE_PATH']
owner = int(os.environ['MAC_CU_FIXTURE_OWNER'])
expected = os.environ['MAC_CU_FIXTURE_ID']
server_pid = int(os.environ['MAC_CU_SERVER_PID'])
server_id = os.environ['MAC_CU_SERVER_ID']
server_path = os.environ['MAC_CU_SERVER_PATH']
fd = int(os.environ['MAC_CU_SERVER_FD'])
mode = os.environ['MAC_CU_FIXTURE_MODE']
record = {'mode': mode, 'pid': pid, 'connected': False, 'attachRequested': False,
          'attached': False, 'detach': 'not attempted', 'timeline': []}
process = None
cancel_active = None
cancel_thread = None

def trace(phase, action, **details):
    record['timeline'].append({'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns(),
                               'phase': phase, 'action': action, **details})

def probe(kind, target):
    with open(fixture + '.probe.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        parts = subprocess.check_output([fixture, kind, str(target)], text=True, timeout=3).strip().split(maxsplit=6)
    return {'pid': int(parts[0]), 'start': parts[1] + ':' + parts[2], 'state': int(parts[3]),
            'traced': int(parts[4]), 'parent': int(parts[5]), 'path': os.path.realpath(parts[6])}

def verify_server():
    server = probe('inspect', server_pid)
    if server['start'] != server_id or server['parent'] != owner or server['path'] != server_path:
        raise RuntimeError('owned debugserver identity changed')
    return server

def valid_fixture(info):
    return (info['pid'] == pid and info['start'] == expected and info['parent'] == owner
            and info['state'] in (2, 3) and not info['traced'])

def cancel_control(process, active, ready):
    control = record.setdefault('cancelControl', {})
    ready.set()
    deadline = time.monotonic() + 25
    try:
        while active.is_set() and time.monotonic() < deadline:
            try:
                with open(os.environ['MAC_CU_CANCEL_REQUEST']) as marker:
                    request = json.load(marker)
                break
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(.01)
        else:
            control['outcome'] = 'request not observed during expression'
            trace('cancel', 'request-not-observed')
            return
        control['requestObserved'] = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        control['request'] = request
        trace('cancel', 'request-observed')
        server = verify_server()
        target = probe('probe', pid)
        collector = probe('inspect', os.getpid())
        control['server'], control['fixture'], control['collector'] = server, target, collector
        requested_collector, requested_fixture, requested_server = request['collector'], request['fixture'], request['server']
        if (collector['pid'] != requested_collector['pid'] or collector['start'] != requested_collector['start']
                or collector['parent'] != owner or collector['path'] != os.environ['MAC_CU_LLDB_PATH']
                or target['pid'] != pid or target['start'] != expected or target['path'] != requested_fixture['path']
                or target['state'] not in (2, 3) or target['traced'] != 1 or target['parent'] != server_pid
                or server['pid'] != requested_server['pid'] or server['start'] != requested_server['start']):
            raise RuntimeError('cancel ownership or running fixture verification failed')
        if not active.is_set():
            control['outcome'] = 'expression ended before interrupt request'
            trace('cancel', 'expression-already-ended')
            return
        control['callStarted'] = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        trace('cancel', 'async-interrupt-request')
        process.SendAsyncInterrupt()  # Void: a returned call is not proof of cancellation.
        control['callReturned'] = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        control['outcome'] = 'async interrupt call returned'
        trace('cancel', 'async-interrupt-returned')
    except BaseException as error:
        control['outcome'] = 'control failed'
        control['error'] = repr(error)
        trace('cancel', 'control-error', error=control['error'])

def wait_for_state(process, listener, wanted, phase):
    deadline = time.monotonic() + 15
    trace(phase, 'wait-start', wanted=int(wanted), timeoutSeconds=15)
    states = record.setdefault(phase + 'States', [])
    while time.monotonic() < deadline:
        state = process.GetState()
        states.append({'source': 'process', 'state': int(state)})
        trace(phase, 'current-state', state=int(state))
        if state == wanted:
            trace(phase, 'wait-success', state=int(state))
            return
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
            raise RuntimeError(phase + ' ended in state ' + str(state))
        event = lldb.SBEvent()
        if listener.WaitForEvent(1, event):
            if not lldb.SBProcess.EventIsProcessEvent(event):
                states.append({'source': 'event', 'processEvent': False})
                trace(phase, 'event', processEvent=False)
                continue
            state = lldb.SBProcess.GetStateFromEvent(event)
            states.append({'source': 'event', 'state': int(state)})
            trace(phase, 'event', state=int(state))
            if state == wanted:
                trace(phase, 'wait-success', state=int(state))
                return
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
                raise RuntimeError(phase + ' event ended in state ' + str(state))
    trace(phase, 'wait-timeout', wanted=int(wanted))
    raise TimeoutError(phase + ' did not reach state ' + str(wanted) + ' within 15 seconds')

try:
    record['serverBeforeConnect'] = verify_server()
    before = probe('probe', pid)
    record['before'] = before
    if not valid_fixture(before):
        record['outcome'] = 'preflight rejected'
    else:
        sock = socket.socket(fileno=fd)
        if sock.family != socket.AF_UNIX or sock.type & socket.SOCK_STREAM != socket.SOCK_STREAM:
            raise RuntimeError('unexpected inherited transport')
        sock.detach()  # LLDB's fd:// does not take ownership.
        lldb.debugger.SetAsync(False)
        target = lldb.debugger.CreateTarget('')
        listener = lldb.SBListener('mac-cu fixture collector')
        error = lldb.SBError()
        trace('connect', 'request')
        process = target.ConnectRemote(listener, 'fd://' + str(fd), 'gdb-remote', error)
        record['connectResult'] = {'error': str(error), 'valid': bool(process.IsValid()),
                                   'rawState': int(process.GetState()) if process.IsValid() else None}
        trace('connect', 'result', **record['connectResult'])
        if error.Fail() or not process.IsValid():
            raise RuntimeError('remote connect failed: ' + str(error))
        wait_for_state(process, listener, lldb.eStateConnected, 'connect')
        record['connected'] = True
        record['serverBeforeAttach'] = verify_server()
        before_attach = probe('probe', pid)
        record['beforeAttach'] = before_attach
        if mode == 'connect':
            record['outcome'] = 'connected without attach'
            trace('attach', 'not-requested')
        elif not valid_fixture(before_attach):
            record['outcome'] = 'preflight rejected before attach'
        else:
            trace('attach', 'request', pid=pid)
            record['attachRequested'] = True
            attached = process.RemoteAttachToProcessWithID(pid, error)
            record['attachResult'] = {'started': bool(attached), 'error': str(error),
                                      'rawState': int(process.GetState())}
            trace('attach', 'result', **record['attachResult'])
            if not attached or error.Fail():
                raise RuntimeError('remote attach failed: ' + str(error))
            record['attached'] = True
            wait_for_state(process, listener, lldb.eStateStopped, 'attach')
            record['pidAfterStop'] = int(process.GetProcessID())
            if record['pidAfterStop'] != pid:
                raise RuntimeError('debugger attached to a different PID')
            current = probe('probe', pid)
            record['afterAttach'] = current
            if current['start'] != expected or current['pid'] != pid:
                raise RuntimeError('fixture identity changed after attach')
            with open(os.environ['MAC_CU_EXPRESSION_READY'], 'w') as marker:
                marker.write('about to evaluate')
            options = lldb.SBExpressionOptions()
            options.SetLanguage(lldb.eLanguageTypeC)
            options.SetTimeoutInMicroSeconds(500000 if mode == 'timeout' else 30000000)
            options.SetUnwindOnError(True)
            expressions = {'success': '1 + 1', 'error': 'mac_cu_missing_symbol',
                           'timeout': '(int)fixture_spin()', 'cancel': '(int)fixture_spin()',
                           'exit': '(void)exit(0)'}
            trace('expression', 'request', timeoutSeconds=.5 if mode == 'timeout' else 30)
            if mode == 'cancel':
                cancel_active = threading.Event()
                cancel_active.set()
                ready = threading.Event()
                cancel_thread = threading.Thread(target=cancel_control, args=(process, cancel_active, ready), daemon=True)
                cancel_thread.start()
                if not ready.wait(2):
                    raise RuntimeError('cancel control thread did not start')
            expression_started = time.monotonic_ns()
            try:
                value = process.GetSelectedThread().GetFrameAtIndex(0).EvaluateExpression(expressions[mode], options)
            finally:
                record['expressionCompletedMonotonicNs'] = time.monotonic_ns()
                if cancel_active:
                    cancel_active.clear()
            record['expressionElapsedNs'] = record['expressionCompletedMonotonicNs'] - expression_started
            expression_error = value.GetError()
            record['expressionError'] = str(expression_error)
            record['expressionErrorCode'] = int(expression_error.GetError())
            record['expressionErrorType'] = int(expression_error.GetType())
            record['expressionSucceeded'] = expression_error.Success()
            record['expressionValue'] = value.GetValue()
            trace('expression', 'result', success=record['expressionSucceeded'], error=record['expressionError'],
                  errorCode=record['expressionErrorCode'], errorType=record['expressionErrorType'],
                  elapsedNs=record['expressionElapsedNs'], rawState=int(process.GetState()))
            record['outcome'] = 'expression returned'
except BaseException as error:
    record['outcome'] = 'interrupted or failed'
    record['error'] = repr(error)
    trace('operation', 'error', error=record['error'])
finally:
    if cancel_active:
        cancel_active.clear()
    if cancel_thread:
        cancel_thread.join(timeout=2)
        record['cancelControlThreadAlive'] = cancel_thread.is_alive()
    if cancel_thread and cancel_thread.is_alive():
        record['detach'] = 'not attempted: cancel control thread still active'
        trace('detach', 'not-requested-control-active')
    elif record['attached'] and process and process.IsValid():
        try:
            record['beforeDetachState'] = int(process.GetState())
            trace('detach', 'state', rawState=record['beforeDetachState'])
            if record['beforeDetachState'] not in (lldb.eStateExited, lldb.eStateDetached):
                trace('detach', 'request')
                detached = process.Detach(False)
                record['detach'] = 'success' if detached.Success() else str(detached)
                trace('detach', 'result', result=record['detach'], rawState=int(process.GetState()))
            else:
                record['detach'] = 'already exited or detached'
                trace('exit', 'observed', rawState=record['beforeDetachState'])
        except BaseException as error:
            record['detach'] = repr(error)
            trace('detach', 'error', error=record['detach'])
    else:
        trace('detach', 'not-requested')
    try:
        trace('exit', 'fixture-observation-request')
        record['after'] = probe('probe', pid)
        trace('exit', 'fixture-observation', **record['after'])
    except Exception as error:
        record['after'] = {'unavailable': str(error)}
        trace('exit', 'fixture-unavailable', error=str(error))
    with open(os.environ['MAC_CU_FIXTURE_RESULT'], 'w') as result:
        json.dump(record, result, indent=2)
