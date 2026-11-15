"""One serial, bounded CLI regression. No debugger, target fixture or GUI."""
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time
from unittest.mock import patch
import remote_watchdog as watchdog

HERE = Path(__file__).resolve().parent
HELPER = HERE / 'watchdog_cli_helper.py'


def guard():
    # Import paths must be inert, including watchdog's main guard.
    with patch.object(subprocess, 'Popen', side_effect=AssertionError('import launched process')):
        for path in (HERE / 'remote_watchdog.py', HELPER, Path(__file__)):
            runpy.run_path(str(path), run_name='cli_import_guard')
    print('import guards passed', flush=True)


def events(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def main():
    guard()
    if sys.argv[1:] == ['--guard']:
        return
    modes = ('normal', 'term')
    if len(sys.argv) == 5 and sys.argv[3:] == ['--case', 'term']:
        modes = ('term',)
    elif len(sys.argv) != 3:
        raise SystemExit('use --guard or --output NEW_DIRECTORY [--case term]')
    if sys.argv[1] != '--output':
        raise SystemExit('use --guard or --output NEW_DIRECTORY [--case term]')
    out = Path(sys.argv[2])
    out.mkdir(exist_ok=False)
    report = {'maximumTotalSeconds': 42, 'initialDeadlineSeconds': 20, 'cleanupSecondsPerCase': 6,
              'budget': 'supervisor1 + worker1 + fixed helper1; transient ps1', 'cases': []}
    def interrupted(signum, frame):
        raise TimeoutError('parent deadline/interruption ' + str(signum))
    for sig in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    signal.alarm(20)
    try:
        for mode in modes:
            log = out / (mode + '.jsonl')
            case = {'mode': mode}
            report['cases'].append(case)
            worker = subprocess.Popen([sys.executable, str(HELPER), mode, str(log)],
                                      stdin=subprocess.DEVNULL, start_new_session=True)
            try:
                ready_deadline = time.monotonic() + 2
                while not any(e['event'] == 'worker-ready' for e in events(log)):
                    if time.monotonic() >= ready_deadline:
                        raise TimeoutError('worker readiness')
                    time.sleep(.01)
                if mode == 'term':
                    case['identity'] = watchdog.process_identity(worker.pid)
                    assert case['identity']['parent'] == os.getpid()
                    # macOS framework Python's kernel executable differs from sys.executable.
                    case['supervisorIdentity'] = watchdog.process_identity(os.getpid())
                    assert case['identity']['path'] == case['supervisorIdentity']['path']
                    helper_pid = next(e['helper'] for e in events(log) if e['event'] == 'worker-ready')
                    case['helperIdentity'] = watchdog.process_identity(helper_pid)
                    assert case['helperIdentity']['parent'] == worker.pid
                else:
                    worker.wait(timeout=2)
                case['grace'] = {}
                watchdog.graceful_stop(worker, case['grace'], timeout=4)
            finally:
                # Never kill a worker that might still own a helper. Its own finite
                # lifetime and finally/wait run before this parent's wait completes.
                signal.alarm(6)
                worker.wait(timeout=5)
                case['finish'] = {}
                with patch.object(worker, 'terminate', side_effect=AssertionError('reaped TERM')), \
                     patch.object(worker, 'kill', side_effect=AssertionError('reaped KILL')):
                    watchdog.graceful_stop(worker, {}, timeout=0)
                    watchdog.finish_direct_worker(worker, case['finish'], timeout=1)
                case['residual'] = watchdog.wait_group_readback(worker.pid, timeout=0)
                case['events'] = events(log)
            assert worker.returncode == 0
            assert case['residual']['groupEmpty']
            names = [e['event'] for e in case['events']]
            assert names[-1] == 'worker-exit'
            if mode == 'term':
                assert case['grace']['status'] == 'exited after TERM'
                assert next(e for e in case['events'] if e['event'] == 'worker-stop')['signal'] == signal.SIGTERM
                assert names.index('worker-stop') < names.index('worker-finally') < names.index('helper-wait') < names.index('worker-exit')
                assert next(e for e in case['events'] if e['event'] == 'helper-wait')['returncode'] == 0
            signal.alarm(10)  # Remaining serial case budget, including cleanup.
        report['passed'] = True
    except BaseException as error:
        report.update(passed=False, error=repr(error))
        raise
    finally:
        signal.alarm(0)
        (out / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
