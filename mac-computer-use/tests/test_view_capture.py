"""Production orchestration tests. No debugger connection, target attach or GUI is used."""
import copy
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import socket
import threading
from types import SimpleNamespace
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
RESOURCE = Path(__file__).resolve().parents[1] / 'skills/mac-computer-use/scripts/view-capture'
spec = importlib.util.spec_from_file_location('view_capture', RESOURCE / 'capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
DEVICE = '00000000-0000-0000-0000-000000000001'


class Probe:
    def __init__(self, target):
        self.target = {**target, 'state': 2, 'traced': False, 'parent': 100}
        self.server = {'pid': 200, 'start': [5, 1], 'path': '/owned/debugserver', 'parent': os.getpid()}

    def identity(self, pid, device=False):
        return copy.deepcopy(self.target if device else self.server)


class Engine:
    def __init__(self, probe, control, events, mode):
        self.probe, self.control, self.events, self.mode = probe, control, events, mode

    def connect(self):
        self.events.append('connect')
        if self.mode == 'racing-debugger':
            self.probe.target['traced'] = True

    def attach(self, target):
        self.events.append('attach')
        self.probe.target.update(state=4, traced=True)
        if self.mode == 'attach-error':
            raise RuntimeError('remote attach partially failed')

    def select_main(self):
        self.events.append('main')
        if self.mode == 'no-main':
            capture.fail('unsupported', 'No unique main queue')

    def collect(self, answer):
        self.events.append('collect')
        if self.mode == 'expression-error':
            capture.fail('expressionError', 'Runtime selector absent')
        if self.mode == 'cancel':
            (answer.parent / 'cancel').touch()
            self.control()
        if self.mode == 'timeout':
            capture.fail('timeout', 'Expression deadline')
        return {'captureTime': '2026-11-09T00:00:00Z', 'hierarchy': {'topLevelGroups': {}},
                'geometry': {'verified': False, 'overlayEnabled': False}}

    def detach(self):
        self.events.append('detach')
        if 'attach' not in self.events:
            return 'not attached'
        if self.mode == 'bad-detach':
            return 'detach failed'
        self.probe.target.update(state=2, traced=False)
        return 'success'

    def close(self):
        self.events.append('close')


class Child:
    def __init__(self, pid, folder, mode):
        self.pid, self.folder, self.mode = pid, folder, mode
        self.returncode = None
        self.signals = []

    def poll(self):
        if self.pid == 201 and self.mode == 'success' and self.returncode is None:
            capture.write_json(self.folder / 'engine.json', {'status': 'success', 'detach': 'success',
                                                           'hierarchy': {}, 'geometry': {}})
            self.returncode = 0
        return self.returncode

    def wait(self, timeout):
        if self.pid == 201 and self.mode == 'receipt-then-hung' and not self.signals:
            capture.write_json(self.folder / 'engine.json', {'status': 'success', 'detach': 'success', 'cleanup': {}})
            raise subprocess.TimeoutExpired('owned worker after receipt', timeout)
        if self.pid == 201 and self.mode == 'hung' and not self.signals:
            raise subprocess.TimeoutExpired('owned worker', timeout)
        if self.pid == 201 and self.mode == 'cancel-cleanup-failed' and not self.signals:
            capture.write_json(self.folder / 'engine.json', {'status': 'cleanupFailed', 'detach': 'detach failed',
                               'message': 'Debugger detach/recovery did not complete cleanly',
                               'hierarchy': None, 'geometry': None})
        self.returncode = 0
        return self.returncode

    def terminate(self):
        self.signals.append('terminate')

    def kill(self):
        self.signals.append('kill')


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='view-capture-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        app = self.folder / 'HierarchyFixture.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': capture.FIXTURE_BUNDLE,
                                                      'CFBundleExecutable': 'HierarchyFixture'}))
        self.target = {'pid': 42, 'start': [100, 123], 'path': str(app / 'HierarchyFixture'), 'deviceID': DEVICE}
        self.request = {'schemaVersion': 1, 'target': self.target, 'query': '', 'validationOnly': True}
        self.probe = Probe(self.target)
        self.events = []

    def engine(self, mode='success'):
        config = {'request': self.request, 'deadline': capture.monotonic() + 20}
        return capture.run_engine(config, self.folder,
                                  lambda control: Engine(self.probe, control, self.events, mode), self.probe)

    def test_contract_rejects_command_injection_and_unknown_fields(self):
        for target in ({**self.target, 'pid': True}, {**self.target, 'start': [1]},
                       {**self.target, 'deviceID': 'x; lldb'}, {**self.target, 'path': '/x\0y'}):
            with self.assertRaises(capture.CaptureError):
                capture.request_contract({**self.request, 'target': target})
        for update in ({'lldbCommand': 'attach'}, {'query': 'x' * 1025}, {'validationOnly': 1}):
            with self.assertRaises(capture.CaptureError):
                capture.request_contract({**self.request, **update})
        # Query is only a text-rendering filter and never becomes executable source.
        self.request['query'] = '"; system("bad");'
        self.assertEqual(capture.request_contract(self.request)['query'], self.request['query'])
        expr = capture.collection_expression(self.folder / 'answer "quoted".json')
        self.assertNotIn(self.request['query'], expr)
        self.assertNotIn('__ANSWER_PATH__', expr)

    def test_fixture_texture_gate_and_request_delta(self):
        for enabled in (False, True):
            request = {**self.request, 'validationTextureProbe': enabled}
            capture.request_contract(request)
            capture.validation_policy(request)
        for invalid in (1, None, 'true', [], {}):
            with self.subTest(invalid=invalid), self.assertRaises(capture.CaptureError):
                capture.request_contract({**self.request, 'validationTextureProbe': invalid})
        for enabled in (True, False):
            with self.assertRaises(capture.CaptureError):
                capture.request_contract({**self.request, 'validationOnly': False, 'validationTextureProbe': enabled})
        other = self.folder / 'Other.app'; other.mkdir()
        (other / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'other', 'CFBundleExecutable': 'HierarchyFixture'}))
        request = {**self.request, 'target': {**self.target, 'path': str(other / 'HierarchyFixture')}, 'validationTextureProbe': True}
        with self.assertRaises(capture.CaptureError):
            capture.validation_policy(capture.request_contract(request))
        with patch.object(capture.uuid, 'uuid4', return_value='fixed-id'):
            baseline = capture.hierarchy_request()
            disabled = capture.hierarchy_request(False)
            enabled = capture.hierarchy_request(True)
        expected = {'DBGHierarchyRequestIdentifier': 'fixed-id', 'DBGHierarchyRequestInitiatorVersionKey': 4,
            'DBGHierarchyRequestPriority': 0, 'DBGHierarchyRequestTransportCompression': False,
            'DBGHierarchyObjectDiscovery': 1, 'DBGHierarchyRequestActions': [{
                'actionClass': 'DebugHierarchyPropertyAction', 'visibility': 1, 'propertyNamesAreExclusive': False,
                'propertyNames': ['frame', 'bounds', 'center', 'transform', 'clipsToBounds', 'hidden', 'alpha',
                    'accessibilityIdentifier', 'accessibilityLabel', 'text', 'firstItem', 'firstAttribute',
                    'relation', 'secondItem', 'secondAttribute', 'multiplier', 'constant', 'priority', 'active', 'identifier']}]}
        self.assertEqual(json.dumps(baseline).encode(), json.dumps(expected).encode())
        self.assertEqual(json.dumps(disabled).encode(), json.dumps(expected).encode())
        self.assertEqual(enabled['DBGHierarchyRequestActions'][0]['propertyNames'].pop(), 'snapshotImage')
        self.assertEqual(enabled, baseline)

    def test_texture_expression_records_exact_wire_request(self):
        wire_path = self.folder / 'hierarchy-request.json'
        expression = capture.collection_expression(self.folder / 'answer.json', True, wire_path)
        import re
        encoded = re.search(r'performRequestWithRequestInBase64:@"([^"]+)"', expression).group(1)
        self.assertEqual(base64.b64decode(encoded), wire_path.read_bytes())
        self.assertEqual(json.loads(wire_path.read_bytes())['DBGHierarchyRequestActions'][0]['propertyNames'][-1], 'snapshotImage')

    def test_real_collect_forwards_texture_and_requires_raw_response(self):
        engine = capture.LLDBEngine.__new__(capture.LLDBEngine)
        engine.config = {'request': {**self.request, 'validationTextureProbe': True}}
        seen = []
        def evaluate(source):
            seen.append(source)
            if 'performRequestWithRequestInBase64' in source:
                capture.write_json(self.folder / 'answer.json', {'hierarchy': {'topLevelGroups': {}},
                    'geometry': {}, 'captureTime': 'now'})
                capture.write_json(self.folder / 'hierarchy-response.json', {'topLevelGroups': {}})
            return SimpleNamespace(GetValueAsUnsigned=lambda: 1)
        engine.evaluate = evaluate
        self.assertEqual(engine.collect(self.folder / 'answer.json')['hierarchy'], {'topLevelGroups': {}})
        import re
        wire = base64.b64decode(re.search(r'performRequestWithRequestInBase64:@"([^"]+)"', seen[1]).group(1))
        self.assertEqual(wire, (self.folder / 'hierarchy-request.json').read_bytes())
        self.assertEqual(json.loads(wire)['DBGHierarchyRequestActions'][0]['propertyNames'][-1], 'snapshotImage')

    def test_success_detaches_before_close_and_recovers(self):
        result = self.engine()
        self.assertEqual(result['status'], 'success')
        self.assertEqual(self.events, ['connect', 'attach', 'main', 'collect', 'detach', 'close'])
        self.assertTrue(result['recovery']['verified'])
        self.assertFalse(result['geometry']['verified'])

    def test_expression_error_timeout_cancel_and_unsupported_share_cleanup(self):
        for mode, status in [('expression-error', 'expressionError'), ('timeout', 'timeout'),
                             ('cancel', 'cancelled'), ('no-main', 'unsupported'), ('attach-error', 'failed')]:
            with self.subTest(mode=mode):
                self.events.clear()
                (self.folder / 'cancel').unlink(missing_ok=True)
                result = self.engine(mode)
                self.assertEqual(result['status'], status)
                self.assertEqual(self.events[-2:], ['detach', 'close'])
                self.assertIsNone(result['hierarchy'])
                self.assertTrue(result['recovery']['verified'])

    def test_paused_traced_reused_unknown_device_fail_before_engine(self):
        for mutation in ({'state': 4}, {'traced': True}, {'start': [101, 0]}, {'deviceID': 'other'}, {'path': '/other'}):
            with self.subTest(mutation=mutation):
                self.probe.target = {**self.target, 'state': 2, 'traced': False, **mutation}
                # Failures remain unverified; shorten only the observation window in this test.
                original = capture.recovered
                with patch.object(capture, 'recovered', side_effect=lambda p, t: original(p, t, seconds=0)):
                    result = self.engine()
                self.assertNotEqual(result['status'], 'success')
                self.assertEqual(self.events, [])

    def test_debugger_race_between_connect_and_attach_is_rejected(self):
        original = capture.recovered
        with patch.object(capture, 'recovered', side_effect=lambda p, t: original(p, t, seconds=0)):
            result = self.engine('racing-debugger')
        self.assertNotIn('attach', self.events)
        self.assertEqual(result['status'], 'targetUnavailable')
        self.assertTrue(self.probe.target['traced'], 'Another debugger must be left alone')

    def test_failed_detach_does_not_publish_hierarchy(self):
        original = capture.recovered
        with patch.object(capture, 'recovered', side_effect=lambda p, t: original(p, t, seconds=0)):
            result = self.engine('bad-detach')
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertFalse(result['recovery']['verified'])
        self.assertIsNone(result['hierarchy'])

    def test_ordinary_capture_policy_never_creates_engine(self):
        self.request['validationOnly'] = False
        self.assertEqual(self.engine()['status'], 'unavailable')
        self.assertEqual(self.events, [])

    def test_general_admission_checks_signed_debug_entitlement_without_bypass(self):
        def signed(entitlements, status=0):
            def run(argv, **kwargs):
                self.assertEqual(argv[:4], ['/usr/bin/codesign', '-d', '--entitlements', '-'])
                self.assertEqual(argv[4], self.target['path'])
                self.assertEqual(kwargs['timeout'], 3)
                return SimpleNamespace(returncode=status, stdout=plistlib.dumps(entitlements))
            return run
        self.assertEqual(capture.admit_debuggable_app(self.target, signed({'get-task-allow': True}))['bundleID'], capture.FIXTURE_BUNDLE)
        for entitlement in ({}, {'get-task-allow': False}, {'get-task-allow': 1}, {'get-task-allow': 'true'}):
            with self.assertRaises(capture.CaptureError):
                capture.admit_debuggable_app(self.target, signed(entitlement))
        with self.assertRaises(capture.CaptureError):
            capture.admit_debuggable_app(self.target, signed({'get-task-allow': True}, 1))
        request = {**self.request, 'validationOnly': False, 'qualificationBypass': True}
        with self.assertRaises(capture.CaptureError):
            capture.request_contract(request)

    def test_texture_preflight_precedes_any_image_request(self):
        expression = capture.collection_expression(self.folder / 'answer.json', True)
        self.assertNotIn('__TEXTURE_PREFLIGHT__', expression)
        self.assertLess(expression.index('while ([pending count] > 0)'), expression.index('performRequestWithRequestInBase64:'))
        self.assertIn('bounded && (!YES || texturePreflight)', expression)
        self.assertIn('[nodes count] >= 64', expression)
        self.assertIn('134217728ULL - estimatedImageBytes', expression)

    def supervisor(self, mode='success', cancelled=lambda: False, bad_server=False, spawn_error=False):
        children, commands = [], []
        if bad_server:
            self.probe.server['path'] = '/wrong/server'

        def popen(argv, **kwargs):
            commands.append(argv)
            self.assertEqual(len(kwargs['pass_fds']), 1)
            self.assertNotIn('shell', kwargs)
            if spawn_error and children:
                raise OSError('worker spawn failed')
            child = Child(200 + len(children), self.folder, mode)
            children.append(child)
            return child
        result = capture.supervise(self.request, self.folder, self.probe, cancelled, popen=popen,
                                   discover=lambda: (Path('/owned/debugserver'), Path('/owned/Python'), Path('/owned/Simulator.sdk')))
        self.assertTrue(result['cleanup']['childrenReaped'])
        self.assertLessEqual(len(children), 2)
        self.assertTrue(all(c.returncode is not None for c in children))
        self.assertTrue(all(str(self.target['pid']) not in argv for argv in commands))
        return result, children

    def test_supervisor_reaps_success_and_spawn_ownership_failures(self):
        self.assertEqual(self.supervisor()[0]['status'], 'success')
        for name in ('worker.json', 'engine.json'):
            (self.folder / name).unlink(missing_ok=True)
        result, children = self.supervisor(spawn_error=True)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(children[0].signals, ['terminate'])
        (self.folder / 'worker.json').unlink(missing_ok=True)
        result, children = self.supervisor(bad_server=True)
        self.assertEqual(result['status'], 'ownershipFailed')
        self.assertEqual(len(children), 1)

    def test_supervisor_cancel_and_hung_worker_reap_only_own_children(self):
        calls = iter([False, True, True])
        result, children = self.supervisor(mode='hung', cancelled=lambda: next(calls, True))
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertEqual(result['interruptionReason'], 'cancelled')
        self.assertTrue((self.folder / 'cancel').is_file())
        self.assertTrue(result['cleanup']['workerDeadlineExceeded'])
        self.assertEqual(children[1].signals, ['terminate'])
        self.assertEqual(children[0].signals, ['terminate'])

    def test_worker_receipt_does_not_erase_supervisor_cleanup_deadline(self):
        calls = iter([False, True, True])
        result, _ = self.supervisor(mode='receipt-then-hung', cancelled=lambda: next(calls, True))
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertTrue(result['cleanup']['workerDeadlineExceeded'])

    def test_cancel_does_not_hide_worker_cleanup_failure(self):
        calls = iter([False, True, True])
        result, _ = self.supervisor(mode='cancel-cleanup-failed', cancelled=lambda: next(calls, True))
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertEqual(result['interruptionReason'], 'cancelled')
        self.assertEqual(result['detach'], 'detach failed')

    def test_supervisor_deadline_is_distinct_from_cancel_and_reaps_children(self):
        with patch.object(capture, 'WORK_SECONDS', -1):
            result, children = self.supervisor(mode='hung')
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertEqual(result['interruptionReason'], 'timeout')
        self.assertTrue(result['cleanup']['childrenReaped'])

    def test_real_engine_observes_connect_and_terminal_events(self):
        event_state = [10]
        fake = SimpleNamespace(eStateExited=3, eStateDetached=4, eStateCrashed=5, eStateUnloaded=6,
                               SBEvent=lambda: object(), SBProcess=SimpleNamespace(
                                   EventIsProcessEvent=lambda event: True, GetStateFromEvent=lambda event: event_state[0]))
        engine = capture.LLDBEngine.__new__(capture.LLDBEngine)
        engine.lldb = fake
        engine.config = {'deadline': capture.monotonic() + 1}
        engine.control = lambda: None
        engine.process = SimpleNamespace(GetState=lambda: 9)
        engine.listener = SimpleNamespace(WaitForEvent=lambda seconds, event: True)
        engine.wait_state(10)
        event_state[0] = fake.eStateDetached
        with self.assertRaises(capture.CaptureError):
            engine.wait_state(10)

    def test_size_and_private_resource_guards(self):
        huge = self.folder / 'huge.json'
        with huge.open('wb') as stream:
            stream.truncate(capture.MAX_BYTES + 1)
        with self.assertRaises(capture.CaptureError):
            capture.read_json(huge)
        self.folder.chmod(0o755)
        with self.assertRaises(capture.CaptureError):
            capture.private_folder(self.folder)
        self.folder.chmod(0o700)
        self.assertGreater(capture.CLEANUP_SECONDS, capture.WORKER_GRACE + 2 * 10 + 5)

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin process identity')
    def test_real_readonly_process_probe_and_exact_direct_child_reaping(self):
        env = {**os.environ, 'SIMULATOR_UDID': DEVICE}
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], env=env)
        try:
            probe = capture.ProcessProbe()
            # exec must finish before procargs2 exposes the Python environment.
            until = time.monotonic() + 2
            while True:
                try:
                    info = probe.identity(child.pid, device=True)
                    break
                except capture.CaptureError:
                    if time.monotonic() >= until:
                        raise
                    time.sleep(.01)
            self.assertEqual(info['deviceID'], DEVICE)
            self.assertEqual(info['parent'], os.getpid())
            self.assertFalse(info['traced'])
            self.assertEqual(info['path'], os.path.realpath(sys.executable))
            capture.stop_child(child)
            self.assertIsNotNone(child.returncode)
            self.assertIsNone(unrelated.poll())
        finally:
            capture.stop_child(child)
            capture.stop_child(unrelated)

    def test_real_engine_transport_main_thread_expression_and_interrupt_contract(self):
        # Fake only the LLDB API, not the production engine/state machine or FD boundary.
        for cancelled in (False, True):
            with self.subTest(cancelled=cancelled):
                (self.folder / 'cancel').unlink(missing_ok=True)
                self.events.clear()
                left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
                fd = left.detach()
                self.addCleanup(right.close)
                interrupted = threading.Event()
                options_seen = []
                owner = self

                class Error:
                    def Fail(self): return False
                    def Success(self): return True

                class Value:
                    def GetValueAsUnsigned(self): return 1
                    def GetError(self): return Error()

                class Options:
                    def __init__(self): self.values = {}
                    def __getattr__(self, name):
                        return lambda value: self.values.update({name: value})

                class Frame:
                    def IsValid(self): return True
                    def GetFunctionName(self): return 'readonly-test-frame'
                    def GetModule(self):
                        return SimpleNamespace(GetFileSpec=lambda: SimpleNamespace(GetDirectory=lambda: '/test', GetFilename=lambda: 'fixture'))
                    def EvaluateExpression(self, source, options):
                        options_seen.append(options.values)
                        if 'writeToFile:' in source:
                            if cancelled:
                                (owner.folder / 'cancel').touch()
                                owner.assertTrue(interrupted.wait(2), 'Interrupt must be requested during evaluation')
                            else:
                                capture.write_json(owner.folder / 'answer.json', {
                                    'hierarchy': {'topLevelGroups': {}}, 'geometry': {'verified': False},
                                    'captureTime': '2026-11-09T00:00:00Z'})
                        return Value()

                thread = SimpleNamespace(GetQueueName=lambda: 'com.apple.main-thread', GetThreadID=lambda: 7,
                                         GetNumFrames=lambda: 1,
                                         GetFrameAtIndex=lambda i: Frame())

                class Remote:
                    state = 1
                    def IsValid(self): return True
                    def GetState(self): return self.state
                    def GetProcessID(self): return owner.target['pid']
                    def GetTarget(self): return None
                    def GetNumThreads(self): return 1
                    def GetThreadAtIndex(self, index): return thread
                    def SetSelectedThread(self, selected): owner.assertIs(selected, thread)
                    def RemoteAttachToProcessWithID(self, pid, error):
                        owner.events.append('remote-attach')
                        owner.assertEqual(pid, owner.target['pid'])
                        self.state = 2
                        owner.probe.target.update(state=4, traced=True)
                        return True
                    def SendAsyncInterrupt(self): interrupted.set()
                    def Detach(self, stopped):
                        owner.assertFalse(stopped)
                        owner.events.append('detach')
                        self.state = 4
                        owner.probe.target.update(state=2, traced=False)
                        return Error()
                remote = Remote()

                def connect(listener, url, plugin, error):
                    self.assertEqual(url, 'fd://' + str(fd))
                    self.assertEqual(plugin, 'gdb-remote')
                    self.assertNotIn('remote-attach', self.events)
                    self.events.append('connect')
                    return remote
                debugger = SimpleNamespace(CreateTarget=lambda name: SimpleNamespace(ConnectRemote=connect))
                fake = SimpleNamespace(SBError=Error, SBListener=lambda name: object(), SBExpressionOptions=Options,
                    SBDebugger=SimpleNamespace(Destroy=lambda d: self.events.append('destroy')),
                    eStateConnected=1, eStateStopped=2, eStateExited=3, eStateDetached=4, eStateCrashed=5,
                    eStateUnloaded=6, eLanguageTypeObjC_plus_plus=9, eErrorTypeExpression=7, eExpressionTimedOut=6)
                config = {'request': self.request, 'deadline': capture.monotonic() + 10,
                          'server': self.probe.server, 'supervisor': os.getpid(), 'sdkPath': '/owned/Simulator.sdk'}

                def factory(control):
                    engine = capture.LLDBEngine.__new__(capture.LLDBEngine)
                    engine.lldb, engine.config, engine.fd = fake, config, fd
                    engine.probe, engine.control, engine.debugger = self.probe, control, debugger
                    engine.process = engine.frame = engine.interrupt_thread = None
                    engine.attach_requested = False
                    return engine
                with patch.object(capture.os, 'getppid', return_value=os.getpid()), \
                     patch.object(capture, 'configure_target', return_value=(SimpleNamespace(ConnectRemote=connect), {})), \
                     patch.object(capture, 'compiler_context', return_value={}), \
                     patch.object(capture, 'import_target_modules', return_value={}):
                    result = capture.run_engine(config, self.folder, factory, self.probe)
                self.assertEqual(result['status'], 'cancelled' if cancelled else 'success')
                self.assertEqual(result['mainThread']['id'], 7)
                self.assertEqual(self.events, ['connect', 'remote-attach', 'detach', 'destroy'])
                self.assertTrue(result['recovery']['verified'])
                self.assertEqual(len(options_seen), 3)
                for options in options_seen:
                    self.assertTrue(options['SetUnwindOnError'])
                    self.assertFalse(options['SetTryAllThreads'])
                    self.assertLessEqual(options['SetTimeoutInMicroSeconds'], 8000000)
                with self.assertRaises(OSError):
                    os.fstat(fd)  # The real engine releases its borrowed private descriptor.

    def test_other_platform_sdk_is_rejected_before_target_creation(self):
        sdk = self.folder / 'Other.sdk'; sdk.mkdir()
        (sdk / 'SDKSettings.json').write_text(json.dumps({'CanonicalName': 'macosx99', 'DefaultProperties': {'PLATFORM_NAME': 'macosx'}}))
        debugger = SimpleNamespace(CreateTarget=lambda *a: self.fail('target created for wrong SDK'))
        with self.assertRaises(capture.CaptureError):
            capture.configure_target(debugger, None, self.target['path'], sdk, lambda: None)

    def test_failed_module_import_is_not_reported_as_success(self):
        class Result:
            def Succeeded(self): return False
            def GetError(self): return 'Foundation unavailable'
        platform = SimpleNamespace(GetName=lambda: 'ios-simulator', SetSDKRoot=lambda _: None)
        target = SimpleNamespace(GetPlatform=lambda: platform, GetTriple=lambda: 'arm64-apple-ios17-simulator')
        debugger = SimpleNamespace(SetSelectedTarget=lambda _: None, GetInstanceName=lambda: 'isolated',
            SetInternalVariable=lambda *a: SimpleNamespace(Fail=lambda: False),
            GetCommandInterpreter=lambda: SimpleNamespace(HandleCommand=lambda *a: None))
        with self.assertRaisesRegex(capture.CaptureError, 'Target module import failed'):
            capture.import_target_modules(debugger, SimpleNamespace(SBCommandReturnObject=Result), target, '/selected.sdk', lambda: None)

    def test_missing_shared_clock_fails_before_starting_children(self):
        with patch.object(capture.time, 'clock_gettime', side_effect=OSError('clock unavailable')), \
             patch.object(subprocess, 'Popen', side_effect=AssertionError('child started without clock')):
            with self.assertRaisesRegex(OSError, 'clock unavailable'):
                capture.supervise(self.request, self.folder, self.probe, lambda: False)

    def test_actual_xcode_worker_expired_shared_deadline_never_constructs_engine(self):
        # Missing engine-only configuration prevents even LLDB import if the admission guard regresses.
        # The production worker CLI itself must reject this expired system-wide deadline first.
        sent = capture.monotonic()
        config = {'request': self.request, 'deadline': sent - 1, 'supervisor': os.getpid(),
                  'clock': 'CLOCK_MONOTONIC', 'sentMonotonic': sent}
        capture.write_json(self.folder / 'worker.json', config)
        env = {k: v for k, v in os.environ.items() if not k.startswith('MAC_CU_')}
        completed = subprocess.run(['/usr/bin/xcrun', 'python3', '-I', str(RESOURCE / 'capture.py'),
                                    '--worker', str(self.folder), '-1'], env=env, capture_output=True, timeout=8)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = capture.read_json(self.folder / 'engine.json')
        self.assertEqual(result['status'], 'timeout')
        self.assertEqual(result['detach'], 'not attempted')
        self.assertFalse(result['connected'] or result['attachRequested'])
        receipt = result['deadlineReceipt']
        self.assertEqual(receipt['deadlineMonotonic'], config['deadline'])
        self.assertGreaterEqual(receipt['receivedMonotonic'], sent - .001)
        self.assertLess(receipt['remainingAtReceiptSeconds'], -1)

    def test_cli_unknown_and_inherited_test_entry_rejected(self):
        for argv in (['--unknown'], ['--native-check'], ['--worker', str(self.folder), '0']):
            completed = subprocess.run([sys.executable, '-I', str(RESOURCE / 'capture.py'), *argv],
                                       env={**os.environ, 'MAC_CU_NATIVE_CHECK_CHILD': '1'},
                                       capture_output=True, timeout=5)
            self.assertNotEqual(completed.returncode, 0)


if __name__ == '__main__':
    unittest.main()
