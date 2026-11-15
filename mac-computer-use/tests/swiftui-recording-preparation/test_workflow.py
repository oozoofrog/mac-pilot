"""Synthetic transitions and an isolated invalid-request CLI; no guest operations."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'skills/mac-computer-use/scripts/view-capture'))
import recording_preparation as r

class IsolatedCLI(unittest.TestCase):
    def test_invalid_request_reaches_preparation_under_isolated_python(self):
        with tempfile.TemporaryDirectory(prefix='mac-cu-recording-cli-', dir='/private/tmp') as directory:
            folder = Path(directory)
            request = folder / 'request.json'
            request.write_text('{}')
            result = subprocess.run(
                [sys.executable, '-I', str(Path(r.__file__).with_name('capture.py')),
                 '--prepare-recording', str(request)],
                cwd=folder, env=dict(os.environ, HOME=str(folder)),
                capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertEqual(json.loads(result.stdout), {
                'status': 'failed', 'stage': 'notDispatched',
                'message': 'Explicit click and exact preparation fields required'})
            self.assertEqual(list(folder.iterdir()), [request])

class Workflow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mac-cu-recording-claim-', dir='/private/tmp'); self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.target = dict(pid=42, start=[10, 1], path='/synthetic/User.app/User', deviceID='11111111-1111-4111-8111-111111111111')
        self.request = dict(explicitClick=True, target=self.target, scope=dict(deviceID=self.target['deviceID'], bootIdentity=self.target['deviceID']+':99:9:1:/synthetic/launchd_sim', presentation='main', generation=1, runtime='27.2'))
        self.events = []; self.terminated = False
        outer = self
        class Probe:
            def identity(self, pid, device=True):
                return dict(outer.target, pid=pid, start=[11, 1] if pid == 43 else [10, 1], state=2, traced=False)
            def status(self, pid):
                return dict(start=[10, 1], state=5 if outer.terminated else 2)
        self.probe = Probe()
        class Ledger:
            def __init__(self, request): self.root = outer.folder; self.state = {'authority': 'released'}
            def close(self): outer.events.append('close')
        self.ledger = Ledger
        self.kw = dict(admit=lambda _: {'bundleID': 'test.user', 'build': {'developer': '/selected/Xcode/Contents/Developer'}}, setting=lambda _: None,
                       _claim_capture=lambda *_: type('Snapshot', (), {'recheck': lambda _: None})(), boot=lambda *_: None, enabled=lambda *_: True,
                       execute=self.execute, terminate=self.terminate)
    def terminate(self, *_): self.events.append('terminate'); self.terminated = True
    def execute(self, args, **kwargs):
        self.events.append(args[2])
        if args[2] == 'launch':
            self.assertEqual(kwargs['env']['SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG'], '287')
            self.assertEqual(kwargs['env']['DEVELOPER_DIR'], '/selected/Xcode/Contents/Developer')
            return subprocess.CompletedProcess(args, 0, b'test.user: 43\n', b'')
        return subprocess.CompletedProcess(args, 0, b'43 0 UIKitApplication:test.user[UUID]\n', b'')
    def run_case(self):
        with patch.object(r.edit_backend, 'Ledger', self.ledger):
            return r.run(self.request, self.folder, self.probe, **self.kw)
    def test_click_only(self):
        self.request['explicitClick'] = False
        self.assertEqual(self.run_case()['stage'], 'notDispatched'); self.assertNotIn('terminate', self.events)
    def test_new_lifetime_and_replay(self):
        result = self.run_case(); self.assertEqual(result['status'], 'success'); self.assertEqual(result['target']['pid'], 43)
        self.assertEqual(self.events.count('launch'), 1)
        self.assertEqual(self.run_case()['stage'], 'notDispatched'); self.assertEqual(self.events.count('terminate'), 1)
    def test_wrong_device(self):
        self.request['scope']['deviceID'] = 'other'; self.assertEqual(self.run_case()['stage'], 'notDispatched')
    def test_stale_identity(self):
        self.probe.identity = lambda *a, **kw: dict(self.target, start=[99, 1], state=2, traced=False)
        self.assertEqual(self.run_case()['stage'], 'notDispatched')
    def test_boot_and_claim_refusal(self):
        for key in ('boot', '_claim_capture', 'admit', 'setting'):
            with self.subTest(key=key):
                old = self.kw[key]
                def reject(*_): raise ValueError('refused')
                self.kw[key] = reject
                self.assertEqual(self.run_case()['stage'], 'notDispatched')
                self.kw[key] = old
        self.assertNotIn('terminate', self.events)
    def test_pending_unknown_custody(self):
        for state in ('active', 'revoked', 'quarantined', 'expired', 'inactive'):
            old = self.ledger
            class Unreleased(old):
                def __init__(self, request): super().__init__(request); self.state['authority'] = state
            self.ledger = Unreleased
            self.assertEqual(self.run_case()['stage'], 'notDispatched')
            self.ledger = old
    def test_cancelled_generation(self):
        (self.folder / 'cancel').touch(); self.assertEqual(self.run_case()['stage'], 'notDispatched')
    def test_termination_failure(self):
        def fail(*_): raise ProcessLookupError('gone')
        self.kw['terminate'] = fail
        self.assertEqual(self.run_case()['status'], 'outcomeUncertain'); self.assertNotIn('launch', self.events)
    def test_termination_timeout(self):
        self.kw['terminate'] = lambda *_: None
        times = iter([0, 10]); self.kw['clock'] = lambda: next(times)
        self.assertEqual(self.run_case()['status'], 'outcomeUncertain'); self.assertNotIn('launch', self.events)
    def test_uncertain_launch_reconciles_without_replay(self):
        original = self.execute
        def execute(args, **kwargs):
            if args[2] == 'launch':
                self.events.append('launch'); raise subprocess.TimeoutExpired(args, 15)
            return original(args, **kwargs)
        self.kw['execute'] = execute
        result = self.run_case(); self.assertEqual(result['status'], 'outcomeUncertain')
        self.assertEqual(result['observedTarget']['pid'], 43); self.assertEqual(self.events.count('launch'), 1)
        self.run_case(); self.assertEqual(self.events.count('launch'), 1)
    def test_launch_failure_reconciles_unresolved(self):
        def execute(args, **kwargs):
            self.events.append(args[2])
            return subprocess.CompletedProcess(args, 1, b'', b'failed')
        self.kw['execute'] = execute
        result = self.run_case()
        self.assertEqual(result['status'], 'outcomeUncertain')
        self.assertEqual(result['reconciliation'], 'unresolved')
        self.assertEqual(self.events.count('launch'), 1)
    def test_cancel_after_termination_prevents_launch(self):
        def terminate(*args):
            self.terminate(*args); (self.folder / 'cancel').touch()
        self.kw['terminate'] = terminate
        self.assertEqual(self.run_case()['stage'], 'terminated'); self.assertNotIn('launch', self.events)
    def test_real_ledger_lock_conflict(self):
        original = r.edit_backend.Ledger
        held = original({'target': self.target}, root=self.folder)
        self.addCleanup(held.close)
        self.ledger = lambda request: original(request, root=self.folder)
        result = self.run_case()
        self.assertEqual(result['stage'], 'notDispatched')
        self.assertNotIn('terminate', self.events)
    def test_real_ledger_without_release(self):
        original = r.edit_backend.Ledger
        self.ledger = lambda request: original(request, root=self.folder)
        self.assertEqual(self.run_case()['stage'], 'notDispatched')
        self.assertNotIn('terminate', self.events)
    def test_unverified_recording(self):
        self.kw['enabled'] = lambda *_: False
        self.assertEqual(self.run_case()['status'], 'outcomeUncertain')

if __name__ == '__main__': unittest.main()
