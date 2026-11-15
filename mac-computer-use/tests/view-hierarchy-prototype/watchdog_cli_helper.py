"""Fixed CLI-only worker and finite child; never accepts an executable command."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import remote_watchdog as watchdog


def event(path, name, **data):
    with path.open('a') as stream:
        stream.write(json.dumps(dict(event=name, pid=os.getpid(), parent=os.getppid(),
                                     monotonicNs=time.monotonic_ns(), **data)) + '\n')


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('normal', 'term', 'helper'):
        return 64
    mode, log = sys.argv[1], Path(sys.argv[2])
    if mode == 'helper':
        event(log, 'helper-start')
        time.sleep(.4)
        event(log, 'helper-exit')
        return 0
    stopping = False
    def stop(signum, frame):
        nonlocal stopping
        stopping = True
        event(log, 'worker-stop', signal=signum)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGALRM, stop)
    signal.alarm(4)  # Independent finite worker lifetime; finally still owns the wait.
    child = None
    try:
        if mode == 'term':
            child = subprocess.Popen([sys.executable, __file__, 'helper', str(log)],
                                     stdin=subprocess.DEVNULL)
        event(log, 'worker-ready', helper=child.pid if child else None, identity=watchdog.process_identity(os.getpid()))
        while mode == 'term' and not stopping:
            time.sleep(.01)
    finally:
        event(log, 'worker-finally')
        if child is not None:
            status = child.wait(timeout=2)
            event(log, 'helper-wait', child=child.pid, returncode=status)
        signal.alarm(0)
        event(log, 'worker-exit')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
