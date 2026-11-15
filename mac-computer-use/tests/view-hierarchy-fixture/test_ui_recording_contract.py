"""Synthetic transition predicate; no runtime observer rebinding or process rows."""
import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'view-hierarchy-prototype'))
import ui_recording_contract as c

class TransitionTests(unittest.TestCase):
    def setUp(self):
        self.old=dict(pid=10,start=[100,1],path='/owned/User.app/User',deviceID='DEVICE')
        self.scope=dict(deviceID='DEVICE',bootIdentity='DEVICE:9:90:1:/owned/launchd_sim',presentation='main',generation=1,runtime='27.2')
        self.native=dict(self.old,parent=9,group=10,state=2,traced=False)
        self.args=dict(original=self.old,scope=self.scope,request=dict(explicitClick=True,target=self.old,scope=self.scope),
            marker=dict(stage='terminationDispatch',target=self.old),release_verified=True,native_original=self.native)
        self.new=dict(self.old,pid=11,start=[101,2])
        self.newnative=dict(self.new,parent=9,group=11,state=2,traced=False)
        self.kw=dict(candidate=self.new,read_native=lambda _:self.newnative,read_scope=lambda:self.scope,
            reconcile_containers=lambda _:True,check=lambda:None)
    def exited(self):
        return c.Transition.begin(**self.args).original_exited(lambda old:dict(target=old,exited=True),lambda:None)
    def test_positive_independent_exit_double_native_and_scope(self):
        self.assertEqual(self.exited().reconcile(**self.kw).state,'reconciled')
    def test_explicit_action_release_and_marker_required(self):
        for key,value in [('release_verified',False),('marker',dict(stage='launchDispatch',target=self.old)),
                          ('request',dict(explicitClick=False,target=self.old,scope=self.scope))]:
            with self.subTest(key=key),self.assertRaises(c.a.ContractError):
                c.Transition.begin(**dict(self.args,**{key:value}))
    def test_no_result_pid_or_missing_exit_authority(self):
        t=c.Transition.begin(**self.args)
        with self.assertRaises(c.a.ContractError):t.reconcile(**self.kw)
        for evidence in (None,{'exited':True},{'target':self.old,'exited':False}):
            with self.subTest(evidence=evidence),self.assertRaises(c.a.ContractError):
                t.original_exited(lambda _:evidence,lambda:None)
    def test_unknown_cannot_resume(self):
        with self.assertRaises(c.a.ContractError):self.exited().stop_unknown().reconcile(**self.kw)
    def test_native_scope_container_and_deadline_rejections(self):
        for key,value in [('read_native',lambda _:dict(self.newnative,start=self.old['start'])),
                          ('read_native',lambda _:dict(self.newnative,traced=True)),
                          ('read_scope',lambda:dict(self.scope,generation=2)),
                          ('reconcile_containers',lambda _:False)]:
            with self.subTest(key=key),self.assertRaises(c.a.ContractError):
                self.exited().reconcile(**dict(self.kw,**{key:value}))
        def deadline():raise TimeoutError('original cutoff expired')
        with self.assertRaisesRegex(c.a.ContractError,'original cutoff expired'):self.exited().reconcile(**dict(self.kw,check=deadline))
    def test_lifetime_change_between_reads(self):
        reads=iter([self.newnative,dict(self.newnative,start=[102,3])])
        with self.assertRaises(c.a.ContractError):
            self.exited().reconcile(**dict(self.kw,read_native=lambda _:next(reads)))
if __name__=='__main__':unittest.main()
