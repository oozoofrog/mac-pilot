"""Test-only direct supervisor entry. Canonical transport/engine, private evidence ledger."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import session


def main():
    # No public request fields, arbitrary command/expression or alternate attach route.
    if (len(sys.argv) != 4 or sys.argv[1] != '--owned-operation'
            or os.environ.get('MAC_CU_EDIT_PARENT') != str(os.getppid())
            or not os.environ.get('MAC_CU_FIXTURE_WORKER')
            or os.environ.get('MAC_CU_NATIVE_CHECK_CHILD')):
        return 64
    folder = session.capture.private_folder(Path(sys.argv[2]).resolve())
    ledger = Path(sys.argv[3]).resolve()
    if folder.parent.parent != ledger.parent or ledger.name != 'ledger':
        return 64
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    session.save(folder / 'supervisor-identity.json', session.watchdog.process_identity(os.getpid()))
    owned = []
    def spawn(argv, **kwargs):
        child = subprocess.Popen(argv, **kwargs)
        entry = {'argv': argv, 'pid': child.pid}
        try:
            entry['identity'] = session.watchdog.process_identity(child.pid)
            entry['exactExecutableAndParent'] = (entry['identity']['path'] == str(Path(argv[0]).resolve())
                                                and entry['identity']['parent'] == os.getpid())
        except Exception as error:
            entry['identityError'] = repr(error)
        owned.append((child, entry))
        # Never lose a newly spawned child's Popen handle because evidence writing
        # failed. Return it to the canonical supervisor so its finally can reap it.
        try:
            session.save(folder / 'owned-children.json', {'children': [e for _, e in owned]})
        except Exception as error:
            entry['evidenceError'] = repr(error)
        return child
    result = session.capture.supervise(session.capture.read_json(folder / 'request.json'), folder,
        session.capture.ProcessProbe(), stopped.is_set, popen=spawn, ledger_root=ledger)
    session.save(folder / 'result.json', result)
    for child, entry in owned:
        entry['returncode'] = child.poll()
        try:
            current = session.watchdog.process_status(child.pid)
            entry['residual'] = 'identityChanged' if current['start'] != entry.get('identity', {}).get('start') else 'present'
            entry['current'] = current
        except Exception as error:
            try:
                os.kill(child.pid, 0)  # Existence read only; no target/descendant signal.
            except ProcessLookupError:
                entry['residual'] = 'gone'
            else:
                entry.update(residual='unknown', error=repr(error))
    session.save(folder / 'owned-children.json', {'children': [e for _, e in owned],
        'allReapedAndAbsent': len(owned) == 2 and all(c.returncode is not None and 'identity' in e
            and not e.get('evidenceError') and e.get('exactExecutableAndParent') is True
            and e['residual'] in ('gone', 'identityChanged') for c, e in owned)})
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
