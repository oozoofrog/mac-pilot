"""Full observer replay with real intercepted production request/worker artifacts.

Native rows are synthetic. Prepared-tool and fixture ownership are independently
validated seams; this does not run a UI, Simulator, debugger or target engine.
"""
from contextlib import ExitStack
import hashlib
import json
import os
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import session as s
import test_ui_capture_contract as artifacts_test
import ui_process_contract as integrated
import ui_tool_contract as tools


class IntegratedUI(unittest.TestCase):
    def fixture(self, kind='capture'):
        self.artifacts = artifacts_test.CaptureContract()
        self.artifacts.setUp()
        self.addCleanup(self.artifacts.doCleanups)
        trace = self.artifacts.fixture(kind)
        self.trace = trace
        base = self.artifacts.root
        ui = base / 'check'; ui.write_bytes(b'prepared synthetic UI; never executed')
        self.ui_pid, self.group, self.worker_pid = 200001, 200002, 801
        self.supervisor_pid = os.getpid()
        self.server_pid = 800
        supervisor = dict(self.artifacts.supervisor, parent=self.ui_pid, group=self.supervisor_pid)
        server = dict(self.artifacts.server, group=self.supervisor_pid)
        self.identities = {
            self.group: dict(pid=self.group,parent=1,group=self.group,path='/worker',start=[101,8],state=2),
            self.ui_pid: dict(pid=self.ui_pid,parent=self.group,group=self.group,path=str(ui),start=[101,9],state=2),
            self.supervisor_pid: dict(supervisor,state=2),
            self.server_pid: dict(server,state=2),
            self.worker_pid: dict(pid=self.worker_pid,parent=self.supervisor_pid,group=self.supervisor_pid,
                                 path=sys.executable,start=[101,10],state=2),
        }
        self.argv = {self.ui_pid:[str(ui),'--native-check'], self.supervisor_pid:self.artifacts.argv,
                     self.server_pid:[server['path'],'--fd','7'], self.worker_pid:self.artifacts.worker_argv}
        self.spec = dict(binary=str(ui),capture=str(artifacts_test.trace.RESOURCE/'capture.py'),
                         output=str(base),temporary=str(base),device=trace['request']['target']['deviceID'],
                         toolHashes={},resourcePins={},binarySHA256=hashlib.sha256(ui.read_bytes()).hexdigest())
        self.config = tools.Configuration(tools.DEVELOPER,tuple((p,'synthetic') for p in tools.required_paths()))
        self.ledger_root = base/'observer-ledger';self.ledger_root.mkdir(mode=0o700)
        request=trace['request'];wire=json.loads(Path(self.artifacts.binding.folder,'wire.json').read_text())
        # Synthetic pre-existing operation state, persisted by the actual
        # production final-wire binding/atomic-write path. No target engine.
        edit=artifacts_test.trace.t.c.edit_backend
        ledger=object.__new__(edit.Ledger);ledger.request=request
        ledger.state=dict(schema=2,lifecycleVersion=1,target=request['target'],ownerID=request['ownerID'],
            inspectionID=request['inspectionID'],epoch=wire['targetEpoch'],highWater=request['sequence'],
            operations={request['operationID']:dict(kind=kind,digest=edit.digest(request),
                        sequence=request['sequence'],state='reserved')})
        ledger.path=self.ledger_root/(edit.digest(request['target'])+'.json');ledger.bind_wire(wire)
        self.ledger_path=ledger.path
        return trace

    def add(self, pid, parent, path, argv, group=None):
        self.identities[pid] = dict(pid=pid,parent=parent,group=group or self.supervisor_pid,
                                   path=path,start=[101,pid % 1000000],state=2)
        self.argv[pid] = list(argv)

    def observer(self):
        observer = s.watchdog.ProcessObservation(lambda:0,isolated_probe='/private/test/session-probe',
            probe_python=(sys.executable,),server_path=self.artifacts.server['path'],ui_contract=self.spec)
        observer.ui_process.target = self.trace['request']['target']
        observer.ui_process.target_binding = {'owner':str(uuid.uuid4())}
        observer.ui_process.ledger_root = self.ledger_root
        return observer

    def run_observer(self, observer=None, mutate=None):
        observer = observer or self.observer()
        self.last_observer = observer
        rows = [(v['pid'],v['parent'],v['group'],v['path'],'S') for v in self.identities.values()]
        def identity(pid):
            value = dict(self.identities[pid])
            if mutate:
                mutate(value)
            return value
        with ExitStack() as stack:
            stack.enter_context(patch.object(Path,'is_file',return_value=True))
            stack.enter_context(patch.object(s.watchdog,'rows',return_value=rows))
            stack.enter_context(patch.object(s.watchdog,'identify_live_server',side_effect=identity))
            stack.enter_context(patch.object(s.watchdog,'process_identity',side_effect=identity))
            stack.enter_context(patch.object(s.watchdog,'process_arguments',side_effect=lambda pid:self.argv[pid]))
            stack.enter_context(patch.object(tools.Configuration,'read',return_value=self.config))
            stack.enter_context(patch.object(observer.ui_process,'prepared',return_value=self.artifacts.binding.prepared))
            stack.enter_context(patch.object(observer.ui_process,'owned_fixture',return_value=(
                self.artifacts.binding.app,self.artifacts.binding.data,self.artifacts.binding.bundle)))
            result = observer.complete(self.group,lambda _:None)
        return result

    def test_all_canonical_calls_for_four_operations_and_child_before_parent(self):
        for kind in ('capture','edit','revert','release'):
            with self.subTest(kind=kind):
                self.fixture(kind)
                for event in self.trace['events']:
                    if event['api'] != 'check_output':
                        continue
                    parent = self.worker_pid if event['parentRole']=='worker' else self.supervisor_pid
                    self.add(600,parent,event['argv'][0],event['argv'])
                    self.run_observer()
                    self.assertEqual(self.last_observer.ui_roles[600],'capture-utility')
                    self.assertEqual(self.last_observer.ui_roles[self.worker_pid],'capture-worker')

    def test_simctl_wrapper_pipeline_and_two_display_origins(self):
        self.fixture()
        command = ('/usr/bin/xcrun','simctl','list','devices','--json')
        shell = ('/bin/bash',tools.wrapper('simctl')) + command[2:]
        self.add(600,self.supervisor_pid,'/bin/bash',shell)
        self.add(500,600,'/bin/bash',shell)
        self.add(400,500,'/bin/bash',shell)
        self.add(300,500,'/usr/bin/sort',('sort','--version-sort'))
        self.add(200,500,'/usr/bin/head',('head','-n1'))
        for pid in (900,901):
            output = Path(self.spec['temporary']) / ('mac-cu-displays-'+self.spec['device']+'-'+str(uuid.uuid4())+'.json')
            argv = (tools.resources('devicectl')+'/bin/devicectl','device','info','displays','--device',
                    self.spec['device'],'--quiet','--json-output',str(output))
            self.add(pid,self.ui_pid,argv[0],argv,group=pid)
        self.run_observer()
        self.assertEqual(sum(v=='display' for v in self.last_observer.ui_roles.values()),2)
        self.add(902,self.ui_pid,self.identities[901]['path'],self.argv[901],group=902)
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'budget|concurrency|reused'):
            self.run_observer()

    def test_mutation_unknown_tool_wrong_signature_path_and_extra_origin_reject(self):
        self.fixture()
        bad = [('/usr/bin/xcrun','simctl','boot',self.spec['device']),
               ('/usr/bin/xcodebuild','-runFirstLaunch'),('/usr/bin/codesign','--verify','--strict','/unowned')]
        for argv in bad:
            with self.subTest(argv=argv):
                self.add(600,self.supervisor_pid,argv[0],argv)
                with self.assertRaises(s.watchdog.IdentityChanged):
                    self.run_observer()
        good = ('/usr/bin/xcode-select','-p')
        self.add(600,self.supervisor_pid,good[0],good)
        self.add(601,self.supervisor_pid,good[0],good)
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'capture-utility'):
            self.run_observer()

    def test_changed_worker_files_and_wrong_resource_reject(self):
        self.fixture()
        self.argv[self.worker_pid][2] = str(artifacts_test.trace.RESOURCE/'capture.py')
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'worker argv'):
            self.run_observer()
        self.argv[self.worker_pid][2] = str(artifacts_test.trace.RESOURCE/'resident_transport.py')
        config = Path(self.argv[self.worker_pid][4])/'worker.json'
        value = json.loads(config.read_text()); value['supervisor'] += 1
        config.write_text(json.dumps(value)); config.chmod(0o600)
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'config join'):
            self.run_observer()

    def test_durable_operation_membership_and_wire_hash_are_independent(self):
        self.fixture()
        original=json.loads(self.ledger_path.read_text());operation_id=self.trace['request']['operationID']
        for field,value in [('state','finished'),('digest','0'*64),('wireDigest','0'*64)]:
            state=json.loads(json.dumps(original));state['operations'][operation_id][field]=value
            self.ledger_path.write_text(json.dumps(state));self.ledger_path.chmod(0o600)
            with self.subTest(field=field),self.assertRaisesRegex(s.watchdog.IdentityChanged,'completed|ledger differs|durable final'):
                self.run_observer()
        self.ledger_path.write_text(json.dumps(original));self.ledger_path.chmod(0o600)
        self.run_observer()

    def test_rejection_keeps_native_row_and_no_signal_authority(self):
        self.fixture()
        self.add(600,self.supervisor_pid,'/usr/bin/xcodebuild',('/usr/bin/xcodebuild','-runFirstLaunch'))
        with self.assertRaises(s.watchdog.IdentityChanged):
            self.run_observer()
        event = self.last_observer.events[-1]
        self.assertEqual(event['status'],'observedMismatch')
        self.assertEqual(event['current']['pid'],600)
        self.assertEqual(event['current']['start'],[101,600])
        self.assertFalse(event['signalAuthority'])

    def test_screenshot_and_identity_exact_bindings(self):
        self.fixture()
        capture = self.spec['capture']
        self.add(900,self.ui_pid,sys.executable,(sys.executable,'-I',capture,'--identity',
                 str(self.trace['request']['target']['pid']),self.spec['device']),group=900)
        self.add(901,self.ui_pid,'/usr/sbin/screencapture',('/usr/sbin/screencapture','-x','-o','-l','123',
                 str(Path(self.spec['output'])/'inspector-open.png')),group=901)
        self.run_observer()
        for pid,index,value in [(900,2,'/wrong/capture.py'),(900,4,'999'),(900,5,str(uuid.uuid4())),
                                (901,5,'/private/unowned/inspector-open.png'),(901,4,'0')]:
            old=self.argv[pid][index];self.argv[pid][index]=value
            try:
                with self.subTest(pid=pid,index=index),self.assertRaises(s.watchdog.IdentityChanged):self.run_observer()
            finally:self.argv[pid][index]=old

    def test_native_reuse_and_group_escape_reject(self):
        self.fixture()
        for key,value in [('start',[202,1]),('parent',999),('group',999)]:
            calls={}
            def mutate(info):
                pid=info['pid'];calls[pid]=calls.get(pid,0)+1
                if pid == self.worker_pid and calls[pid] >= 2:info[key]=value
            with self.subTest(key=key),self.assertRaises(s.watchdog.IdentityChanged):
                self.run_observer(mutate=mutate)

    def test_forward_exec_is_semantic_and_reverse_is_rejected(self):
        self.fixture()
        command=('/usr/bin/xcrun','simctl','list','devices','--json')
        path=tools.resources('simctl')+'/bin/simctl'
        self.add(600,self.supervisor_pid,path,(path,)+command[2:])
        observer=self.observer()
        observer.ui_process.histories[600]=['/usr/bin/xcrun','/bin/bash',path]
        self.run_observer(observer)
        observer=self.observer();observer.ui_process.histories[600]=['/usr/bin/xcrun','/bin/zsh',path]
        with self.assertRaisesRegex(s.watchdog.IdentityChanged,'exec history'):self.run_observer(observer)
        old=self.identities[600]
        self.assertFalse(observer.ui_process.allow_exec(600,old,dict(old,path='/usr/bin/xcrun')))

    def test_owner_target_device_and_data_metadata_join(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary).resolve();device=str(uuid.uuid4()).upper();owner=str(uuid.uuid4())
            device_root=base/'Devices'/device
            app=device_root/'data/Containers/Bundle/Application'/str(uuid.uuid4())/'Fixture.app'
            data=device_root/'data/Containers/Data/Application'/str(uuid.uuid4())
            app.mkdir(parents=True);data.mkdir(parents=True)
            (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='test.fixture',CFBundleExecutable='Fixture')))
            metadata=data/'.com.apple.mobile_container_manager.metadata.plist'
            metadata.write_bytes(plistlib.dumps(dict(MCMMetadataIdentifier='test.fixture')))
            target=dict(pid=123,start=[101,7],path=str(app/'Fixture'),deviceID=device)
            request=dict(target,fixtureSession=owner,documents=str(data/'Documents'),output=str(base))
            request_path=base/'ui-request.json';request_path.write_text(json.dumps(request));request_path.chmod(0o600)
            def contract():
                return integrated.Contract(dict(output=str(base),device=device),(sys.executable,),'/server',
                                           target,dict(owner=owner),lambda:None)
            c=contract();c.fixture=None;c.file_pins=[]
            self.assertEqual(c.owned_fixture(),(str(app),str(data),'test.fixture'))
            metadata.write_bytes(plistlib.dumps(dict(MCMMetadataIdentifier='foreign.fixture')))
            c=contract();c.fixture=None;c.file_pins=[]
            with self.assertRaisesRegex(integrated.Rejected,'data container bundle'):c.owned_fixture()
            request['fixtureSession']=str(uuid.uuid4());request_path.write_text(json.dumps(request))
            c=contract();c.fixture=None;c.file_pins=[]
            with self.assertRaisesRegex(integrated.Rejected,'owner/target'):c.owned_fixture()


if __name__ == '__main__':
    unittest.main()
