"""인터프리터 및 LLDB 증명이 fixture 진입보다 먼저 실패하는지 확인한다."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import debugger
import prepare
import runner
import worker_runtime as w


class WorkerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.pin = dict(path='/chosen/lldb/__init__.py', resolved='/chosen/lldb/__init__.py', sha256='digest')
        self.context = dict(developer='/chosen/Developer', pythonPath='/chosen', files=[self.pin])
        self.proof = dict(schema=w.SCHEMA, context=self.context,
                          capability=dict(identity=w.identity(), isolated=True, module=self.pin,
                                          extension=self.pin, lldbVersion='LLDB test'))

    def test_old_manifest_refused_before_prepared_verification(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'prepared.json').write_text(json.dumps({'swiftUIProbe': {}}))
            with patch.object(runner.s, 'verify_prepared', side_effect=AssertionError('too late')) as admission:
                with self.assertRaisesRegex(RuntimeError, 'Missing standalone'):
                    runner.configure(Path(folder))
                admission.assert_not_called()

    def test_identity_change_refused_before_context_tools(self):
        self.proof['capability']['identity']['executable'] = '/other/python'
        with patch.object(w, 'context', side_effect=AssertionError('too late')) as context:
            with self.assertRaisesRegex(RuntimeError, 'interpreter changed'):
                w.verify(self.proof)
            context.assert_not_called()

    def test_xcode_or_lldb_hash_change_refused(self):
        for key in ('developer', 'files', 'developerOverride'):
            changed = dict(self.context, **{key: 'changed'})
            with self.subTest(key=key), patch.object(w, 'context', return_value=changed):
                with self.assertRaisesRegex(RuntimeError, 'Stale worker'):
                    w.verify(self.proof)

    def test_unselected_binding_refused(self):
        self.proof['capability']['extension'] = dict(self.pin, resolved='/other/LLDB')
        with patch.object(w, 'context', return_value=self.context):
            with self.assertRaisesRegex(RuntimeError, 'binding does not match'):
                w.verify(self.proof)

    def test_nonisolated_proof_refused(self):
        self.proof['capability']['isolated'] = False
        with self.assertRaisesRegex(RuntimeError, 'unverified'):
            w.verify(self.proof)

    def test_supervisor_refuses_before_target_or_fixture_admission(self):
        with patch.object(debugger, 'RUNTIME_PROOF', None), patch.object(debugger, 'admit_fixture') as admit, \
             patch.object(debugger.c, 'ProcessProbe') as probe:
            with self.assertRaisesRegex(RuntimeError, 'Missing standalone'):
                debugger.supervise({}, Path('/unused'), lambda: None)
            admit.assert_not_called(); probe.assert_not_called()

    def test_prepare_import_failure_precedes_build(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'prepare'
            with patch.object(w, 'prove', side_effect=RuntimeError('incompatible')), \
                 patch.object(prepare.subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'incompatible'):
                    prepare.prepare(output, None)
                run.assert_not_called()
                self.assertFalse((output / 'base').exists())

    def test_actual_script_isolated_and_sanitized_launch(self):
        result = subprocess.CompletedProcess([], 1, '', 'ImportError incompatible ABI')
        with patch.object(w, 'context', return_value=self.context), patch.dict('os.environ',
                {'PYTHONPATH': '/wrong', 'DYLD_LIBRARY_PATH': '/wrong', 'MAC_CU_TEST': 'wrong', 'KEEP': 'yes'}), \
             patch.object(w.subprocess, 'run', return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, 'No fallback'):
                w.prove()
            args, kwargs = run.call_args
            self.assertEqual(args[0], [sys.executable, '-I', str(w.HERE / 'debugger.py'),
                                      '--check-worker-runtime', '/chosen'])
            self.assertEqual(kwargs['timeout'], 15)
            self.assertEqual(kwargs['env']['KEEP'], 'yes')
            self.assertFalse(any(k.startswith(('PYTHON', 'DYLD_', 'MAC_CU_')) for k in kwargs['env']))

    def test_symlink_retarget_detected_even_for_identical_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ('a', 'b'): (root / name).write_bytes(b'same')
            link = root / 'link'; link.symlink_to(root / 'a'); old = w.file_pin(link)
            link.unlink(); link.symlink_to(root / 'b')
            self.assertNotEqual(w.file_pin(link), old)

    def test_bound_worker_uses_pinned_selection_without_child_tools(self):
        with patch.object(w, 'context', return_value=self.context) as context:
            w.verify(self.proof, bound_worker=True)
            context.assert_called_once_with('/chosen/Developer')

    def test_native_import_requires_isolation(self):
        with self.assertRaisesRegex(RuntimeError, '-I'):
            w.isolated_report('/unused')

    def test_guard_worker_verifies_binding_without_spawning_a_tool(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            developer = root / 'Xcode.app/Contents/Developer'; developer.mkdir(parents=True)
            resources = developer.parent / 'SharedFrameworks/LLDB.framework/Resources'
            package = resources / 'Python/lldb'; package.mkdir(parents=True)
            for path in (developer.parent / 'version.plist', resources.parent / 'LLDB',
                         resources / 'debugserver', package / '__init__.py', package / '_lldb.test.so'):
                path.write_bytes(b'unit-test binding identity')
            context = w.context(str(developer))
            proof = dict(schema=w.SCHEMA, context=context, capability=dict(identity=w.identity(), isolated=True,
                module=w.file_pin(package / '__init__.py'), extension=w.file_pin(package / '_lldb.test.so'),
                lldbVersion='unit-test capability'))
            (root / 'prepared.json').write_text(json.dumps(dict(dispatchPassed=True, hashes={},
                swiftUIProbe=dict(workerRuntime=proof, bundleID='local.test.fixture'))))
            argv = ['runner.py', '--worker-guard', str(root), str(root / 'out'), 'device', 'token', '123', '999']
            with patch.object(sys, 'argv', argv), \
                 patch.object(subprocess, 'Popen', side_effect=AssertionError('guard worker spawned a tool')), \
                 patch.object(runner.s, 'guard_worker', return_value=0) as guard, \
                 patch.object(runner.s, 'worker', side_effect=AssertionError('fixture admission')):
                self.assertEqual(runner.main(), 0)
                guard.assert_called_once()


if __name__ == '__main__':
    unittest.main()
