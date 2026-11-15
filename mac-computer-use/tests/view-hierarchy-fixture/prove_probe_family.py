"""Finite canonical Foundation identity proof. Host CLI only; never a Simulator route.

Build and prove are separate explicit entries. The generated main calls unchanged
simulatorViewCaptureTarget once on one directly owned, finite plain C sentinel.
No production source is edited and no replacement capture.py is used.
"""
import argparse
import ast
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import session as s
w = s.watchdog
SOURCE = s.RESOURCE.parent / 'mac-cu-src'
DEVICE = '11111111-1111-4111-8111-111111111111'


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def kernel_rows():
    """Advisory fast sampler, independent of the real observer's unchanged ps route."""
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    capacity = libc.proc_listallpids(None, 0) + 256
    pids = (ctypes.c_int * capacity)()
    count = libc.proc_listallpids(pids, ctypes.sizeof(pids))
    if not 0 < count < capacity:
        raise RuntimeError('incomplete kernel PID inventory')
    result = []
    for pid in pids[:count]:
        if pid <= 0: continue
        try: info = w.process_status(pid)
        except w.IdentityReadError: continue
        result.append((pid, info['parent'], info['group'], '', 'Z' if info['state'] == 5 else 'S'))
    return result


def full_family(roots, retained=(), retain_unknown=False):
    rows = kernel_rows()
    ids = set(roots) | set(retained)
    while True:
        found = {r[0] for r in rows if r[1] in ids}
        if found <= ids: break
        ids |= found
    result = []
    for row in rows:
        if row[0] not in ids: continue
        value = w.identify_live_server(row[0])
        if value is w.UNVERIFIED:
            if not retain_unknown: raise RuntimeError('unknown family identity: ' + str(row[0]))
            value = dict(pid=row[0], parent=row[1], group=row[2], observation='unknown', signalAuthority=False)
        if value is not None: result.append(value)
    return result


# SDK libproc.h: int proc_listpids(uint32_t, uint32_t, void *, int).
# sys/proc_info.h: PROC_PGRP_ONLY=2, PROC_PPID_ONLY=6. Result is bytes,
# unlike proc_listallpids. pid_t is a signed 32-bit int on this host ABI.
ADVISORY_MEMBERS = 64
ADVISORY_DEPTH = 8
ADVISORY_QUERIES = 256
ADVISORY_SECONDS = .1


class AdvisoryUnknown(RuntimeError):
    pass


