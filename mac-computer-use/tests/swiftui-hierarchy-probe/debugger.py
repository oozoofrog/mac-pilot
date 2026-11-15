"""One owned debugserver/LLDB bootstrap. Never executes fixture work in an expression."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
sys.dont_write_bytecode = True
import time
import threading

HERE = Path(__file__).resolve().parent
RESOURCE = HERE.parent.parent / 'skills/mac-computer-use/scripts/view-capture'
sys.path.insert(0, str(HERE))
import protocol as p
import worker_runtime
RUNTIME_PROOF = None
spec = importlib.util.spec_from_file_location('resident_capture_support', RESOURCE / 'capture.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
BOOTSTRAP_SECONDS = 30
CHILD_GRACE_SECONDS = 10
REAP_SECONDS = 10


def admit_fixture(target):
    """Read the existing Simulator fixture signature; never alter app entitlements."""
    executable = Path(target['path'])
    info = plistlib.loads((executable.parent / 'Info.plist').read_bytes())
    p.require(info['CFBundleIdentifier'].startswith('local.mac-pilot.swiftui-probe.') and
              info['CFBundleExecutable'] == 'SwiftUIProbe' and executable.name == 'SwiftUIProbe', 'not owned probe')
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j'], timeout=5))['devices']
    p.require(target['deviceID'] == '64A62D96-12FE-4D9C-81AE-ED9C3A2174F0' and
              any(d['udid'] == target['deviceID'] and d['state'] == 'Booted'
                  for d in devices.get('com.apple.CoreSimulator.SimRuntime.iOS-27-2', [])), 'wrong device/runtime')
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j'], timeout=5))['runtimes']
    runtime = next(r for r in runtimes if r['identifier'] == 'com.apple.CoreSimulator.SimRuntime.iOS-27-2')
    p.require(runtime['version'] == '27.2' and runtime['buildversion'] == '24B114' and
              runtime['supportedArchitectures'] == ['arm64'] and runtime['isAvailable'], 'wrong runtime tuple')
    p.require(subprocess.check_output(['xcodebuild', '-version'], text=True, timeout=5).strip() ==
              'Xcode 27.2\nBuild version 27B48', 'wrong Xcode tuple')
    installed = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', target['deviceID'], info['CFBundleIdentifier'], 'app'], text=True, timeout=5).strip()
    p.require(Path(installed).resolve() == executable.parent, 'wrong installed application')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(executable.parent)], check=True, timeout=5,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    signed = subprocess.check_output(['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-', str(executable)], timeout=5, stderr=subprocess.PIPE)
    p.require(len(signed) <= 65536 and plistlib.loads(signed).get('com.apple.security.get-task-allow') is True,
              'missing signed debug entitlement')
    return {'bundleID': info['CFBundleIdentifier'], 'runtime': runtime, 'targetResigned': False}


def submission(address, folder):
    p.scalar(address, 1); p.absolute(str(folder))
    # Only a verified exported symbol address and validated literal path are used.
    # The exported function synchronously copies all caller-owned bytes.
    return '(int)((int (*)(const char *))0x%x)(%s)' % (address, json.dumps(str(folder)))


class Engine(c.LLDBEngine):
    active_call = None

    def select_stopped_main(self):
        lldb = self.lldb
        p.require(self.process.GetState() == lldb.eStateStopped, 'load requires stopped process')
        candidates = [self.process.GetThreadAtIndex(i) for i in range(self.process.GetNumThreads())
                      if self.process.GetThreadAtIndex(i).GetQueueName() == 'com.apple.main-thread']
        p.require(len(candidates) == 1, 'main queue thread is ambiguous')
        thread = candidates[0]
        frames = []
        for index in range(65):
            f = thread.GetFrameAtIndex(index)
            if not f.IsValid():
                break
            row = {'function': f.GetFunctionName() or '', 'module': str(f.GetModule().GetFileSpec())}
            if '.$main()' in row['function']:
                symbol = f.GetSymbol()
                if symbol.IsValid():
                    start, end = symbol.GetStartAddress(), symbol.GetEndAddress()
                    row['symbol'] = {'name': symbol.GetName() or '', 'mangled': symbol.GetMangledName() or '',
                                     'module': str(start.GetModule().GetFileSpec()),
                                     'start': start.GetLoadAddress(self.target), 'end': end.GetLoadAddress(self.target),
                                     'pc': f.GetPC()}
            frames.append(row)
        c.write_json(Path(self.config['evidenceDirectory']) / 'main-thread-entry.json', {'frames': frames})
        runtime = self.config['admission']['runtime']['runtimeRoot']
        p.require(c.edit_backend.safe_entry(frames, self.config['request']['target']['path'], runtime), 'unsupported main entry: requires qualified UIKit startup or exact SwiftUI idle startup with executable-bound generated main; active callbacks are unsupported')
        self.process.SetSelectedThread(thread); self.frame = thread.GetFrameAtIndex(0)
        p.require(self.frame.IsValid(), 'invalid main-thread frame')
        runtime = self.config['admission']['runtime']['runtimeRoot']
        p.require(all(not ('/RuntimeRoot/' in f['module']) or f['module'].startswith(runtime + '/') for f in frames), 'stack runtime differs from verified selected runtime')
        return {'threadID': thread.GetThreadID(), 'queue': thread.GetQueueName(), 'frames': frames}

    def load_submit(self, folder, image, image_uuid):
        self.control(); self.check_server()
        p.require(self.target.GetTriple().startswith('arm64-') and self.target.GetTriple().endswith('-simulator'),
                  'only compiled arm64 Simulator image supported')
        first = self.config['experimentRequest']['sequence'] == 1
        existing = self.target.FindFunctions('mac_cu_resident_submit').GetSize()
        p.require((first and existing == 0) or (not first and existing > 0), 'image pin sequence mismatch')
        token = None
        if first:
            error = self.lldb.SBError()
            c.write_json(folder / 'load-attempt.json', {'image': image, 'uuid': image_uuid, 'monotonicNS': p.monotonic_ns()})
            self.active_call = 'load'
            token = self.process.LoadImage(self.lldb.SBFileSpec(image), error)
            p.require(error.Success() and token != self.lldb.LLDB_INVALID_IMAGE_TOKEN, 'LoadImage uncertain: ' + str(error))
            p.require(self.process.GetState() == self.lldb.eStateStopped, 'LoadImage did not return stopped')
            self.active_call = None
        modules = [self.target.GetModuleAtIndex(i) for i in range(self.target.GetNumModules())
                   if (self.target.GetModuleAtIndex(i).GetUUIDString() or '').upper() == image_uuid.upper()]
        p.require(len(modules) == 1, 'loaded helper UUID is not unique')
        module = modules[0]
        p.require(Path(str(module.GetFileSpec())).resolve() == Path(image), 'loaded helper path differs')
        symbols = [module.GetSymbolAtIndex(i) for i in range(module.GetNumSymbols())
                   if module.GetSymbolAtIndex(i).GetName() == 'mac_cu_resident_submit']
        p.require(len(symbols) == 1 and symbols[0].GetType() == self.lldb.eSymbolTypeCode, 'fixed exported entry is ambiguous')
        address = symbols[0].GetStartAddress().GetLoadAddress(self.target)
        text = module.FindSection('__TEXT').FindSubSection('__text')
        lower = text.GetLoadAddress(self.target); upper = lower + text.GetByteSize()
        p.require(text.IsValid() and lower <= address < upper, 'entry not inside helper text')
        image_evidence = {'loadToken': token, 'uuid': image_uuid, 'path': image, 'loadCount': 1 if first else 0, 'retainedForLifetime': True,
                          'textStart': lower, 'textEnd': upper, 'submitPC': address,
                          'residentFileBytes': Path(image).stat().st_size,
                          'mappedSectionBytes': sum(module.GetSectionAtIndex(i).GetByteSize() for i in range(module.GetNumSections()))}
        c.write_json(folder / 'loaded-image.json', image_evidence)
        self.control()
        options = self.lldb.SBExpressionOptions()
        options.SetLanguage(self.lldb.eLanguageTypeObjC_plus_plus)
        options.SetAutoApplyFixIts(False); options.SetTryAllThreads(False)
        options.SetStopOthers(True); options.SetUnwindOnError(False)
        options.SetTrapExceptions(False); options.SetIgnoreBreakpoints(True)
        options.SetTimeoutInMicroSeconds(2000000); options.SetOneThreadTimeoutInMicroSeconds(2000000)
        c.write_json(folder / 'submission-attempt.json', {'monotonicNS': p.monotonic_ns(), 'replayAllowed': False})
        self.active_call = 'submission'
        value = self.frame.EvaluateExpression(submission(address, folder), options)
        p.require(value.GetError().Success(), 'submission uncertain: ' + str(value.GetError()))
        returned = p.monotonic_ns()
        p.require(self.process.GetState() == self.lldb.eStateStopped, 'submission did not leave main stopped')
        self.active_call = None
        p.require(value.GetValueAsSigned() == 1, 'submission returned refusal')
        c.verify_target(self.probe, self.config['request']['target'], running=False)
        p.require(not (folder / 'entered.json').exists() and not (folder / 'terminal.json').exists(),
                  'callback ran before detach')
        return {'image': image_evidence, 'submitReturnedNS': returned}


def finish_engine(engine, result):
    """A stopped checkpoint is not proof that an interrupted JIT caller returned."""
    result['activeCall'] = engine.active_call
    if engine.active_call is not None:
        result.update(custodyRequired=True, detach='withheld: JIT caller completion unknown', debuggerClosed=False)
        return False
    try:
        result['detachStartedNS'] = p.monotonic_ns()
        result['detach'] = engine.detach()
        result['detachReturnedNS'] = p.monotonic_ns()
        p.require(result['detach'] in ('success', 'not attached', 'target exited', 'already detached'),
                  'detach completion unknown; debugger retained')
        engine.close()
        result['debuggerClosed'] = True
        return True
    except BaseException as error:
        result.update(cleanupError=repr(error), custodyRequired=True, debuggerClosed=False)
        return False


def finish_children(child, server, result):
    # A live/unreported worker may still own JIT code and the private transport.
    # Killing either child could discard that ownership or resume a pending caller.
    if child is not None and result.get('debuggerClosed') is not True:
        result.update(custodyRequired=True, childrenReaped=False,
                      retainedChildren=[{'role': name, 'pid': owned.pid, 'returncode': owned.poll()}
                                        for name, owned in (('lldb', child), ('debugserver', server)) if owned is not None])
        return False
    for label, owned in (('lldb', child), ('debugserver', server)):
        try:
            result[label + 'Exit'] = c.stop_child(owned)
        except BaseException as error:
            result[label + 'CleanupError'] = repr(error)
    result['childrenReaped'] = all(x is None or x.returncode is not None for x in (child, server))
    return result['childrenReaped']


class ServerReaper:
    """Observe/reap only the exact direct handle; never signal or release custody.

    CPython 3.9 poll uses nonblocking waitpid on this Popen handle. A stoppable
    poll loop avoids an unbounded wait thread when a live server must be retained.
    The supervisor joins before finish_children/stop_child touches the handle.
    """
    def __init__(self, server):
        self.server = server
        self.stop = threading.Event()
        self.evidence = {'pid': server.pid, 'startedNS': p.monotonic_ns()}
        self.thread = threading.Thread(target=self.run, name='swiftui-server-reaper')
        self.thread.start()

    def run(self):
        try:
            while not self.stop.is_set():
                code = self.server.poll()
                if code is not None:
                    self.evidence.update(returncode=code, reapedNS=p.monotonic_ns())
                    break
                self.stop.wait(.025)
        except BaseException as error:
            # Transport errors are evidence of failure, never evidence of exit.
            self.evidence['error'] = repr(error)
        finally:
            self.evidence['finishedNS'] = p.monotonic_ns()

    def finish(self):
        self.stop.set()
        # poll is nonblocking; Event wakes immediately. No child-wait deadline
        # is added or extended, and no live retained child is killed to join.
        self.thread.join()
        return dict(self.evidence, joined=True)


def worker(folder, fd):
    config = json.loads((folder / 'worker.json').read_text())
    p.require(os.getppid() == config['supervisor'] and os.environ.get('MAC_CU_RESIDENT_WORKER') == config['token'],
              'worker parent/token mismatch')
    worker_runtime.verify(config.get('workerRuntime'), bound_worker=True)
    p.require(config['pythonPath'] == config['workerRuntime']['context']['pythonPath'], 'LLDB path changed')
    signal.signal(signal.SIGTERM, lambda *_: None) # bounded parent owns child; no target interrupts
    signal.signal(signal.SIGINT, lambda *_: None)
    result = {'status': 'pending/uncertain', 'detach': 'not attempted'}
    engine = None
    def control():
        p.require(p.monotonic() < config['deadline'], 'bootstrap deadline exceeded')
    try:
        p.validate(config['experimentRequest'])
        c.verify_target(c.ProcessProbe(), config['request']['target'])
        engine = Engine(config, fd, c.ProcessProbe(), control)
        engine.connect(); engine.attach(config['request']['target'])
        result['main'] = engine.select_stopped_main()
        result.update(engine.load_submit(folder, config['experimentRequest']['image'], config['experimentRequest']['imageUUID']))
        result['status'] = 'submitted'
    except BaseException as error:
        result['error'] = repr(error)
    finally:
        closed = True
        if engine:
            closed = finish_engine(engine, result)
        else:
            result['debuggerClosed'] = True
        c.write_json(folder / 'debugger-result.json', result)
        if not closed:
            # No further target commands or work-deadline extension. Retain the
            # actual engine/transport instead of destroying them on Python exit.
            # The bounded supervisor reports pending recovery and leaves custody.
            while True:
                signal.pause()
    return 0 if result['status'] == 'submitted' and result['detach'] == 'success' and 'cleanupError' not in result else 1


def supervise(request, folder, check):
    """Directly owns both children; no delegated descendants or process-group signals."""
    worker_runtime.verify(RUNTIME_PROOF)
    p.validate(request); folder = Path(folder)
    probe = c.ProcessProbe(); c.verify_target(probe, request['target'])
    admission = admit_fixture(request['target'])
    p.require(admission['bundleID'].startswith('local.mac-pilot.swiftui-probe.'), 'only owned probe is admitted')
    server_path, python_path, sdk = c.tools_for_xcode()
    p.require(str(python_path) == RUNTIME_PROOF['context']['pythonPath'], 'LLDB selection changed')
    server = child = left = right = reaper = None
    result = {'status': 'pending/uncertain', 'childrenReaped': False}
    try:
        check()
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        env = worker_runtime.worker_env()
        server = subprocess.Popen([str(server_path), '--fd', str(right.fileno())], pass_fds=(right.fileno(),),
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        right.close()
        identity = probe.identity(server.pid)
        p.require(identity['parent'] == os.getpid() and identity['path'] == str(server_path), 'debugserver ownership unknown')
        reaper = ServerReaper(server)
        token = os.urandom(16).hex(); env['MAC_CU_RESIDENT_WORKER'] = token
        config = {'request': {'schemaVersion': 1, 'target': request['target'], 'query': '', 'validationOnly': True},
                  'experimentRequest': request, 'admission': admission, 'server': identity, 'supervisor': os.getpid(),
                  'token': token, 'workerRuntime': RUNTIME_PROOF, 'pythonPath': str(python_path), 'sdkPath': str(sdk),
                  'deadline': p.monotonic() + BOOTSTRAP_SECONDS, 'evidenceDirectory': str(folder)}
        c.write_json(folder / 'worker.json', config)
        with (folder / 'debugger.log').open('w') as log:
            child = subprocess.Popen([sys.executable, '-I', str(HERE / 'debugger.py'), '--worker', str(folder), str(left.fileno())],
                pass_fds=(left.fileno(),), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            left.close()
            while child.poll() is None:
                check()
                if p.monotonic() >= config['deadline']:
                    raise TimeoutError('bootstrap pending/uncertain; no replay')
                time.sleep(.025)
        result.update(json.loads((folder / 'debugger-result.json').read_text()))
    except BaseException as error:
        result['supervisorError'] = repr(error)
    finally:
        try:
            for sock in (left, right):
                if sock is not None:
                    sock.close()
            # Only exact direct children. A stuck bootstrap gets bounded child cleanup,
            # never target Stop/interrupt/forced return/kill or an additional expression.
            if child and child.poll() is None:
                try:
                    child.wait(timeout=CHILD_GRACE_SECONDS)
                except subprocess.TimeoutExpired:
                    result['bootstrapTimeout'] = True
            # A worker may finish during the bounded grace; inspect its final receipt
            # before deciding whether either child is safe to reap.
            receipt = folder / 'debugger-result.json'
            if receipt.is_file():
                result.update(json.loads(receipt.read_text()))
        finally:
            if reaper is not None:
                result['serverReaper'] = reaper.finish()
        result['childrenCleanupStartedNS'] = p.monotonic_ns()
        closed = finish_children(child, server, result)
        result['childrenCleanupFinishedNS'] = p.monotonic_ns()
        result['recovery'] = (c.recovered(probe, request['target'], seconds=5) if closed else
                              {'verified': False, 'error': 'JIT/debugger custody retained; recovery requires separate review'})
        c.write_json(folder / 'bootstrap.json', result)
    p.require(result.get('status') == 'submitted' and result.get('detach') == 'success' and
              result['childrenReaped'] and result['recovery']['verified'] and not result.get('supervisorError') and
              not result.get('cleanupError') and not result.get('bootstrapTimeout') and
              not result.get('serverReaper', {}).get('error'),
              'bootstrap/load/submission/recovery uncertain; preserve fixture and claim')
    return result


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--check-worker-runtime':
        print(json.dumps(worker_runtime.isolated_report(sys.argv[2])))
        raise SystemExit(0)
    if len(sys.argv) != 4 or sys.argv[1] != '--worker':
        raise SystemExit(64)
    raise SystemExit(worker(Path(sys.argv[2]), int(sys.argv[3])))
