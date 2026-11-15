"""Bounded attempt-1 topology replay; no GUI, child, signal or custody."""
from pathlib import Path
import unittest
from unittest.mock import patch
import session as s
from test_probe_family import SERVER, PYTHON_APP

DEVICE='64A62D96-12FE-4D9C-81AE-ED9C3A2174F0'
UI='/private/test/ui/InspectorProductCheck.app/Contents/MacOS/check'
RESOURCE='/private/test/ui/InspectorProductCheck.app/Contents/Resources/view-capture/capture.py'
DEVICECTL='/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl'
CONTRACT=dict(binary=UI,capture=RESOURCE,device=DEVICE,output='/private/test/run',temporary='/private/test/tmp')
ROWS=[(33918,1,33918,'/worker','S'),(34146,33918,33918,UI,'S'),(34150,34146,34150,DEVICECTL,'S')]
ARGS=[DEVICECTL,'device','info','displays','--device',DEVICE,'--quiet','--json-output','/private/test/tmp/mac-cu-displays-'+DEVICE+'-test.json']

class UIFamily(unittest.TestCase):
    def observer(self):
        o=s.watchdog.ProcessObservation(lambda:0,isolated_probe='/private/test/product/session-probe',
            probe_tools=s.probe_tool_paths(SERVER),probe_python=(PYTHON_APP,),ui_contract=CONTRACT)
        o.group=33918
        o.validate_groups(ROWS,33918)
        return o

    def test_attempt1_old_contract_rejects_raw_topology(self):
        o=s.watchdog.ProcessObservation(lambda:0,isolated_probe='/private/test/product/session-probe',probe_tools=s.probe_tool_paths(SERVER))
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'unexpected separate process group'):
            o.validate_groups(ROWS,33918)

    def test_ui_parent_group_and_two_display_candidates(self):
        o=self.observer()
        o.validate_groups(ROWS+[(34151,34146,34151,DEVICECTL,'S')],33918)
        self.assertEqual(o.ui_roles,{34150:'candidate',34151:'candidate'})
        self.assertEqual(o.helper_roles,{})  # Topology alone grants no argv role.

    def test_wrong_root_group_parent_or_executable_retains_row(self):
        cases = [
            (ROWS + [(34147,33918,33918,UI,'S')], 34147),
            ([ROWS[0], (34146,99,33918,UI,'S'), ROWS[2]], 34146),
            (ROWS[:2] + [(101,34146,999,PYTHON_APP,'S')], 101),
            (ROWS[:2] + [(101,34146,101,'/unknown','S')], 101),
            (ROWS[:2] + [(101,34146,101,PYTHON_APP,'S'), (102,101,999,PYTHON_APP,'S')], 102),
            (ROWS[:2] + [(101,34146,101,PYTHON_APP,'S'), (102,101,101,'/unadmitted-child','S')], 102),
        ]
        for rows,pid in cases:
            with self.subTest(pid=pid,rows=rows):
                o=self.observer()
                with self.assertRaises(s.watchdog.IdentityChanged):o.validate_groups(rows,33918)
                event=o.events[-1]
                self.assertEqual(event['status'],'observedMismatch')
                self.assertEqual(event['current']['pid'],pid)
                self.assertIsNone(event['current']['start'])
                self.assertFalse(event['signalAuthority'])

    def test_candidate_budget_is_bounded_before_argv(self):
        rows=ROWS[:2]+[(500+i,34146,500+i,DEVICECTL,'S') for i in range(17)]
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'candidate budget'):
            self.observer().validate_groups(rows,33918)

    def test_missing_prepared_pins_never_qualify_complete_inventory(self):
        o=self.observer()
        identities={r[0]:dict(pid=r[0],parent=r[1],group=r[2],path=r[3],start=[10,r[0]],state=2) for r in ROWS}
        with patch.object(Path,'is_file',return_value=True),patch.object(s.watchdog,'rows',return_value=ROWS), \
             patch.object(s.watchdog,'identify_live_server',side_effect=lambda pid:dict(identities[pid])), \
             patch.object(s.watchdog,'process_identity',side_effect=lambda pid:dict(identities[pid])):
            with self.assertRaisesRegex(s.watchdog.IdentityChanged,'toolHashes'):
                o.complete(33918,lambda _:None)
        self.assertEqual(o.events[-1]['context'],'UI semantic admission')

    def test_partial_parent_deferral_does_not_grant_final_role(self):
        o=self.observer()
        partial=ROWS[:2]+[(102,101,101,'/usr/bin/codesign','S')]
        o.validation_pending={101}
        o.validation_members={102}
        token=s.watchdog._observation.set(o)
        try:
            o.validate_groups(partial,33918)
            self.assertEqual(o.ui_roles[102],'candidate')
            o.validation_pending=set()
            with self.assertRaises(s.watchdog.IdentityChanged):o.validate_groups(partial,33918)
        finally:s.watchdog._observation.reset(token)
