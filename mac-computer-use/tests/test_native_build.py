"""Compilation routing and failure propagation without native execution."""
import sys
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'skills/mac-computer-use/scripts'))
from native_build import run_swift, native_inputs, STUB_MODULES, SOURCE

STUBS = len(STUB_MODULES)


def ok(stderr=''):
    return subprocess.CompletedProcess([], 0, '', stderr)


class NativeBuildTests(unittest.TestCase):
    @patch('native_build.subprocess.run')
    def test_typecheck_imports_without_object(self, run):
        run.return_value = ok()
        run_swift(['swiftc', '-typecheck', 'main.swift'])
        self.assertEqual(run.call_count, STUBS + 1)
        command = run.call_args.args[0]
        self.assertIn('-import-objc-header', command)
        self.assertFalse(any(p.endswith('.o') for p in command))

    @patch('native_build.subprocess.run')
    def test_stub_modules_precede_compile_and_are_found(self, run):
        run.return_value = ok()
        run_swift(['swiftc', '-typecheck', 'main.swift'])
        emits = [call.args[0] for call in run.call_args_list[:STUBS]]
        # Dependencies first; library evolution, module only, never an object or a link.
        self.assertEqual([c[c.index('-module-name') + 1] for c in emits], ['CoreDeviceUtilities', 'CoreDevice'])
        for c in emits:
            self.assertIn('-emit-module', c)
            self.assertIn('-enable-library-evolution', c)
            self.assertFalse(any(p.endswith('.o') for p in c))
            self.assertTrue(c[c.index('-emit-module-path') + 1].endswith('.swiftmodule'))
        modules = str(Path(emits[0][emits[0].index('-emit-module-path') + 1]).parent)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index('-I') + 1], modules)
        weak = [command[i + 2] for i, flag in enumerate(command) if flag == '-weak_framework']
        self.assertEqual(weak, ['CoreDevice', 'CoreDeviceUtilities'])
        self.assertNotIn('-framework', command)
        self.assertFalse(Path(modules).exists())  # Temporary: gone after the command.

    @patch('native_build.subprocess.run')
    def test_stub_failure_stops_before_compile(self, run):
        run.return_value = subprocess.CompletedProcess([], 3, '', 'stub failure')
        result = run_swift(['swiftc', 'main.swift', '-o', '/tmp/unused'], capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stderr, run.call_count), (3, 'stub failure', 1))

    @patch('native_build.subprocess.run')
    def test_compile_failure_does_not_link(self, run):
        run.side_effect = [ok()] * STUBS + [subprocess.CompletedProcess([], 9, '', 'clang failure')]
        result = run_swift(['swiftc', 'main.swift', '-o', '/tmp/unused'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stderr, 'clang failure')
        self.assertEqual(run.call_count, STUBS + 1)
        self.assertIn('-fobjc-arc', run.call_args.args[0])

    @patch('native_build.subprocess.run')
    def test_link_uses_temporary_object_and_preserves_options(self, run):
        run.side_effect = [ok()] * STUBS + [ok('warning\n'), subprocess.CompletedProcess([], 1, '', 'link failure')]
        result = run_swift(['swiftc', '-g', 'main.swift', '-o', '/tmp/unused'], capture_output=True, text=True, timeout=180)
        obj = run.call_args.args[0][-1]
        self.assertTrue(obj.endswith('.o'))
        self.assertFalse(Path(obj).parent.exists())
        self.assertEqual(run.call_args.kwargs['timeout'], 180)
        self.assertEqual(result.stderr, 'warning\nlink failure')

    def test_stub_sources_are_build_inputs_outside_the_product_glob(self):
        stubs = [p for p in native_inputs() if p.parent.name == 'CoreDeviceStubs']
        self.assertEqual(len(stubs), STUBS)
        self.assertTrue(all(p.is_file() for p in stubs))
        # setup.py and the checks compile SOURCE.glob('*.swift'): the stubs must never be compiled into mac-cu.
        self.assertFalse(set(stubs) & set(SOURCE.glob('*.swift')))


if __name__ == '__main__':
    unittest.main()
