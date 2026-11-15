"""Production resident custody: exact image pin, copied bootstrap, detached native callback."""
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
RESOURCE = HERE
sys.path.insert(0, str(HERE))
import resident_protocol as p
import resident_support as support
spec = importlib.util.spec_from_file_location('resident_capture_support', RESOURCE / 'capture.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
BOOTSTRAP_SECONDS = 30
CHILD_GRACE_SECONDS = 10
REAP_SECONDS = 10


def submission(address, folder):
    p.scalar(address, 1); p.absolute(str(folder))
    # Only a verified exported symbol address and validated literal path are used.
    # The exported function synchronously copies all caller-owned bytes.
    return '(int)((int (*)(const char *))0x%x)(%s)' % (address, json.dumps(str(folder)))


def verify_resident_exports(target, lldb, image, image_uuid):
    # Match the complete reserved namespace, including unknown future ABI names.
    # This is symbol lookup only, never target code or a caller-supplied selector.
    exports = target.FindGlobalFunctions('mac_cu_resident_', 16, lldb.eMatchTypeStartsWith)
    p.require(exports.GetSize() <= 1, 'duplicate/unknown resident exports; target restart required')
    if exports.GetSize():
        context = exports.GetContextAtIndex(0)
        name = context.GetFunction().GetName() or context.GetSymbol().GetName()
        module = context.GetModule()
        p.require(name == 'mac_cu_resident_submit_v2' and
                  (module.GetUUIDString() or '').upper() == image_uuid.upper() and
                  Path(str(module.GetFileSpec())).resolve() == Path(image),
                  'unknown resident ABI/image; no second load; target restart required')


def resident_entry(module, lldb):
    # SBModule.FindSymbols returns all exact-name matches, including non-code
    # symbols. Do not filter by Code before checking ambiguity.
    matches = module.FindSymbols('mac_cu_resident_submit_v2', lldb.eSymbolTypeAny)
    p.require(matches.GetSize() == 1, 'fixed exported entry is ambiguous')
    symbol = matches.GetContextAtIndex(0).GetSymbol()
    p.require(symbol.GetName() == 'mac_cu_resident_submit_v2' and
              symbol.GetType() == lldb.eSymbolTypeCode, 'fixed exported entry is ambiguous')
    return symbol


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
        verify_resident_exports(self.target, self.lldb, image, image_uuid)
        prior = [self.target.GetModuleAtIndex(i) for i in range(self.target.GetNumModules())
                 if 'mac-cu-resident' in str(self.target.GetModuleAtIndex(i).GetFileSpec())
                 or (self.target.GetModuleAtIndex(i).GetUUIDString() or '').upper() == image_uuid.upper()]
        existing_symbols = self.target.FindFunctions('mac_cu_resident_submit_v2').GetSize()
        legacy_symbols = self.target.FindFunctions('mac_cu_resident_submit').GetSize()
        p.require(not legacy_symbols and len(prior) <= 1, 'unknown/duplicate resident image; target restart required')
        token = None
        if prior or existing_symbols:
            p.require(len(prior) == 1 and existing_symbols > 0 and
                      (prior[0].GetUUIDString() or '').upper() == image_uuid.upper() and
                      Path(str(prior[0].GetFileSpec())).resolve() == Path(image),
                      'resident version/path conflict; no reload/unload; target restart required')
        else:
            error = self.lldb.SBError()
            c.write_json(folder / 'load-attempt.json', {'image': image, 'uuid': image_uuid, 'monotonicNS': p.monotonic_ns()})
            self.active_call = 'load'
            token = self.process.LoadImage(self.lldb.SBFileSpec(image), error)
            p.require(error.Success() and token != self.lldb.LLDB_INVALID_IMAGE_TOKEN, 'LoadImage unsupported/uncertain: ' + str(error))
            p.require(self.process.GetState() == self.lldb.eStateStopped, 'LoadImage did not return stopped')
            self.active_call = None
        modules = [self.target.GetModuleAtIndex(i) for i in range(self.target.GetNumModules())
                   if (self.target.GetModuleAtIndex(i).GetUUIDString() or '').upper() == image_uuid.upper()]
        p.require(len(modules) == 1, 'loaded helper UUID is not unique')
        module = modules[0]
        p.require(Path(str(module.GetFileSpec())).resolve() == Path(image), 'loaded helper path differs')
        address = resident_entry(module, self.lldb).GetStartAddress().GetLoadAddress(self.target)
        text = module.FindSection('__TEXT').FindSubSection('__text')
        lower = text.GetLoadAddress(self.target); upper = lower + text.GetByteSize()
        p.require(text.IsValid() and lower <= address < upper, 'entry not inside helper text')
        image_evidence = {'loadToken': token, 'uuid': image_uuid, 'path': image, 'loadCount': 0 if prior else 1, 'residentImages': 1, 'reused': bool(prior), 'abi': 2,
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


def bootstrap_control(folder, deadline):
    p.require(p.monotonic() < deadline, 'bootstrap deadline exceeded')
    p.require(not (folder / 'cancel').exists(), 'bootstrap cancelled before submission')


def worker(folder, fd):
    config = json.loads((folder / 'worker.json').read_text())
    p.require(os.getppid() == config['supervisor'] and os.environ.get('MAC_CU_RESIDENT_WORKER') == config['token'],
              'worker parent/token mismatch')
    signal.signal(signal.SIGTERM, lambda *_: None) # bounded parent owns child; no target interrupts
    signal.signal(signal.SIGINT, lambda *_: None)
    result = {'status': 'pending/uncertain', 'detach': 'not attempted'}
    engine = None
    def control():
        bootstrap_control(folder, config['deadline'])
    try:
        c.request_contract(config['request'])
        build = support.manifest()
        p.require(support.sha(config["image"]) == build["sha256"], "staged resident hash changed")
        support.run(["/usr/bin/codesign", "--verify", "--strict", config["image"]])
        c.verify_target(c.ProcessProbe(), config['request']['target'])
        engine = Engine(config, fd, c.ProcessProbe(), control)
        engine.connect(); engine.attach(config['request']['target'])
        result['main'] = engine.select_stopped_main()
        result.update(engine.load_submit(folder, config['image'], config['imageUUID']))
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


def supervise(request, wire, folder, probe, cancelled, revoke):
    """Own direct debugger children and retain them if JIT completion is ambiguous."""
    folder = Path(folder)
    result = {**c.edit_backend.receipt(request, 'failed', 'notDispatched'),
              'target': request['target'], 'validationOnly': request['validationOnly'],
              'captureID': wire['newCaptureID'] if request['kind'] == 'capture' else request['captureID'],
              'evidenceDirectory': str(folder), 'verified': False, 'overlayEnabled': False}
    server = child = left = right = None
    bootstrap = {'status': 'pending/uncertain', 'childrenReaped': False}
    channel = digest = None; revoked = False; dispatched = False
    deadline = p.monotonic() + c.WORK_SECONDS
    def cancel_authority(reason):
        nonlocal revoked
        if revoked:
            return
        revoke()  # durable host quarantine precedes the best-effort target marker
        revoked = True
        c.write_json(folder / 'authority.json', {'authority': 'revoked', 'reason': reason,
                     'operationID': request['operationID'], 'monotonicNS': p.monotonic_ns()})
        if channel and digest:
            p.write(channel, 'cancel', digest.encode())
    def check():
        if cancelled() or (folder / 'cancel').exists():
            cancel_authority('cancelled')
        if p.monotonic() >= deadline:
            cancel_authority('deadline')
    try:
        c.verify_target(probe, request['target'])
        admission = support.admit(request)
        c.write_json(folder / 'admission.json', admission)
        check()
        p.require(not revoked, 'cancelled before dispatch')
        image, channel = support.stage(wire, admission)
        raw, digest = p.encode(wire, str(image), admission['build']['uuid'])
        p.write(channel, 'request.bin', raw)
        c.write_json(folder / 'channel.json', {'path': str(channel), 'image': str(image), 'transportDigest': digest})
        c.write_json(folder / 'wire.json', wire)
        server_path, python_path, sdk = c.tools_for_xcode()
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'PYTHON', 'MAC_CU_'))}
        server = subprocess.Popen([str(server_path), '--fd', str(right.fileno())], pass_fds=(right.fileno(),),
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        right.close()
        identity = probe.identity(server.pid)
        p.require(identity['parent'] == os.getpid() and identity['path'] == str(server_path), 'debugserver ownership unknown')
        token = os.urandom(16).hex(); env['MAC_CU_RESIDENT_WORKER'] = token
        config = {'request': request, 'server': identity, 'supervisor': os.getpid(), 'token': token,
                  'image': str(image), 'imageUUID': admission['build']['uuid'], 'admission': admission,
                  'pythonPath': str(python_path), 'sdkPath': str(sdk),
                  'deadline': min(deadline, p.monotonic() + BOOTSTRAP_SECONDS), 'evidenceDirectory': str(channel)}
        c.write_json(channel / 'worker.json', config)
        dispatched = True
        with (folder / 'debugger.log').open('w') as log:
            child = subprocess.Popen([sys.executable, '-I', str(HERE / 'resident_transport.py'), '--worker', str(channel), str(left.fileno())],
                pass_fds=(left.fileno(),), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            left.close()
            while child.poll() is None:
                check()
                if p.monotonic() >= config['deadline']:
                    raise TimeoutError('bootstrap pending/uncertain; no replay')
                time.sleep(.025)
        bootstrap.update(c.read_json(channel / 'debugger-result.json'))
    except BaseException as error:
        result.update(status='failed', message=str(error))
    finally:
        for sock in (left, right):
            if sock is not None:
                sock.close()
        if child and child.poll() is None:
            try:
                child.wait(timeout=CHILD_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                bootstrap['bootstrapTimeout'] = True
        if channel and (channel / 'debugger-result.json').is_file():
            bootstrap.update(c.read_json(channel / 'debugger-result.json'))
        closed = finish_children(child, server, bootstrap)
        bootstrap['recovery'] = c.recovered(probe, request['target']) if closed else {'verified': False, 'error': 'JIT/debugger custody retained'}
        result['cleanup'] = {**bootstrap, 'detach': bootstrap.get('detach', 'not attempted')}
        c.write_json(folder / 'bootstrap.json', bootstrap)
    try:
        if bootstrap.get('status') != 'submitted' or bootstrap.get('detach') != 'success' or not bootstrap.get('childrenReaped') or not bootstrap['recovery']['verified']:
            if dispatched and not (channel / 'load-attempt.json').exists() and not (channel / 'submission-attempt.json').exists() and bootstrap.get('debuggerClosed') and bootstrap.get('childrenReaped') and bootstrap['recovery']['verified']:
                result.update(status='unsupported', reasonCode='unsupportedMainEntry', message=bootstrap.get('error', 'unsupported main entry'), mutationOutcome='notEntered', needsRefresh=True)
            elif dispatched:
                result.update(status='cleanupFailed', mutationOutcome='uncertain', needsRefresh=True, reasonCode='bootstrapUncertain')
                cancel_authority('bootstrap uncertain')
            return result
        # Debugger custody is closed. Target callback now owns its ordinary main-queue
        # execution; cancellation never interrupts/unwinds it. Cleanup reserve is separate.
        terminal_deadline = deadline + 30
        terminal = None
        while p.monotonic() < terminal_deadline:
            check()
            if (channel / 'terminal.json').exists():
                terminal = json.loads(p.read(channel, 'terminal.json'))
                break
            time.sleep(.025)
        if terminal is None:
            cancel_authority('native callback pending')
            result.update(status='outcomeUncertain', mutationOutcome='uncertain', needsRefresh=True,
                          reasonCode='callbackPending', targetCallbackPending=True)
            return result
        pinned = bootstrap['image']
        p.require(terminal.get('abi') == 2 and terminal.get('operationID') == request['operationID']
                  and terminal.get('requestDigest') == digest and terminal.get('poolExited') is True
                  and terminal.get('operationContexts') == 0 and terminal.get('mainThread') is True
                  and terminal.get('traced') == 0 and terminal.get('imageUUID') == pinned['uuid']
                  and pinned['textStart'] <= terminal['callbackPC'] < pinned['textEnd']
                  and terminal['callbackNS'] <= terminal['workFinishedNS'] <= terminal['poolExitedNS'] <= terminal['publicationNS']
                  and terminal.get('answerPublished') is True, 'native terminal identity/lifetime proof failed')
        payload = c.edit_backend.validate_payload(json.loads(p.read(channel, 'answer.json', limit=16777216)), wire)
        result.update(payload, resident=terminal)
        if revoked:
            result.update(status='cancelled', needsRefresh=True, authorityRevoked=True)
            result.pop('editing', None); result.pop('editableNodes', None)
        result['cleanup']['recovery'] = c.recovered(probe, request['target'])
        if not result['cleanup']['recovery']['verified']:
            result.update(status='cleanupFailed', needsRefresh=True)
        return result
    except BaseException as error:
        cancel_authority('receipt uncertainty')
        result.update(status='outcomeUncertain', mutationOutcome='uncertain', needsRefresh=True,
                      reasonCode='nativeReceiptUnverified', message=str(error))
        return result
    finally:
        if channel:
            # Copy only fixed owned evidence, never remove a pinned live image or
            # discard custody. Exact fixture cleanup owns its data lifecycle.
            import shutil
            for name in (*p.NAMES, 'main-thread-entry.json', 'loaded-image.json', 'load-attempt.json',
                         'submission-attempt.json', 'debugger-result.json', 'worker.json'):
                path = channel / name
                if path.is_file() and not path.is_symlink():
                    shutil.copyfile(path, folder / ('resident-' + name))


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != '--worker':
        raise SystemExit(64)
    raise SystemExit(worker(Path(sys.argv[2]), int(sys.argv[3])))
