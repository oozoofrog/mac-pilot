"""Headless one-process parent bound. Never use for a guest/GUI/debugger attach."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(command, output, name, seconds, environment=None, expected=0):
    output = Path(output); started = time.monotonic(); child = None
    record = {'command': command, 'deadlineSeconds': seconds, 'processBudget': 1, 'expectedExit': expected}
    def rows():
        text = subprocess.check_output(['/bin/ps', '-axo', 'pid=,pgid=,comm='], text=True, timeout=3)
        return [line.strip() for line in text.splitlines() if len(line.split(None, 2)) == 3 and int(line.split(None, 2)[1]) == child.pid]
    def stop(signum, frame):
        raise InterruptedError('headless parent interrupted: ' + str(signum))
    previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with (output / (name + '.log')).open('w') as log:
            child = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = child.pid
            while child.poll() is None:
                members = rows()
                if len(members) > 1:
                    raise RuntimeError('headless exact group budget exceeded: ' + repr(members))
                if time.monotonic() - started >= seconds:
                    raise TimeoutError('headless process exceeded deadline')
                time.sleep(.05)
            record['exit'] = child.wait(timeout=1)
            if record['exit'] != expected:
                raise RuntimeError('headless command exit differs: ' + str(record['exit']))
    except BaseException as error:
        record['error'] = repr(error)
    finally:
        if child:
            # Only the new headless process group; it is forbidden to own a guest.
            if child.poll() is None or rows():
                try:
                    os.killpg(child.pid, signal.SIGSTOP); os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.wait(timeout=5)
            record['remaining'] = rows()
        record['elapsedSeconds'] = time.monotonic() - started
        (output / (name + '-parent.json')).write_text(json.dumps(record, indent=2) + '\n')
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if record.get('error') or record.get('remaining'):
        raise RuntimeError('headless check failed; see ' + str(output / (name + '-parent.json')))
    return record
