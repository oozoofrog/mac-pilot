"""Headless contract tests. Synthetic receipts here are never UI or guest evidence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import evidence

class ReceiptContract(unittest.TestCase):
    def setUp(self):
        self.target = dict(pid=1, start=[2,3], path='/owned/app', deviceID='owned-device')
        self.state = dict(target=self.target, authority='released', releaseProof=dict(operationID='release'),
            operations={'release':dict(state='finished',kind='release')}, results={'release':dict(
                status='success',registryReleased=True,validationOnly=False,cleanup=dict(detach='success',childrenReaped=True,recovery=dict(verified=True)))})
    def test_release_requires_native_terminal_and_recovery(self):
        self.assertTrue(evidence.released(self.state,self.target))
        for key, value in [('authority','revoked'),('target',{}),('releaseProof',None)]:
            state=copy.deepcopy(self.state); state[key]=value
            self.assertFalse(evidence.released(state,self.target))
        for key,value in [('registryReleased',False),('validationOnly',True),('status','expired')]:
            state=copy.deepcopy(self.state);state['results']['release'][key]=value
            self.assertFalse(evidence.released(state,self.target))
        for key,value in [('childrenReaped',False),('detach','unknown'),('recovery',{'verified':False})]:
            state=copy.deepcopy(self.state);state['results']['release']['cleanup'][key]=value
            self.assertFalse(evidence.released(state,self.target))
    def test_reserved_operation_preserves_custody(self):
        self.state['operations']['pending']={'state':'reserved','kind':'capture'}
        self.assertFalse(evidence.released(self.state,self.target))
    def test_unknown_receipt_is_not_release(self):
        self.state['results']={}
        self.assertFalse(evidence.released(self.state,self.target))
    def test_target_key_is_canonical(self):
        self.assertEqual(evidence.ledger_path(self.target),evidence.ledger_path(dict(reversed(list(self.target.items())))))
    def test_no_mock_or_wrapper_UI_path(self):
        source=Path(__file__).with_name('live.swift').read_text()
        for forbidden in ['SimulatorInspectorBackend(', 'SimulatorInspectorCallbacks(', 'simulatorCaptureEditableViews(', 'validationOnly: true', 'simulatorEditView(', 'simulatorRevertView(']:
            self.assertNotIn(forbidden,source)
        self.assertIn('SimulatorWindow(device:',source)
        self.assertIn('3D 뷰 검사…',source)
        self.assertIn('native capture reservation',source)

if __name__=='__main__': unittest.main()

class HeadlessTopologyGuard(unittest.TestCase):
    def test_no_debugger_guard_preserves_original_snapshot_and_no_ui_contract(self):
        import importlib.util
        from unittest.mock import patch
        spec=importlib.util.spec_from_file_location('guard_contract_runner',Path(__file__).with_name('runner.py'))
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        snapshot=[]; details={}
        with patch.object(runner.product,'process_budget') as budget:
            runner.process_budget(snapshot,40,None,Path('/private/test/build'),None,details)
            self.assertIs(budget.call_args.args[0],snapshot)
            budget.assert_called_once_with(snapshot,40,None,Path('/private/test/build'),None,details)
