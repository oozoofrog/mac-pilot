"""Resident production channel/custody regressions; no Simulator or GUI calls."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

RESOURCE = Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture'
sys.path.insert(0, str(RESOURCE))
import resident_protocol as p
import resident_transport as transport
import edit_backend
import runner


class IsolatedProbeObservation(unittest.TestCase):
    def test_shared_isolated_probe_and_aggregate_utility_contract(self):
        import tempfile
        w = runner.s.watchdog
        server = '/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve(); probe = build / 'session-probe'; probe.touch()
            for extra in (False, True):
                rows = [(100, 40, 100, str(probe), 'S'), (101, 100, 100, '/bin/ps', 'S')]
                if extra: rows.append((102, 40, 40, '/usr/bin/plutil', 'S'))
                def identify(pid):
                    row = next(r for r in rows if r[0] == pid)
                    return dict(pid=pid, parent=row[1], group=row[2], path=row[3], start=[10, pid], state=2)
                with patch.object(runner.s, 'monotonic', return_value=0), \
                     patch.object(w, 'rows', return_value=rows), \
                     patch.object(w, 'identify_live_server', side_effect=identify):
                    def observe():
                        return runner.s.observe_processes(40, None, build, server, {}, 3,
                                                         process_check=runner.process_budget)
                    if extra:
                        with self.assertRaisesRegex(RuntimeError, 'utility budget'): observe()
                    else:
                        self.assertEqual(len(observe()), 2)


class PartialProcessTopology(unittest.TestCase):
    def observe_tree(self, utility_parent):
        w = runner.s.watchdog
        server = '/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'
        python = str(Path(sys.executable).resolve())
        now, passes = [0.0], [0]
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve(); probe = build / 'session-probe'; probe.touch()
            stable = [(90, 100, 40, python, 'S'), (80, 90, 40, python, 'S'), (70, 90, 40, server, 'S')]
            utility = (60, utility_parent, 40, '/usr/bin/xcrun', 'S')
            def rows(timeout):
                passes[0] += 1; now[0] += .25
                return [(100, 40, 40, '/nonexistent/(session-probe)', 'S')] + stable + ([utility] if passes[0] == 1 else [])
            def identity(pid):
                if pid == 100 and passes[0] == 1: return w.UNVERIFIED
                if pid == 60: return None
                row = (100, 40, 40, str(probe), 'S') if pid == 100 else next(r for r in stable if r[0] == pid)
                info = dict(pid=pid, parent=row[1], group=40, start=[1000, pid], state=2, path=row[3])
                w._observation.get().record(pid, 'controlled-kernel', 1, 0, info)
                return info
            with patch.object(runner.s, 'monotonic', side_effect=lambda: now[0]), \
                 patch.object(w, 'rows', side_effect=rows), \
                 patch.object(w, 'identify_live_server', side_effect=identity):
                return runner.s.observe_processes(40, None, build, server, {}, 1,
                                                   process_check=runner.process_budget)

    def test_known_nested_roles_wait_for_unresolved_probe_ancestor(self):
        actual = self.observe_tree(utility_parent=80)
        self.assertEqual({r[0] for r in actual}, {70, 80, 90, 100})

    def test_known_forbidden_parent_is_not_hidden_by_unknown_ancestor_or_exit(self):
        with self.assertRaisesRegex(RuntimeError, 'unknown process/utility parent'):
            self.observe_tree(utility_parent=70)

class Product(unittest.TestCase):
    def request(self):
        uid = lambda: str(uuid.uuid4()).upper()
        return {'schemaVersion':2, 'kind':'capture', 'validationOnly':False, 'ownerID':uid(), 'operationID':uid(),
                'inspectionID':uid(), 'targetEpoch':None, 'sequence':1, 'replaceCaptureID':None,
                'target':{'pid':123,'start':[100,5],'path':'/private/app/Ordinary.app/Ordinary','deviceID':uid()}}

    def test_copy_wire_has_no_pointers_and_integrity_covers_payload(self):
        q = self.request(); raw,digest = p.encode(q,'/private/image.dylib',str(uuid.uuid4()).upper())
        self.assertEqual(p.WIRE.size,2325)
        self.assertEqual(hashlib.sha256(raw[:p.WIRE.size-65]+raw[p.WIRE.size:]).hexdigest(),digest)
        self.assertEqual(json.loads(raw[p.WIRE.size:]),q)
        self.assertNotEqual(hashlib.sha256(raw[:p.WIRE.size-65]+raw[p.WIRE.size:-1]+b'!').hexdigest(),digest)

    def test_private_channel_refuses_symlinks_duplicates_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve(); os.chmod(root,0o700)
            p.write(root,'cancel',b'x'*64)
            with self.assertRaises(FileExistsError):p.write(root,'cancel',b'y'*64)
            (root/'answer.json').symlink_to(root/'cancel')
            with self.assertRaises(OSError):p.read(root,'answer.json')
            with self.assertRaises(RuntimeError):p.encode(dict(self.request(),junk='a'*65536),'/private/i',str(uuid.uuid4()).upper())

    def test_uncertain_load_and_submission_retain_debugger_and_children(self):
        for phase in ('load','submission'):
            engine=Mock(active_call=phase); result={}
            self.assertFalse(transport.finish_engine(engine,result))
            engine.detach.assert_not_called(); engine.close.assert_not_called()
            child=Mock(); server=Mock()
            self.assertFalse(transport.finish_children(child,server,result))
            child.terminate.assert_not_called(); child.kill.assert_not_called(); server.terminate.assert_not_called()
            self.assertTrue(result['custodyRequired'])

    def test_only_completed_call_and_detach_permit_destroy_and_reap(self):
        engine=Mock(active_call=None); engine.detach.return_value='success'; result={}
        self.assertTrue(transport.finish_engine(engine,result)); engine.close.assert_called_once()
        with patch.object(transport.c,'stop_child',return_value=0) as stop:
            child=Mock(returncode=0);server=Mock(returncode=0)
            self.assertTrue(transport.finish_children(child,server,result));self.assertEqual(stop.call_count,2)

    def test_detach_failure_retains_engine(self):
        engine=Mock(active_call=None); engine.detach.return_value='unknown'; result={}
        self.assertFalse(transport.finish_engine(engine,result));engine.close.assert_not_called()

    def test_normal_schema_is_not_an_override_for_native_policy(self):
        q=self.request(); self.assertFalse(transport.c.request_contract(q)['validationOnly'])
        for field in ('qualified','runtime','image','imageUUID','expression','selector','transition'):
            with self.assertRaises(transport.c.edit_backend.BackendError):transport.c.request_contract(dict(q,**{field:True}))

    def test_unknown_abi_or_duplicate_exports_refused_before_load(self):
        target=Mock(); lldb=Mock(); exports=target.FindGlobalFunctions.return_value
        exports.GetSize.return_value=1
        context=exports.GetContextAtIndex.return_value
        context.GetFunction.return_value.GetName.return_value=None
        context.GetSymbol.return_value.GetName.return_value='mac_cu_resident_submit_v3'
        with self.assertRaises(RuntimeError):transport.verify_resident_exports(target,lldb,'/private/pin.dylib','UUID')
        exports.GetSize.return_value=2
        with self.assertRaises(RuntimeError):transport.verify_resident_exports(target,lldb,'/private/pin.dylib','UUID')
        target.LoadImage.assert_not_called()
        exports.GetSize.return_value=0
        transport.verify_resident_exports(target,lldb,'/private/pin.dylib','UUID')

    def test_transport_escape_never_claims_pre_entry(self):
        q=self.request()
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory); folder.chmod(0o700)
            with patch.object(transport.c, 'validation_policy'), patch.object(transport.c, '_supervise', side_effect=RuntimeError('transport lost')):
                result=transport.c.supervise(q, folder, Mock(), lambda:False, ledger_root=folder/'ledger')
            self.assertEqual(result['mutationOutcome'],'uncertain')
            self.assertFalse(result['neverDispatched'])
            self.assertEqual(result['status'],'cleanupFailed')

    def test_host_admission_failure_is_explicitly_never_dispatched(self):
        q=self.request()
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory); folder.chmod(0o700)
            with patch.object(transport.c, 'validation_policy', side_effect=transport.c.CaptureError('unsupported','tuple mismatch')), patch.object(transport.c, '_supervise') as dispatch:
                result=transport.c.supervise(q,folder,Mock(),lambda:False,ledger_root=folder/'ledger')
            self.assertTrue(result['neverDispatched']); self.assertEqual(result['mutationOutcome'],'notEntered')
            dispatch.assert_not_called()

    def test_bootstrap_is_only_fixed_submit_address_and_owned_path(self):
        expression=transport.submission(4096,Path('/private/channel'))
        self.assertEqual(expression,'(int)((int (*)(const char *))0x1000)("/private/channel")')
        for path in ('/private/../x','/private/"x'):
            with self.assertRaises(RuntimeError):transport.submission(4096,Path(path))

if __name__=='__main__':unittest.main()
