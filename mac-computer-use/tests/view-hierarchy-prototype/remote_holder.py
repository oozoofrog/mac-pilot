"""Hold a separate debugger on the runner's fixture until explicitly released."""
import os
import fcntl
import subprocess
import time
import lldb

fixture = os.environ['MAC_CU_FIXTURE_PATH']
pid = int(os.environ['MAC_CU_FIXTURE_PID'])
owner = int(os.environ['MAC_CU_FIXTURE_OWNER'])
def inspect(kind, target):
    with open(fixture + '.probe.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return subprocess.check_output([fixture, kind, str(target)], text=True, timeout=3).strip().split(maxsplit=6)
def verify():
    server = inspect('inspect', os.environ['MAC_CU_SERVER_PID'])
    target = inspect('probe', pid)
    if (server[1] + ':' + server[2] != os.environ['MAC_CU_SERVER_ID'] or int(server[5]) != owner
            or os.path.realpath(server[6]) != os.environ['MAC_CU_SERVER_PATH']
            or target[1] + ':' + target[2] != os.environ['MAC_CU_FIXTURE_ID']
            or int(target[5]) != owner or int(target[3]) not in (2, 3) or int(target[4])):
        raise RuntimeError('fixture or server preflight failed')

process = None
attached = False
states = []
def trace(phase, action, **details):
    states.append({'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns(),
                   'phase': phase, 'action': action, **details})
def wait_for_state(process, listener, wanted, phase):
    deadline = time.monotonic() + 15
    trace(phase, 'wait-start', wanted=int(wanted), timeoutSeconds=15)
    while time.monotonic() < deadline:
        state = process.GetState()
        trace(phase, 'current-state', state=int(state))
        if state == wanted:
            trace(phase, 'wait-success', state=int(state))
            return
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
            raise RuntimeError(phase + ' ended in state ' + str(state))
        event = lldb.SBEvent()
        if listener.WaitForEvent(1, event):
            if not lldb.SBProcess.EventIsProcessEvent(event):
                trace(phase, 'event', processEvent=False)
                continue
            state = lldb.SBProcess.GetStateFromEvent(event)
            trace(phase, 'event', state=int(state))
            if state == wanted:
                trace(phase, 'wait-success', state=int(state))
                return
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
                raise RuntimeError(phase + ' event ended in state ' + str(state))
    trace(phase, 'wait-timeout', wanted=int(wanted))
    raise TimeoutError(phase + ' did not reach state ' + str(wanted) + ' within 15 seconds')
try:
    verify()
    lldb.debugger.SetAsync(False)
    target = lldb.debugger.CreateTarget('')
    listener = lldb.SBListener('mac-cu fixture holder')
    error = lldb.SBError()
    trace('connect', 'request')
    process = target.ConnectRemote(listener, 'fd://' + os.environ['MAC_CU_SERVER_FD'], 'gdb-remote', error)
    trace('connect', 'result', valid=bool(process.IsValid()), error=str(error),
          rawState=int(process.GetState()) if process.IsValid() else None)
    if error.Fail() or not process.IsValid():
        raise RuntimeError('holder connect failed: ' + str(error))
    wait_for_state(process, listener, lldb.eStateConnected, 'connect')
    verify()
    trace('attach', 'request', pid=pid)
    attached = process.RemoteAttachToProcessWithID(pid, error)
    trace('attach', 'result', started=bool(attached), error=str(error), rawState=int(process.GetState()))
    if not attached or error.Fail():
        raise RuntimeError('holder attach failed: ' + str(error))
    wait_for_state(process, listener, lldb.eStateStopped, 'attach')
    trace('attach', 'pid-after-stop', pid=int(process.GetProcessID()))
    if process.GetProcessID() != pid:
        raise RuntimeError('holder attach did not stop the expected fixture')
    with open(os.environ['MAC_CU_HOLDER_READY'], 'w') as ready:
        ready.write('attached')
    deadline = time.monotonic() + 40
    while not os.path.exists(os.environ['MAC_CU_HOLDER_RELEASE']) and time.monotonic() < deadline:
        time.sleep(.1)
except BaseException as error:
    trace('operation', 'error', error=repr(error))
    raise
finally:
    try:
        if attached and process and process.IsValid():
            trace('detach', 'state', state=int(process.GetState()))
        if attached and process and process.IsValid() and process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            trace('detach', 'request')
            result = process.Detach(False)
            trace('detach', 'result', result=str(result), rawState=int(process.GetState()))
            with open(os.environ['MAC_CU_HOLDER_DETACH'], 'w') as output:
                output.write('success' if result.Success() else str(result))
    finally:
        with open(os.environ['MAC_CU_HOLDER_READY'] + '.states', 'w') as output:
            import json
            json.dump(states, output)
