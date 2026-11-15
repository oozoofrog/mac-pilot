"""Actual preparation dispatch/calls with all process boundaries intercepted.

Synthetic claim absence is trace input, never normal-button qualification.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_canonical_call_trace as trace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_view_edit_backend as backend_tests
import recording_preparation as recording


def record(root, uncertain=False, claimed=False, invalid_release=False):
    def preparation(target, folder, resource, developer, events):
        # Generate a released ledger through the actual existing schema-2 test
        # supervisor; no fabricated authority='released' shortcut.
        case = backend_tests.EditTests()
        case.setUp()
        try:
            case.target = target
            case.probe = backend_tests.Probe(target)
            case.request['target'] = target
            case.request['validationOnly'] = False
            initial = case.bootstrap()
            release = case.call(case.release_request(initial))
            assert release['status'] == 'success', release
            events.clear()
            ledger_root = case.root
            ledger_class = recording.edit_backend.Ledger
            if invalid_release:
                path, state = case.state()
                state['results'][state['releaseProof']['operationID']]['cleanup']['recovery']['verified'] = False
                recording.edit_backend.atomic_write(path, state)
            request = dict(explicitClick=True, target=target, scope=dict(deviceID=target['deviceID'],
                bootIdentity=target['deviceID']+':99:90:1:/synthetic/launchd_sim',
                presentation='synthetic', generation=1, runtime='27.2'))
            request_path = folder/'recording-request.json'
            request_path.write_text(json.dumps(request)); request_path.chmod(0o600)
            folder.chmod(0o700)
            terminated = []
            class Probe:
                def identity(self, pid, device=True):
                    if pid == 99:
                        return dict(pid=99, start=[90,1], path='/synthetic/launchd_sim', deviceID=target['deviceID'],state=2,traced=False)
                    return dict(target, pid=pid, start=[101,6] if pid == 124 else target['start'], state=2, traced=False)
                def status(self, pid):
                    return dict(start=target['start'], state=5 if terminated else 2)
            def terminate(pid, sig):
                assert (pid,sig)==(target['pid'],signal.SIGTERM)
                marker=json.loads((ledger_root/(recording.edit_backend.digest(target)+'.recording')).read_text())
                assert marker == dict(stage='terminationDispatch',target=target)
                terminated.append(pid); events.append(dict(api='signal',pid=pid,signal=int(sig)))
            def execute(argv, **kw):
                events.append(dict(api='run',argv=argv,timeout=kw['timeout'],env=kw['env']))
                assert kw['env']['DEVELOPER_DIR']==str(developer)
                assert kw['env']['SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG']=='287'
                if argv[2]=='launch':
                    if uncertain: raise subprocess.TimeoutExpired(argv,15)
                    return subprocess.CompletedProcess(argv,0,b'test.owned.fixture: 124\n',b'')
                return subprocess.CompletedProcess(argv,0,b'124 0 UIKitApplication:test.owned.fixture[UUID]\n',b'')
            home=root/'home'; claims=home/'Library/Application Support/sim-pilot/claims.json'
            claims.parent.mkdir(parents=True)
            claims.write_text(json.dumps({target['deviceID']:dict(pid=os.getpid())} if claimed else {}))
            real_run=recording.run
            def run(request, folder, probe):
                # Defaults bind before patching. Supply intercepted boundaries
                # explicitly; actual admission, claim, boot and ledger execute.
                return real_run(request,folder,probe,setting=lambda _:None,
                    execute=execute,terminate=terminate,enabled=lambda *_:True)
            output=io.StringIO()
            with patch.object(recording.edit_backend,'Ledger',side_effect=lambda r:ledger_class(r,root=ledger_root)), \
                 patch.object(Path,'home',return_value=home), \
                 patch.object(recording.capture,'ProcessProbe',return_value=Probe()), \
                 patch.object(recording,'run',side_effect=run), \
                 patch.object(sys,'argv',['capture.py','--prepare-recording',str(request_path)]), \
                 contextlib.redirect_stdout(output):
                recording.capture.main()
                first=json.loads(output.getvalue())
                output.seek(0); output.truncate(0)
                recording.capture.main()
                second=json.loads(output.getvalue())
            return dict(events=events,result=first,replay=second,request=request,
                evidence='synthetic dispatch trace; setting/env readback injected; no process spawned')
        finally:
            case.doCleanups()
    return trace.record_canonical_calls(root, preparation=preparation)


class RecordingCalls(unittest.TestCase):
    def run_trace(self, **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            return record(Path(tmp).resolve(),**kwargs)

    def test_actual_dispatch_admission_launch_and_one_shot(self):
        value=self.run_trace()
        self.assertEqual(value['result']['status'],'success')
        self.assertEqual(value['replay']['stage'],'notDispatched')
        events=value['events']
        self.assertEqual(len([e for e in events if e['api']=='check_output']),20) # admission twice
        self.assertEqual(len([e for e in events if e['api']=='signal']),1)
        self.assertEqual([e['argv'] for e in events if e['api']=='run'],[
            ['/usr/bin/xcrun','simctl','launch',value['request']['target']['deviceID'],'test.owned.fixture']])
        self.assertFalse(any(e['api']=='Popen' for e in events))

    def test_uncertain_launch_reconciles_once_without_replay(self):
        value=self.run_trace(uncertain=True)
        self.assertEqual(value['result']['status'],'outcomeUncertain')
        calls=[e for e in value['events'] if e['api']=='run']
        self.assertEqual([e['timeout'] for e in calls],[15,5])
        self.assertEqual(calls[1]['argv'],['/usr/bin/xcrun','simctl','spawn',value['request']['target']['deviceID'],'launchctl','list'])
        self.assertEqual(value['replay']['stage'],'notDispatched')

    def test_live_harness_claim_is_a_real_product_blocker(self):
        value=self.run_trace(claimed=True)
        self.assertEqual(value['result']['stage'],'notDispatched')
        self.assertIn('claimed',value['result']['message'])
        self.assertFalse(any(e['api'] in ('run','signal') for e in value['events']))

    def test_invalid_release_proof_prevents_signal_and_launch(self):
        value=self.run_trace(invalid_release=True)
        self.assertEqual(value['result']['stage'],'notDispatched')
        self.assertFalse(any(e['api'] in ('run','signal') for e in value['events']))

if __name__=='__main__': unittest.main()