def selected_pids(kind, value):
    if kind not in (2, 6) or type(value) is not int or not 0 < value <= 2147483647:
        raise AdvisoryUnknown('invalid bounded selector')
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    call = libc.proc_listpids
    call.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    call.restype = ctypes.c_int
    buffer = (ctypes.c_int32 * ADVISORY_MEMBERS)()
    ctypes.set_errno(0)
    size = call(kind, value, buffer, ctypes.sizeof(buffer))
    error = ctypes.get_errno()
    # Full buffer is ambiguous truncation, even if exactly full. Zero with no
    # errno is an empty selector result, never an identity/absence acceptance.
    if error or size < 0 or size >= ctypes.sizeof(buffer) or size % 4:
        raise AdvisoryUnknown('selector error/partial/saturated: %s/%s' % (size, error))
    result = list(buffer[:size // 4])
    if any(pid <= 0 for pid in result) or len(set(result)) != len(result):
        raise AdvisoryUnknown('invalid selector PID payload')
    return result


class AdvisoryFamily:
    """Bounded over-approximation; no acceptance, role, or signal authority.

    Retain discovered PIDs and groups across samples, including exited parents.
    Selectors are not an atomic census and cannot prove unsampled-child absence.
    """
    def __init__(self, roots):
        self.depths = {pid: 0 for pid in roots}
        self.groups = set(roots)
        self.unknowns = []

    def sample(self):
        until = s.monotonic() + ADVISORY_SECONDS
        records = []
        queried = set()
        read = set()
        def check():
            if s.monotonic() >= until:
                raise AdvisoryUnknown('advisory sample time budget')
            if len(self.depths) > ADVISORY_MEMBERS or len(self.groups) > ADVISORY_MEMBERS:
                raise AdvisoryUnknown('advisory member/group cap')
        def add(pid, depth):
            if pid not in self.depths or depth > self.depths[pid]:
                if depth > ADVISORY_DEPTH:
                    raise AdvisoryUnknown('advisory depth cap')
                self.depths[pid] = depth
            check()
        try:
            check()
            while True:
                for pid in sorted(set(self.depths) - read):
                    check()
                    read.add(pid)
                    try:
                        info = w.process_identity(pid)
                    except w.IdentityReadError as error:
                        info = dict(error.identity or {}, pid=pid, observation='unknown',
                                    syscall=error.syscall, result=error.result, errno=error.errno)
                        self.unknowns.append(info)
                    records.append(dict(info, signalAuthority=False, acceptanceAuthority=False, roleAuthority=False))
                    if info.get('group', 0) > 0:
                        self.groups.add(info['group'])
                    check()
                pending = (set((6, pid) for pid in self.depths) |
                           set((2, group) for group in self.groups)) - queried
                if not pending:
                    return records
                for kind, value in sorted(pending):
                    check()
                    if len(queried) >= ADVISORY_QUERIES:
                        raise AdvisoryUnknown('advisory query cap')
                    queried.add((kind, value))
                    found = selected_pids(kind, value)
                    check()
                    for pid in found:
                        add(pid, self.depths[value] + 1 if kind == 6 else self.depths.get(pid, 1))
        except BaseException as error:
            self.unknowns.append(dict(observation='unknown', error=repr(error), signalAuthority=False,
                                      acceptanceAuthority=False, roleAuthority=False))
            raise


def exact_instances(executable):
    """Exact private executable inventory; no process names or signals."""
    target = str(executable.resolve())
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    matches = []
    for row in kernel_rows():
        buf = ctypes.create_string_buffer(4096)
        if libc.proc_pidpath(row[0], buf, len(buf)) > 0 and os.path.realpath(os.fsdecode(buf.value)) == target:
            matches.append(row[0])
    return matches


def build(out):
    out.mkdir(mode=0o700)
    sys.path.insert(0, str(SOURCE.parent))
    from native_build import run_swift, native_inputs
    entry = '''func probeFamilyIdentity() -> Never {
    DispatchQueue.global().async {
        do {
            guard let directory = ProcessInfo.processInfo.environment["PROBE_FAMILY_DIRECTORY"] else { exit(64) }
            let folder = URL(fileURLWithPath: directory)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("owned-target.json"))) as! [String: Any]
            guard let pid = raw["pid"] as? Int32, let device = raw["deviceID"] as? String else { exit(64) }
            try Data("ready".utf8).write(to: folder.appendingPathComponent("root-ready"))
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("go").path) {
                if Date() >= deadline { exit(65) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let target = try simulatorViewCaptureTarget(pid: pid, deviceID: device)
            let result: [String: Any] = ["status": "success", "target": target.json]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            exit(0)
        } catch { fputs("\\(error)\\n", stderr); exit(1) }
    }
    dispatchMain()
}
'''
    (out / 'Proof.swift').write_text('import Foundation\nimport Darwin\n' + entry)
    (out / 'main.swift').write_text(s.native.isolated_main((SOURCE / 'main.swift').read_text(), 'probeFamilyIdentity()'))
    (out / 'sentinel.c').write_text('''#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--sentinel") || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    sleep(25); return 0;
}
''')
    resource = out / 'view-capture'; resource.mkdir(mode=0o700)
    for path in s.RESOURCE.glob('*.py'):
        (resource / path.name).write_bytes(path.read_bytes())
    inputs = [*sorted(SOURCE.glob('*.swift')), *native_inputs(SOURCE), *s.RESOURCE.glob('*.py'),
              Path(__file__), s.TESTS / 'native_check_support.py', out / 'main.swift', out / 'Proof.swift', out / 'sentinel.c']
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    save(out / 'build-inputs.json', hashes)
    commands = [(['clang', '-Wall', '-Wextra', '-Werror', str(out / 'sentinel.c'), '-o', str(out / 'sentinel')], 30),
                (['swiftc', '-whole-module-optimization', *map(str, sorted(p for p in SOURCE.glob('*.swift') if p.name != 'main.swift')),
                  str(out / 'Proof.swift'), str(out / 'main.swift'), '-o', str(out / 'session-probe')], 180)]
    for index, (command, deadline) in enumerate(commands):
        print('DECLARED build', index, 'deadline', deadline, 'compiler driver1 frontend1 linker1; native app0', flush=True)
        with (out / ('compile-' + str(index) + '.log')).open('x') as log:
            if index == 0:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=deadline, start_new_session=True)
            else:
                result = run_swift(command, stdout=log, stderr=subprocess.STDOUT, timeout=deadline, start_new_session=True)
        save(out / ('compile-' + str(index) + '.json'), {'command': command, 'exit': result.returncode, 'deadlineSeconds': deadline})
        if result.returncode: raise RuntimeError('canonical compile failed; preserve logs')
    for path, digest in hashes.items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest: raise RuntimeError('build input changed')
    save(out / 'binaries.json', {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in ('session-probe', 'sentinel')})


def run_guard(out, executable, arguments, env, expected, index):
    print('DECLARED guard', index, 'deadline5s executable1 children0', flush=True)
    record = {'arguments': arguments, 'deadlineSeconds': 5, 'budget': 'executable1 children0'}
    child = None; family = []
    private_executable = executable.name in {'session-probe', 'sentinel'}
    if private_executable and exact_instances(executable):
        raise RuntimeError('exact guard executable already runs')
    try:
        with (out / ('guard-' + str(index) + '.log')).open('x') as log:
            until = s.monotonic() + 5
            child = subprocess.Popen([str(executable), *arguments], env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = child.pid
            try: record['directIdentity'] = w.process_identity(child.pid)
            except w.IdentityReadError as e: record['identityReadError'] = repr(e)
            while child.poll() is None:
                family = full_family({child.pid}, retain_unknown=True)
                record.setdefault('observations', []).append(family)
                for info in family:
                    if private_executable and info.get('path') and info['path'] != str(executable.resolve()):
                        raise RuntimeError('guard executable changed')
                    if info['pid'] == child.pid and (info['parent'] != os.getpid() or info['group'] != child.pid):
                        raise RuntimeError('guard parent/group changed')
                if any(r['pid'] != child.pid for r in family): raise RuntimeError('guard created a descendant')
                if private_executable and len(exact_instances(executable)) > 1: raise RuntimeError('duplicate exact guard executable')
                if s.monotonic() >= until: raise TimeoutError('guard deadline')
                time.sleep(.01)
            record['exit'] = child.wait(timeout=1)
            if s.monotonic() >= until: raise TimeoutError('guard acceptance deadline')
            if child.returncode not in expected: raise RuntimeError('guard unexpected exit')
    except BaseException as error:
        record['error'] = repr(error)
        raise
    finally:
        if child:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
            rows = kernel_rows()
            record['residue'] = [r for r in rows if r[2] == child.pid or r[1] == child.pid or r[0] in {i['pid'] for i in family}]
            record['reaped'] = child.returncode is not None
            record['finalReturncode'] = child.returncode
            if private_executable: record['exactExecutableResidue'] = exact_instances(executable)
            save(out / ('guard-' + str(index) + '.json'), record)
            if record['residue'] or record.get('exactExecutableResidue'): raise RuntimeError('guard residue; stop, independent reconciliation required')


def reuse_guards(receipts, build, out):
    """Reuse only the retained exact controller's unchanged guard call graph."""
    old_root = receipts.parent / 'source-after'
    relative = Path(__file__).resolve().relative_to(s.TESTS.parent.parent)
    old = old_root / relative
    controller = json.loads((receipts / 'controller-inputs.json').read_text())
    if hashlib.sha256(old.read_bytes()).hexdigest() != controller['currentControllerSHA256']:
        raise RuntimeError('old guard controller pin mismatch')
    def nodes(path):
        return {n.name: ast.dump(n, include_attributes=False) for n in ast.parse(path.read_text()).body
                if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    before, after = nodes(old), nodes(Path(__file__))
    for name in ('run_guard', 'kernel_rows', 'full_family', 'exact_instances'):
        if before[name] != after[name]: raise RuntimeError('guard logic changed: ' + name)
    # rows is not reachable from these guards (they use kernel_rows). All other
    # shared watchdog definitions must match, including identity and checkpoints.
    before, after = nodes(old_root / 'mac-computer-use/tests/view-hierarchy-prototype/remote_watchdog.py'), nodes(Path(w.__file__))
    if {k:v for k,v in before.items() if k != 'rows'} != {k:v for k,v in after.items() if k != 'rows'}:
        raise RuntimeError('guard identity dependency changed')
    copied = {}
    for index in [*range(12), 'sentinel-inherited', 'sentinel-unknown', 'worker-unowned', 'worker-inherited', 'selected-xcode']:
        path = receipts / ('guard-' + str(index) + '.json')
        record = json.loads(path.read_text())
        expected = {0,1} if index == 0 else {0} if index == 'selected-xcode' else {64}
        if (record.get('error') or record.get('exit') not in expected or not record.get('reaped') or
                record.get('finalReturncode') != record['exit'] or record.get('residue') != [] or
                record.get('exactExecutableResidue', []) != [] or record.get('deadlineSeconds') != 5):
            raise RuntimeError('guard receipt not reusable: ' + str(index))
        if isinstance(index, int) or str(index).startswith('sentinel'):
            executable = build / ('session-probe' if isinstance(index,int) else 'sentinel')
            if record.get('directIdentity', {}).get('path') != str(executable.resolve()):
                raise RuntimeError('guard binary path mismatch')
        if str(index).startswith('worker') and record.get('directIdentity', {}).get('path') != str(Path(sys.executable).resolve()):
            raise RuntimeError('guard worker interpreter changed')
        copied[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    selected = (receipts / 'guard-selected-xcode.log').read_text().strip()
    if Path('/var/db/xcode_select_link').resolve() != Path(selected).resolve():
        raise RuntimeError('selected Xcode changed or selection cannot be proved')
    (out / 'guard-selected-xcode.log').write_text(selected + '\n')
    save(out / 'guard-reuse.json', dict(receipts=copied, currentControllerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
         guardLogicUnchanged=True, watchdogRowsExcludedAsUnreachable=True))


def load_callbacks():
    # Reuse the contract test's isolated module loader; no test execution.
    from test_probe_family import callbacks
    return list(callbacks())


def prove(build, out, trace=None, guard_receipts=None):
    out.mkdir(mode=0o700, exist_ok=False)
    recipe = str(Path(__file__).resolve())
    build_hashes = json.loads((build / 'build-inputs.json').read_text())
    for path, digest in json.loads((build / 'build-inputs.json').read_text()).items():
        # The Python controller is not linked into the native executable. Preserve
        # its build-time hash; independently pin today's controller below.
        if path == recipe: continue
        if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest: raise RuntimeError('proof input changed')
        if Path(path).parent == s.RESOURCE:
            if hashlib.sha256((build / 'view-capture' / Path(path).name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('staged canonical Python resource changed')
    for name, digest in json.loads((build / 'binaries.json').read_text()).items():
        if hashlib.sha256((build / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('compiled CLI executable changed')
    save(out / 'controller-inputs.json', {'buildRecipeSHA256': build_hashes[recipe],
         'currentControllerSHA256': hashlib.sha256(Path(recipe).read_bytes()).hexdigest(),
         'nativeAndResourceInputsReverified': True})
    env = {k:v for k,v in os.environ.items() if not k.startswith(('MAC_CU_', 'FIXTURE_', 'PYTHON', 'DYLD_'))}
    if guard_receipts is not None:
        reuse_guards(guard_receipts, build, out)
    else:
        routes = [(['--check-screen-recording'], env, {0,1}),
                  (['--native-check'], dict(env, MAC_CU_NATIVE_CHECK_CHILD='1'), {64})]
        routes += [([route], env, {64}) for route in ('--daemon','--mode','--request-accessibility','--request-screen-recording',
                    '--pick-request','--approve','--quit-daemon','--update','--unknown-native-check')]
        routes += [([], env, {64})]
        for index, (args, environment, expected) in enumerate(routes):
            run_guard(out, build / 'session-probe', args, environment, expected, index)
        run_guard(out, build / 'sentinel', ['--sentinel'], dict(env, MAC_CU_NATIVE_CHECK_CHILD='1'), {64}, 'sentinel-inherited')
        run_guard(out, build / 'sentinel', ['--unknown'], env, {64}, 'sentinel-unknown')
        run_guard(out, Path(sys.executable), ['-B', str(Path(__file__).resolve()), '--worker', str(build), '--output', str(out)], env, {64}, 'worker-unowned')
        run_guard(out, Path(sys.executable), ['-B', str(Path(__file__).resolve()), '--worker', str(build), '--output', str(out)],
                  dict(env, MAC_CU_NATIVE_CHECK_CHILD='1'), {64}, 'worker-inherited')
        run_guard(out, Path('/usr/bin/xcode-select'), ['-p'], env, {0}, 'selected-xcode')
    print('DECLARED proof work15s total30s sentinel1(finite25s) worker1 probe1 Foundation helper1 monitor-ps1; descendant signals0', flush=True)
    callbacks = load_callbacks()
    report = {'scope': 'host CLI identity only; no guest identity qualification', 'errors': [], 'observations': [],
              'budgets': {'sentinel':1,'worker':1,'probe':1,'identityHelper':1,'monitorPS':1},
              'deadlineSeconds':30, 'sourceHashes': json.loads((build / 'build-inputs.json').read_text())}
    sentinel = worker = None; stop = threading.Event(); sampler = None; tracked = {}; observed_groups = set(); started = s.monotonic()
    logs = []
    if trace is not None: trace.deadline = started + 30
    # Selected paths only; do not invoke tools_for_xcode (which also queries Simulator SDK).
    developer = Path((out / 'guard-selected-xcode.log').read_text().strip()).resolve()
    server = developer.parent / 'SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'
    def check(snapshot, group, target, build, server_path, details):
        for name, callback in callbacks:
            if trace is None:
                callback(snapshot, group, target, build, server_path, details)
            else:
                with trace.span('validation'):
                    callback(snapshot, group, target, build, server_path, details)
            counts = report.setdefault('callbackChecks', {})
            counts[name] = counts.get(name, 0) + 1
    try:
        sf = (out / 'sentinel.log').open('x'); logs.append(sf)
        sentinel = subprocess.Popen([str(build / 'sentinel'), '--sentinel'], env=dict(env, SIMULATOR_UDID=DEVICE),
                                    stdin=subprocess.DEVNULL, stdout=sf, stderr=subprocess.STDOUT, start_new_session=True)
        target = w.process_identity(sentinel.pid); report['sentinel'] = target
        authored = dict(target, deviceID=DEVICE); save(out / 'owned-target.json', authored)
        wf = (out / 'worker.log').open('x'); logs.append(wf)
        worker = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), '--worker', str(build), '--output', str(out)],
                                  env=dict(env, PROBE_FAMILY_DIRECTORY=str(out), PROBE_FAMILY_PARENT=str(os.getpid())), stdin=subprocess.DEVNULL,
                                  stdout=wf, stderr=subprocess.STDOUT, start_new_session=True)
        report['worker'] = w.process_identity(worker.pid)
        options = s.probe_family_options(build, server)
        advisory = AdvisoryFamily({worker.pid})
        def sample():
            try:
                with (out / 'kernel-observations.jsonl').open('x') as raw:
                    iterations = 0
                    while not stop.is_set():
                        iterations += 1
                        if iterations > 7500: raise AdvisoryUnknown('advisory iteration cap')
                        for info in advisory.sample():
                            if info.get("group"): observed_groups.add(info["group"])
                            pid = info['pid']
                            if tracked.get(pid) != info:
                                raw.write(json.dumps({'monotonic':s.monotonic(),'identity':info})+'\n');raw.flush()
                                tracked[pid] = info
                        if advisory.unknowns: raise AdvisoryUnknown('advisory identity unknown')
                        time.sleep(.002)
            except BaseException as error: report['samplerError'] = repr(error)
            finally:
                report['advisoryUnknowns'] = advisory.unknowns
                report['advisoryDiscoveredPIDs'] = sorted(advisory.depths)
                report['advisoryDiscoveredGroups'] = sorted(advisory.groups)
        sampler = threading.Thread(target=sample); sampler.start()
        sent = False
        while worker.poll() is None:
            if report.get('samplerError') or advisory.unknowns:
                raise AdvisoryUnknown('advisory observation incomplete')
            if s.monotonic() - started >= 15: raise TimeoutError('fixed proof work deadline')
            if len(exact_instances(build / 'session-probe')) > 1 or exact_instances(build / 'sentinel') != [sentinel.pid]:
                raise RuntimeError('exact CLI executable instance budget exceeded')
            s.observe_processes(worker.pid, None, build, server, report, started + 15, process_check=check)
            if report.get('samplerError') or advisory.unknowns:
                raise AdvisoryUnknown('advisory observation incomplete before release')
            if (out / 'root-ready').exists() and not sent:
                (out / 'go').touch(); sent = True
            time.sleep(.005)
        report['workerExit'] = worker.wait(timeout=1)
        if worker.returncode != 0: raise RuntimeError('proof worker failed')
        result = json.loads((out / 'canonical-identity.json').read_text())
        if result['target'] != {k:authored[k] for k in ('pid','start','path','deviceID')}:
            raise RuntimeError('canonical result differs from owned sentinel')
        fresh = w.process_identity(sentinel.pid)
        if any(fresh[k] != target[k] for k in ('pid','start','path','parent','group')):
            raise RuntimeError('sentinel lifetime changed')
        report['canonicalResult'] = result
        verified = [e for e in report.get('residentExecutableObservations',[]) if e.get('status')=='verifiedReadHelper'
                    and e.get('role') == 'identity' and (e.get('identity') or {}).get('path') in options['probe_python']]
        report['fullIdentityHelperObserved'] = bool(verified)
        if not verified: report['errors'].append('canonical call returned but helper too short for real observer; model not runtime-proven')
    except BaseException as error:
        report['errors'].append(repr(error))
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM): signal.signal(sig, signal.SIG_IGN)
        if worker and worker.poll() is None:
            worker.terminate()
            try: worker.wait(timeout=max(.1,started+25-s.monotonic()))
            except subprocess.TimeoutExpired:
                report['errors'].append('worker still owns descendants; no kill fallback')
        stop.set()
        if sampler: sampler.join(timeout=1)
        if sampler and sampler.is_alive(): report['errors'].append('sampler did not join')
        if sentinel:
            if sentinel.poll() is None: sentinel.terminate()
            try: sentinel.wait(timeout=2)
            except subprocess.TimeoutExpired: sentinel.kill(); sentinel.wait(timeout=2)
        roots = {p.pid for p in (worker,sentinel) if p}
        roots |= set(report.get('advisoryDiscoveredPIDs', []))
        groups = roots | observed_groups | set(report.get('advisoryDiscoveredGroups', []))
        report['terminalReads'] = []
        for pid in roots | set(tracked):
            try:
                os.kill(pid, 0)
                report['terminalReads'].append({'pid':pid,'status':'existsOrZombie'})
                report['errors'].append('recorded PID still exists: '+str(pid))
            except ProcessLookupError:
                report['terminalReads'].append({'pid':pid,'status':'ESRCH'})
        report['cleanupRows'] = [r for r in kernel_rows() if r[2] in groups or r[0] in tracked or r[1] in roots | set(tracked)]
        report['groups'] = sorted(groups)
        report['directReaped'] = {str(p.pid):p.returncode for p in (worker,sentinel) if p}
        if report['cleanupRows']: report['errors'].append('unexpected residue; stop and reconcile independently')
        if report.get('samplerError'): report['errors'].append(report['samplerError'])
        if report.get('advisoryUnknowns'): report['errors'].append('advisory unknowns retained')
        if trace is not None:
            report['trace'] = dict(truncated=trace.truncated, storageFailed=trace.storage_failed)
            if trace.truncated or trace.storage_failed: report['errors'].append('trace tail unknown')
        report['elapsedSeconds'] = s.monotonic() - started
        if report['elapsedSeconds'] > 30: report['errors'].append('total proof deadline exceeded')
        report['passed'] = not report['errors']
        save(out / 'proof.json', report)
        for log in logs: log.close()
    if not report['passed']: raise RuntimeError('proof incomplete; inspect proof.json; no automatic retry')


def main():
    def interrupted(*_):
        raise s.native.NativeCheckInterrupted('CLI proof interrupted; direct-child cleanup follows')
    for sig in (signal.SIGINT, signal.SIGTERM): signal.signal(sig, interrupted)
    if os.environ.get('MAC_CU_NATIVE_CHECK_CHILD'):
        raise SystemExit(64)
    parser=argparse.ArgumentParser(allow_abbrev=False)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--build',type=Path); group.add_argument('--prove',type=Path); group.add_argument('--worker',type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--reuse-guards',type=Path)
    parser.add_argument('--trace',type=Path, help='existing private directory; single controller only')
    args=parser.parse_args()
    if args.build: build(args.build.resolve())
    elif args.prove:
        if args.output is None: parser.error('--prove requires a fresh --output directory')
        if args.trace is None:
            prove(args.prove.resolve(), args.output.resolve(), guard_receipts=args.reuse_guards)
        else:
            from trace_process_reads import ProcessReadTrace
            with ProcessReadTrace(args.trace, 'cli-parent', max_bytes=1048576, max_events=4096) as trace:
                trace.bind(w, 'rows', 'rows')
                trace.bind(w.ProcessObservation, 'snapshot', 'snapshot')
                trace.bind(w, 'wait_group_readback', 'readback')
                trace.bind(Path, 'read_text', 'receipt-read')
                trace.bind(sys.modules[__name__], 'save', 'receipt-write')
                prove(args.prove.resolve(), args.output.resolve(), trace, args.reuse_guards)
    else:
        if os.environ.get('PROBE_FAMILY_PARENT') != str(os.getppid()):
            raise SystemExit(64)
        if args.output is None: raise SystemExit(64)
        built=args.worker.resolve();out=args.output.resolve()
        value=s.probe(built,out,'canonical-identity',DEVICE)
        if value.get('status')!='success': raise RuntimeError('canonical identity failed')

if __name__=='__main__': main()
