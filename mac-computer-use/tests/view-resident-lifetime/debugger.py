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
import time

HERE = Path(__file__).resolve().parent
RESOURCE = HERE.parent.parent / 'skills/mac-computer-use/scripts/view-capture'
sys.path.insert(0, str(HERE))
import protocol as p
spec = importlib.util.spec_from_file_location('resident_capture_support', RESOURCE / 'capture.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
BOOTSTRAP_SECONDS = 30
CHILD_GRACE_SECONDS = 10
REAP_SECONDS = 10


def admit_fixture(target):
    """Read the existing Simulator fixture signature; never alter app entitlements."""
    c.validation_policy({'validationOnly': True, 'target': target})
    executable = Path(target['path'])
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(executable.parent)],
                   check=True, timeout=5, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    signed = subprocess.run(['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-', str(executable)],
                            check=True, timeout=3, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.require(len(signed.stdout) <= 65536, 'signed entitlement response exceeds cap')
    entitlements = plistlib.loads(signed.stdout)
    p.require(entitlements.get('com.apple.security.get-task-allow') is True,
              'fixture lacks its original signed Simulator debug entitlement')
    return {'bundleID': c.FIXTURE_BUNDLE, 'signedDebugEntitlement': 'com.apple.security.get-task-allow',
            'targetResigned': False}


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
            frames.append({'function': f.GetFunctionName() or '', 'module': str(f.GetModule().GetFileSpec())})
        p.require(c.edit_backend.safe_entry(frames, self.config['request']['target']['path']), 'unsafe fixture idle stack')
        self.process.SetSelectedThread(thread); self.frame = thread.GetFrameAtIndex(0)
        p.require(self.frame.IsValid(), 'invalid main-thread frame')
        return {'threadID': thread.GetThreadID(), 'queue': thread.GetQueueName(), 'frames': frames}

    def load_submit(self, folder, image, image_uuid):
        self.control(); self.check_server()
        p.require(self.target.GetTriple().startswith('arm64-') and self.target.GetTriple().endswith('-simulator'),
                  'only compiled arm64 Simulator image supported')
        p.require(self.target.FindFunctions('mac_cu_resident_submit').GetSize() == 0, 'resident image already present; no reload')
        error = self.lldb.SBError()
        c.write_json(folder / 'load-attempt.json', {'image': image, 'uuid': image_uuid, 'monotonicNS': p.monotonic_ns()})
        self.active_call = 'load'
        token = self.process.LoadImage(self.lldb.SBFileSpec(image), error)
        p.require(error.Success() and token != self.lldb.LLDB_INVALID_IMAGE_TOKEN, 'LoadImage unsupported/uncertain: ' + str(error))
        # Token is retained as evidence only. This harness has no UnloadImage path.
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
        image_evidence = {'loadToken': token, 'uuid': image_uuid, 'path': image, 'loadCount': 1,
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


def worker(folder, fd):
    config = json.loads((folder / 'worker.json').read_text())
    p.require(os.getppid() == config['supervisor'] and os.environ.get('MAC_CU_RESIDENT_WORKER') == config['token'],
              'worker parent/token mismatch')
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
    p.validate(request); folder = Path(folder)
    probe = c.ProcessProbe(); c.verify_target(probe, request['target'])
    admission = admit_fixture(request['target'])
    p.require(admission['bundleID'] == c.FIXTURE_BUNDLE, 'only owned fixture is admitted')
    server_path, python_path, sdk = c.tools_for_xcode()
    server = child = left = right = None
    result = {'status': 'pending/uncertain', 'childrenReaped': False}
    try:
        check()
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'PYTHON', 'MAC_CU_'))}
        server = subprocess.Popen([str(server_path), '--fd', str(right.fileno())], pass_fds=(right.fileno(),),
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        right.close()
        identity = probe.identity(server.pid)
        p.require(identity['parent'] == os.getpid() and identity['path'] == str(server_path), 'debugserver ownership unknown')
        token = os.urandom(16).hex(); env['MAC_CU_RESIDENT_WORKER'] = token
        config = {'request': {'schemaVersion': 1, 'target': request['target'], 'query': '', 'validationOnly': True},
                  'experimentRequest': request, 'server': identity, 'supervisor': os.getpid(),
                  'token': token, 'pythonPath': str(python_path), 'sdkPath': str(sdk),
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
        closed = finish_children(child, server, result)
        result['recovery'] = (c.recovered(probe, request['target'], seconds=5) if closed else
                              {'verified': False, 'error': 'JIT/debugger custody retained; recovery requires separate review'})
        c.write_json(folder / 'bootstrap.json', result)
    p.require(result.get('status') == 'submitted' and result.get('detach') == 'success' and
              result['childrenReaped'] and result['recovery']['verified'] and not result.get('supervisorError') and
              not result.get('cleanupError') and not result.get('bootstrapTimeout'),
              'bootstrap/load/submission/recovery uncertain; preserve fixture and claim')
    return result


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != '--worker':
        raise SystemExit(64)
    raise SystemExit(worker(Path(sys.argv[2]), int(sys.argv[3])))
