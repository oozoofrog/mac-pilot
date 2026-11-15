"""Production admission with file/native/clock doubles; no native process reads."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import test_workflow as workflow
r = workflow.r

DEVICE = '11111111-1111-4111-8111-111111111111'

class Claims(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mac-cu-recording-claim-', dir='/private/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'claims.json'
        self.claim = dict(pid=20, by='advisory', note='', since='1970-01-01T00:01:41Z')
        self.write()
        self.nodes = {30: dict(pid=30, start=[102, 1], parent=25, state=2, path='/native/helper'),
                      25: dict(pid=25, start=[101, 1], parent=20, state=2, path='/native/ui'),
                      20: dict(pid=20, start=[100, 1], parent=10, state=2, path='/native/claimant')}
        owner = self
        class Probe:
            def identity(self, pid): return copy.deepcopy(owner.nodes[pid])
            def status(self, pid): return copy.deepcopy(owner.nodes[pid])
        self.probe = Probe()
        self.getpid = patch.object(r.os, 'getpid', return_value=30); self.getpid.start(); self.addCleanup(self.getpid.stop)
    def write(self, other=None):
        self.path.write_text(json.dumps({DEVICE:self.claim, **(other or {})}))
    def snapshot(self, dead=False):
        return r.ClaimAdmission(DEVICE, self.probe, _path_override=self.path, _wall=lambda:200, _dead_probe=lambda _:dead)
    def test_ancestor_and_unrelated_update(self):
        snap = self.snapshot()
        self.write({'22222222-2222-4222-8222-222222222222':dict(self.claim, pid=123)})
        snap.recheck()
        self.assertEqual([v['pid'] for v in snap.chain], [30,25,20])
    def test_foreign_shared_parent_is_not_ancestor(self):
        self.nodes[25]['parent'] = 1
        with self.assertRaises(ValueError): self.snapshot()
    def test_absent_and_dead_routes_are_pinned(self):
        self.path.unlink(); snap = self.snapshot(); self.write()
        with self.assertRaises(ValueError): snap.recheck()
        dead = self.snapshot(dead=True); dead.recheck(); dead.dead=lambda _:False
        with self.assertRaises(ValueError): dead.recheck()
    def test_claim_value_changed(self):
        snap=self.snapshot(); self.claim['by']='same pid different claim'; self.write()
        with self.assertRaises(ValueError): snap.recheck()
    def test_same_second_and_future_refused(self):
        for since in ('1970-01-01T00:01:40Z', '1970-01-01T00:04:00Z', '1970-01-01T00:01:41'):
            self.claim['since']=since; self.write()
            with self.subTest(since=since), self.assertRaises(ValueError): self.snapshot()
    def test_pid_reuse_reparent_exec_zombie(self):
        for key,value in [('start',[100,2]), ('parent',11), ('path','/native/exec'), ('state',5)]:
            original=copy.deepcopy(self.nodes); snap=self.snapshot(); self.nodes[20][key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): snap.recheck()
            self.nodes=original
    def test_edge_changes_during_native_read(self):
        original=self.probe.identity
        def read(pid):
            value=original(pid); self.nodes[pid]['parent']+=1; return value
        self.probe.identity=read
        with self.assertRaises(ValueError): self.snapshot()
    def test_normal_running_sleeping_transitions_keep_native_identity(self):
        reads = 0
        def read(pid):
            nonlocal reads
            reads += 1
            value = copy.deepcopy(self.nodes[pid])
            value['state'] = 2 if reads % 2 else 3
            return value
        self.probe.status = read
        self.probe.identity = read
        snapshot = self.snapshot()
        snapshot.recheck()
        self.assertEqual([node['pid'] for node in snapshot.chain], [30, 25, 20])
    def test_stopped_or_unknown_native_state_is_not_admitted(self):
        for state in (0, 1, 4, 5):
            with self.subTest(state=state):
                self.nodes[25]['state'] = state
                with self.assertRaises(ValueError): self.snapshot()
    def test_cycle_pid1_bound_missing_denied(self):
        for mode in ('cycle','pid1','missing','denied','bound'):
            with self.subTest(mode=mode):
                original=copy.deepcopy(self.nodes)
                if mode=='cycle': self.nodes[25]['parent']=30
                if mode=='pid1': self.claim['pid']=1; self.write()
                if mode=='missing': del self.nodes[25]
                if mode=='bound':
                    for pid in range(30,63): self.nodes[pid]=dict(self.nodes[20],pid=pid,parent=pid+1)
                if mode=='denied': self.probe.identity=lambda _: (_ for _ in ()).throw(PermissionError())
                with self.assertRaises((ValueError,KeyError,PermissionError)): self.snapshot()
                self.nodes=original; self.claim['pid']=20; self.write()
    def test_bad_files(self):
        variants=['{', '[]', json.dumps({DEVICE:dict(self.claim,pid=True)}),
                  json.dumps({DEVICE:dict(self.claim,since='NaN')}),
                  '{"'+DEVICE+'":{},"'+DEVICE+'":{}}',
                  json.dumps({DEVICE:self.claim, DEVICE.lower():self.claim}) if DEVICE.lower()!=DEVICE else
                  '{"AAAAAAAA-1111-4111-8111-111111111111":{},"aaaaaaaa-1111-4111-8111-111111111111":{}}',
                  ' '* (1024*1024+1)]
        for raw in variants:
            self.path.write_text(raw)
            device='AAAAAAAA-1111-4111-8111-111111111111' if raw.startswith('{"AAAAAAAA') else DEVICE
            with self.subTest(raw=raw[:60]), self.assertRaises((ValueError,KeyError)):
                r.ClaimAdmission(device,self.probe,_path_override=self.path,_wall=lambda:200,_dead_probe=lambda _:False)
        self.path.unlink(); self.path.symlink_to('missing')
        with self.assertRaises(OSError): self.snapshot()
    def test_denied_file_and_unsafe_mode(self):
        with patch.object(r.os,'open',side_effect=PermissionError()), self.assertRaises(PermissionError): self.snapshot()
        import stat
        from types import SimpleNamespace
        with patch.object(r.os,'fstat',return_value=SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=os.getuid()+1)), self.assertRaises(ValueError): self.snapshot()
        self.path.chmod(0o666)
        with self.assertRaises(ValueError): self.snapshot()

class SchemaAndBoundaries(workflow.Workflow):
    def test_closed_schema_before_admission(self):
        variants=[]
        for key in self.request:
            value=copy.deepcopy(self.request); del value[key]; variants.append(value)
        for value in (False,1,None): variants.append(dict(self.request,explicitClick=value))
        variants.append(dict(self.request,extra=1))
        for section in ('target','scope'):
            for field in self.request[section]:
                value=copy.deepcopy(self.request); del value[section][field]; variants.append(value)
            value=copy.deepcopy(self.request); value[section]['extra']=1; variants.append(value)
        for field,bad in [('pid',True),('pid',float('nan')),('pid',2**31),('start',[10,True]),('start',[10,1000000]),('start',[2**64,0]),('path','/a/../b'),('path','relative'),('deviceID','bad')]:
            value=copy.deepcopy(self.request); value['target'][field]=bad; variants.append(value)
        for field,bad in [('generation',True),('generation',float('nan')),('generation',2**64),('runtime',False),('bootIdentity','bad'),('bootIdentity',DEVICE+':99:9:1000000:/launchd_sim')]:
            value=copy.deepcopy(self.request); value['scope'][field]=bad; variants.append(value)
        value=copy.deepcopy(self.request); value['scope']['displayID']='main'; variants.append(value)
        for value in variants:
            with self.subTest(value=value), patch.object(r.edit_backend,'Ledger') as ledger:
                self.kw['admit']=lambda _: self.fail('admission before validation')
                result=r.run(value,self.folder,self.probe,**self.kw)
                self.assertEqual(result['stage'],'notDispatched'); ledger.assert_not_called()
    def test_marker_boundary_mutation_and_no_replay(self):
        for stage in ('terminationDispatch','launchDispatch'):
            with self.subTest(stage=stage):
                for marker in self.folder.glob('*.recording'): marker.unlink()
                self.events.clear(); self.terminated=False
                claims=Claims(); claims.setUp(); self.addCleanup(claims.doCleanups)
                self.kw['_claim_capture']=lambda *_: claims.snapshot()
                original=r.edit_backend.atomic_write
                def write(path,value):
                    original(path,value)
                    if value['stage']==stage:
                        claims.claim['note']='changed before dispatch'; claims.write()
                with patch.object(r.edit_backend,'atomic_write',side_effect=write): result=self.run_case()
                self.assertEqual(result['status'],'outcomeUncertain')
                self.assertNotIn('launch',self.events)
                self.assertEqual(self.events.count('terminate'),0 if stage=='terminationDispatch' else 1)
                count=list(self.events); self.run_case()
                self.assertEqual(self.events.count('terminate'),count.count('terminate'))
    def test_real_serialized_released_ledger(self):
        import sys
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
        import test_view_edit_backend as backend
        case=backend.EditTests(); case.setUp(); self.addCleanup(case.doCleanups)
        self.target['path']=case.target['path']
        case.target=self.target; case.probe=backend.Probe(self.target); case.request['target']=self.target
        initial=case.bootstrap(); released=case.call(case.release_request(initial))
        self.assertEqual(released['status'],'success',released)
        original=r.edit_backend.Ledger
        self.ledger=lambda request:original(request,root=case.root)
        self.assertEqual(self.run_case()['status'],'success')
        self.assertEqual(self.run_case()['stage'],'notDispatched')
        self.assertEqual(self.events.count('launch'),1)

    def test_claim_changed_after_launch_prevents_successor_admission(self):
        claims=Claims(); claims.setUp(); self.addCleanup(claims.doCleanups)
        self.kw['_claim_capture']=lambda *_: claims.snapshot()
        original=self.execute
        def execute(*args,**kwargs):
            result=original(*args,**kwargs)
            claims.claim['note']='changed after launch'; claims.write()
            return result
        self.kw['execute']=execute
        result=self.run_case()
        self.assertEqual(result['status'],'outcomeUncertain')
        self.assertNotIn('target',result)
        self.run_case(); self.assertEqual(self.events.count('launch'),1)
