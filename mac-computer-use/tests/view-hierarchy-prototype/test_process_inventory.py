"""Pure tests only: no Darwin calls, subprocesses, native apps, or signals."""
import ast
import ctypes as C
import errno
from pathlib import Path
import unittest
from unittest.mock import patch
import process_inventory as p


def status(pid=10, parent=1, group=10, start=(1, 2), state=2):
    return p.Status(pid, parent, group, start, state)


class Fake:
    def __init__(self):
        self.listed = [10]
        self.states = {10: status()}
        self.paths = {10: '/worker'}
        self.missing = set()
        self.hook = lambda name: None

    def enumerate(self):
        self.hook('enumerate')
        return len(self.listed) * 4, 0, tuple(self.listed)

    def status(self, pid):
        self.hook('status')
        s = self.states.get(pid)
        if isinstance(s, list):
            s = s.pop(0)
        return (C.sizeof(p.BSDInfo), 0, s) if s else (0, errno.EACCES, None)

    def path(self, pid):
        self.hook('path')
        value = self.paths.get(pid)
        return (len(value), 0, value) if value else (0, errno.ESRCH, None)

    def absent(self, pid):
        self.hook('absent')
        return (-1, errno.ESRCH, True) if pid in self.missing else (0, 0, False)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.fake, self.now = Fake(), 0

    def make(self, **kw):
        return p.Inventory(3, 10, ('/worker',), backend=self.fake,
                           clock=lambda: self.now, normalize=lambda x: x, **kw)

    def test_complete(self):
        r = self.make().sample()
        self.assertTrue(r.complete)
        self.assertEqual(r.matches, {'/worker': (10,)})
        self.assertEqual(r.counts, {'enumerate': 1, 'status': 2, 'path': 1})

    def test_unrelated_denied_blocks_global_completeness(self):
        self.fake.listed.append(99)
        r = self.make().sample()
        self.assertFalse(r.complete)
        self.assertIn(99, r.unknown)
        self.assertNotIn(99, r.members)

    def test_pid_zero_not_excluded(self):
        self.fake.listed.append(0)
        r = self.make().sample()
        self.assertIn(0, r.unknown)
        self.assertNotIn('absent', r.counts)

    def test_duplicate_across_unrelated_group(self):
        self.fake.listed.append(99)
        self.fake.states[99], self.fake.paths[99] = status(99, group=99), '/worker'
        r = self.make().sample()
        self.assertIn('duplicate exact executable', r.issues)
        self.assertEqual(r.matches['/worker'], (10, 99))

    def test_recursive_cross_group_children(self):
        self.fake.listed += [11, 12]
        self.fake.states.update({11: status(11, 10, 11), 12: status(12, 11, 12)})
        self.fake.paths.update({11: '/helper', 12: '/child'})
        r = self.make().sample()
        self.assertEqual(r.members, {10, 11, 12})
        self.assertEqual(r.groups, {10, 11, 12})

    def test_parent_exit_retains_orphan_and_group(self):
        self.fake.listed.append(11)
        self.fake.states[11], self.fake.paths[11] = status(11, 10, 11), '/helper'
        inv = self.make()
        self.assertTrue(inv.sample().complete)
        self.fake.listed = [11, 12]
        del self.fake.states[10]
        del self.fake.paths[10]
        self.fake.missing.add(10)
        self.fake.states[11] = status(11, 1, 11)
        self.fake.states[12], self.fake.paths[12] = status(12, 1, 11), '/other'
        r = inv.sample()
        self.assertFalse(r.complete)
        self.assertEqual(r.members, {10, 11, 12})
        self.assertEqual(r.terminal[10], 'fresh ESRCH')

    def test_identity_changes_sticky_even_after_terminal(self):
        for changed in (status(start=(2, 3)), status(parent=2), status(group=11)):
            with self.subTest(changed=changed):
                self.fake = Fake()
                self.fake.states[10] = [status(), changed]
                inv = self.make()
                self.assertFalse(inv.sample().complete)
                self.fake.states = {}
                self.fake.paths = {}
                self.fake.missing.add(10)
                self.assertFalse(inv.sample().complete)

    def test_path_change_between_samples_rejected(self):
        inv = self.make()
        self.assertTrue(inv.sample().complete)
        self.fake.paths[10] = '/exec'
        self.assertFalse(inv.sample().complete)

    def test_scheduling_states_not_collapsed_or_lifetime_changes(self):
        self.fake.states[10] = [status(state=2), status(state=3)]
        r = self.make().sample()
        self.assertTrue(r.complete)
        self.assertEqual(r.rows[10][0].state, 3)

    def test_zombie_missing_path_blocks_exact_count(self):
        self.fake.states[10] = status(state=5)
        self.fake.paths = {}
        r = self.make().sample()
        self.assertIn(10, r.unknown)
        self.assertEqual(r.terminal[10], 'zombie (not reaped)')

    def test_transient_esrch_not_terminal_without_fresh_proof(self):
        self.fake.paths = {}
        inv = self.make()
        self.assertIn(10, inv.sample().unknown)
        self.fake.missing.add(10)
        self.assertEqual(inv.sample().terminal, {10: 'fresh ESRCH'})

    def test_unlisted_unknown_is_retained(self):
        self.fake.listed.append(99)
        inv = self.make()
        inv.sample()
        self.fake.listed = [10]
        self.assertIn(99, inv.sample().unknown)

    def test_enumeration_failure_partial_saturated(self):
        for size in (-1, 0, 3, p.MAX_PIDS * 4, p.MAX_PIDS * 4 + 4):
            with self.subTest(size=size), patch.object(self.fake, 'enumerate', return_value=(size, 0, ())):
                r = self.make().sample()
                self.assertFalse(r.complete)
                self.assertNotIn('status', r.counts)

    def test_cumulative_ceiling(self):
        inv = self.make()
        inv.seen = set(range(1, p.MAX_PIDS + 1))
        self.fake.listed = [p.MAX_PIDS + 1]
        self.assertIn('cumulative PID ceiling exceeded', inv.sample().issues)

    def test_input_allocation_limits(self):
        for kw in ({'retained': tuple(range(1, p.MAX_PIDS + 2))}, {'groups': (0,)}):
            with self.assertRaises(ValueError): self.make(**kw)
        with self.assertRaises(ValueError):
            p.Inventory(float('inf'), 10)

    def test_cutoff_each_kernel_boundary(self):
        for stage in ('enumerate', 'status', 'path', 'absent'):
            with self.subTest(stage=stage):
                self.fake, self.now = Fake(), 0
                if stage == 'absent': self.fake.paths = {}
                def expire(name):
                    if name == stage: self.now = 3
                self.fake.hook = expire
                r = self.make().sample()
                self.assertFalse(r.complete)
                self.assertIn('cutoff exhausted; raw results rejected', r.issues)

    def test_cutoff_normalization_and_no_restart(self):
        inv = self.make()
        n = [0]
        def normalize(path):
            n[0] += 1
            if n[0] == 2: self.now = 3
            return path
        inv.normalize = normalize
        self.assertFalse(inv.sample().complete)
        self.assertFalse(inv.sample().complete)
        self.assertEqual(inv.calls['enumerate'], 1)
        self.assertEqual(inv.cutoff, 3)
        self.assertIn('sample ceiling exceeded', inv.sample().issues)

    def test_no_process_launch_or_nonzero_signal_source(self):
        tree = ast.parse(Path(p.__file__).read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
        names = [ast.unparse(n.func) for n in calls]
        self.assertFalse(any(any(x in name for x in ('Popen', 'subprocess', 'spawn', 'fork', 'waitpid', 'killpg', 'system')) for name in names))
        kills = [n for n in calls if ast.unparse(n.func) == 'os.kill']
        self.assertEqual(len(kills), 1)
        self.assertEqual(ast.literal_eval(kills[0].args[1]), 0)


class ABIReads(unittest.TestCase):
    def make(self):
        backend = object.__new__(p.Libproc)
        backend.lib = type('Library', (), {})()
        return backend

    def test_layout(self):
        self.assertEqual(C.sizeof(p.BSDInfo), 136)
        self.assertEqual(p.BSDInfo.start_sec.offset, 120)
        self.assertEqual(p.BSDInfo.pgid.offset, 100)

    def test_typed_declarations(self):
        from unittest.mock import Mock
        lib = Mock()
        with patch.object(p.C, 'CDLL', return_value=lib):
            p.Libproc()
        self.assertEqual(lib.proc_listpids.argtypes, [C.c_uint32, C.c_uint32, C.c_void_p, C.c_int])
        self.assertEqual(lib.proc_pidinfo.argtypes, [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int])
        self.assertEqual(lib.proc_pidpath.argtypes, [C.c_int, C.c_void_p, C.c_uint32])
        for fn in (lib.proc_listpids, lib.proc_pidinfo, lib.proc_pidpath):
            self.assertIs(fn.restype, C.c_int)

    def test_fixed_enumeration_buffer(self):
        b = self.make()
        for returned in (4, 3, 0, -1, p.MAX_PIDS * 4):
            def read(kind, info, buf, capacity):
                self.assertEqual((kind, info, capacity), (1, 0, p.MAX_PIDS * 4))
                buf[0] = 10
                return returned
            b.lib.proc_listpids = read
            self.assertEqual(b.enumerate()[2], (10,) if returned == 4 else ())

    def test_invalid_state_is_unknown(self):
        b = self.make()
        def read(pid, flavor, arg, buf, capacity):
            value = C.cast(buf, C.POINTER(p.BSDInfo)).contents
            value.pid, value.status = pid, 0
            return capacity
        b.lib.proc_pidinfo = read
        self.assertIsNone(b.status(10)[2])

    def test_status_failed_partial_wrong_pid(self):
        b = self.make()
        for size, pid in ((0, 10), (135, 10), (-1, 10), (136, 11)):
            def read(_pid, flavor, arg, buf, capacity):
                value = C.cast(buf, C.POINTER(p.BSDInfo)).contents
                value.pid, value.status = pid, 5
                return size
            b.lib.proc_pidinfo = read
            self.assertIsNone(b.status(10)[2])

    def test_path_failed_partial_and_saturated(self):
        b = self.make()
        for size, raw in ((0, b'/x\0'), (-1, b'/x\0'), (1, b'/x\0'), (2, b'x\0'), (4096, b'/x\0'), (2, b'/x!')):
            def read(pid, buf, capacity):
                C.memmove(buf, raw, len(raw))
                return size
            b.lib.proc_pidpath = read
            self.assertIsNone(b.path(10)[2])
        b.lib.proc_pidpath = lambda pid, buf, capacity: (C.memmove(buf, b'/x\0', 3), 2)[1]
        self.assertEqual(b.path(10)[2], '/x')

    def test_absence_denied_live_esrch(self):
        b = self.make()
        for error, expected in ((None, False), (PermissionError(errno.EPERM, 'denied'), False), (ProcessLookupError(errno.ESRCH, 'gone'), True)):
            with patch.object(p.os, 'kill', side_effect=error) as kill:
                self.assertEqual(b.absent(10)[2], expected)
                kill.assert_called_once_with(10, 0)


if __name__ == '__main__':
    unittest.main()
