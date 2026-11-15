"""Production serialization/Ledger + actual session/observer replay; no guest or UI.

Only native observations, target payloads and subprocess boundaries are controlled.
All recorded PIDs are synthetic; no device/claim state outside this private tree.
"""
from contextlib import ExitStack, closing
from dataclasses import replace
import copy
import errno
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import time
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent), str(HERE.parent / 'view-hierarchy-prototype')]
sys.path.insert(0, str(HERE.parent / 'simulator-inspector-product-live'))
from recording_writer_check import RecordingWriter
import session as s
import recording_owner as owner
import recording_session as fixture
import ui_recording_contract as recording
import ui_process_contract as process
import ui_capture_contract as a
import ui_tool_contract as tools
import test_ui_capture_contract as artifacts
import test_view_edit_backend as backend
import resident_transport
import native_check_support as safety


def put(path, value):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fixture.private_write(path, value, replace=True)


class RecordingIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = Path(os.environ.get('MAC_CU_RECORDING_EVIDENCE', tempfile.mkdtemp(prefix='mac-cu-recording-integration-serializer-', dir='/private/tmp')))
        cls.evidence.mkdir(exist_ok=True)
        cls.bridge_writer = RecordingWriter(cls.evidence / 'ui-bridge-writer')
        source = HERE.parents[1] / 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorViews.swift'
        text = source.read_text(); start = text.index('    let wire: [String: Any]', text.index('func simulatorPrepareSwiftUIRecording'))
        end = text.index('    var result =', start)
        serializer = text[start:end]
        main = '''import Foundation
import Darwin
struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }
guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"],
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
umask(0o022)
let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SERIALIZER_INPUT"]!))) as! [String: Any]
let target = (json: input["target"] as! [String: Any], ignored: false)
let raw = input["scope"] as! [String: Any]
let scope = (deviceID: raw["deviceID"]!, deviceLifetime: raw["bootIdentity"]!, presentation: raw["presentation"]!, generation: raw["generation"]!, runtime: raw["runtime"]!)
let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SERIALIZER_OUTPUT"]!)
SERIALIZER
print("PASS verbatim production preparation serializer")
'''.replace('SERIALIZER\n', serializer)
        swift = cls.evidence / 'main.swift'; swift.write_text(main)
        cls.binary = cls.evidence / 'serializer'
        with (cls.evidence / 'serializer-compile.log').open('w') as log:
            subprocess.run(['xcrun','swiftc',str(swift),'-o',str(cls.binary)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        with (cls.evidence / 'serializer-guards.log').open('w') as log:
            safety.check_routes(cls.binary, dict(os.environ), log, production_helper=False)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='recording-data-'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        seed = artifacts.CaptureContract(); seed.setUp(); self.addCleanup(seed.doCleanups); seed.fixture()
        _, recording_pin = a.read_file(artifacts.trace.RESOURCE / 'recording_preparation.py', private=False)
        self.prepared = replace(seed.binding.prepared, files=seed.binding.prepared.files + (recording_pin,))
        developer = Path(json.loads(self.prepared.build_json)['developer'])
        setting = developer.parent / 'PlugIns/DebuggerUI.framework/Versions/A/Resources/DebuggerUI.xcplugindata'
        setting.parent.mkdir(parents=True)
        shutil.copyfile('/Applications/Xcode.app/Contents/PlugIns/DebuggerUI.framework/Versions/A/Resources/DebuggerUI.xcplugindata', setting)
        self.device = str(uuid.uuid4()).upper()
        device_root = self.root / 'devices' / self.device
        self.app = device_root / 'data/Containers/Bundle/Application' / str(uuid.uuid4()) / 'Fixture.app'
        self.data = device_root / 'data/Containers/Data/Application' / str(uuid.uuid4())
        self.app.mkdir(parents=True); (self.data / 'Documents').mkdir(parents=True)
        self.bundle = 'test.owned.fixture'
        self.exe = self.app / 'Fixture'; self.exe.write_bytes(b'owned synthetic executable, never executed')
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Fixture', CFBundleIdentifier=self.bundle)))
        (self.data / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(plistlib.dumps(dict(MCMMetadataIdentifier=self.bundle)))
        self.old = dict(pid=123, start=[100,1], path=str(self.exe), deviceID=self.device)
        self.new = dict(self.old, pid=124, start=[102,2])
        self.scope = dict(deviceID=self.device, bootIdentity=self.device+':99:90:1:'+str(self.root/'launchd_sim'), presentation='main|rot0', generation=1, runtime='27.2|24B114')
        self.ui_pid, self.group, self.helper_pid = 200001, 200002, 200003
        self.ui = self.root / 'ui'; self.ui.write_bytes(b'owned UI, never executed')
        self.native = {}
        self.argv = {}
        self.add(os.getpid(), 1, str(Path(sys.executable).resolve()), group=os.getpid())
        self.add(self.group, os.getpid(), str(Path(sys.executable).resolve()), group=self.group)
        self.add(99, 1, str(self.root/'launchd_sim'), group=99, start=[90,1])
        self.add(123,99,str(self.exe), group=123, start=self.old['start'])
        self.add(self.ui_pid,self.group,str(self.ui), group=self.group, argv=[str(self.ui),'--native-check'])
        self.add(self.helper_pid,self.ui_pid,self.prepared.python, group=self.helper_pid)
        self.binding = dict(version=1, owner=str(uuid.uuid4()).upper(), worker=s.watchdog.lifetime(self.native[self.group]),
            target=self.old, group=123, originalParent=s.watchdog.lifetime(self.native[99]))
        self.ledger_root = self.root / 'home/Library/Application Support/mac-cu/view-edit-ledger'
        self.capture = self.make_ledger(self.old)
        self.ready = dict(target=self.old, scope=self.scope, captureID=self.capture['captureID'], ownerID=self.capture['ownerID'],
            inspectionID=self.capture['inspectionID'], epoch=self.capture['targetEpoch'], selector='prepareRecordingNow',
            disclosure='현재 실행 상태가 사라집니다. 기존 실행 인자와 환경 변수는 복원되지 않습니다.')
        self.folder = self.root / ('mac-cu-views-' + str(uuid.uuid4()).upper()); self.folder.mkdir(mode=0o700)
        input_file = self.root / 'serializer-input.json'; put(input_file,dict(target=self.old,scope=self.scope))
        self.request_path = self.folder / 'recording-request.json'
        with (self.evidence / 'serializer-runs.log').open('a') as log:
            env = dict(os.environ, SERIALIZER_INPUT=str(input_file), SERIALIZER_OUTPUT=str(self.request_path))
            self.assertEqual(safety.run_owned(self.binary,['--native-check'],environment=env,log=log,timeout=5,max_instances=1),0)
        self.assertEqual(self.request_path.stat().st_mode & 0o777, 0o600)
        self.request = a.read_json(self.request_path,[])
        self.argv[self.helper_pid] = [self.prepared.python,'-I',str(artifacts.trace.RESOURCE/'capture.py'),'--prepare-recording',str(self.request_path)]
        self.spec = dict(binary=str(self.ui), binarySHA256=a.digest(self.ui.read_bytes()), capture=str(artifacts.trace.RESOURCE/'capture.py'),
            output=str(self.root), temporary=str(self.root), device=self.device, resourcePins={}, toolHashes={})
        put(self.root/'ui-request.json',dict(self.old,fixtureSession=self.binding['owner'],output=str(self.root),documents=str(self.data/'Documents')))
        self.installation = fixture.Installation.read(self.old,self.data,self.bundle)
        self.entry = self.data / '.recording-entry-v1'; self.entry.mkdir(mode=0o700)
        capsule = dict(version=1,session=self.binding['owner'],identity=self.installation.identity,
            oldTarget=dict(pid=123,startSeconds=100,startMicroseconds=1))
        put(self.entry/'bootstrap.json',capsule)
        self.claim_path = self.root/'claims.json'; self.claim = dict(pid=self.group,by=self.binding['owner'],note='owned',since='2026-11-10T00:00:00Z')
        put(self.claim_path,{self.device:self.claim,'FOREIGN':dict(pid=9,by='other')})
        self.now = 10.0
        self.arm = fixture.Arm(session=self.binding['owner'],target=self.old,installation=self.installation,deadline=200,
            check=lambda:None,clock=lambda:self.now,wall=lambda:1000+self.now)
        self.arm.arm()
        self.pending = dict(version=1,restartID=self.arm.restart_id,session=self.binding['owner'],oldTarget=capsule['oldTarget'],identity=self.installation.identity,
            issuedUnixSeconds=1010.0,expiresUnixSeconds=1070.0,issuedUptime=500.0,expiresUptime=560.0)
        # Guest sorted-key bytes deliberately differ from host canonical bytes.
        self.pending_raw = json.dumps(self.pending, sort_keys=True, indent=1).encode()
        with os.fdopen(os.open(self.entry/'restart.pending.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(self.pending_raw)
        self.receipt = dict(version=1,status='armed',restartID=self.arm.restart_id,pendingSHA256=a.digest(self.pending_raw),pending=self.pending)
        self.assertTrue(self.arm.acknowledge(dict(restartReceipt=self.receipt)))
        self.declaration = dict(version=1,binding=self.binding,ready=self.ready,parent=s.watchdog.lifetime(self.native[os.getpid()]),
            installation=self.installation.wire(),claim=self.claim,claimPath=str(self.claim_path),deadline=200,expires=70,restartID=self.arm.restart_id,receipt=self.receipt)
        put(self.root/'recording-session.json',self.declaration)
        action = dict(restartID=self.arm.restart_id,selector='prepareRecordingNow',method='NSButton.performClick',target=self.old,
            enabled=True,visible=True,controllerTarget=True,physicalClick=False)
        self.assertEqual(self.bridge_writer.publish(self.root, {'recording-ready.json': self.ready,
            'recording-action.json': action}), 0)
        self.assertEqual(a.read_json(self.root/'recording-ready.json', []), self.ready)
        self.assertEqual(a.read_json(self.root/'recording-action.json', []), action)
        cleanup_resource=self.root/'cleanup-resources';cleanup_resource.mkdir()
        shutil.copy2(Path(self.prepared.resident_resource)/'resident-build.json',cleanup_resource/'resident-build.json')
        self.cleanup_spec=dict(self.spec,capture=str(cleanup_resource/'capture.py'))
        self.config = tools.Configuration(tools.DEVELOPER,tuple((p,'controlled') for p in tools.required_paths()))
        self.probe = SimpleNamespace(identity=self.device_identity, status=self.status)
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(s.capture,'ProcessProbe',return_value=self.probe))
        self.stack.enter_context(patch.object(s.watchdog,'process_identity',side_effect=self.identity))
        self.stack.enter_context(patch.object(s.watchdog,'process_status',side_effect=self.status))
        self.stack.enter_context(patch.object(s.watchdog,'process_arguments',side_effect=lambda pid:self.argv[pid]))
        self.stack.enter_context(patch.object(s.watchdog,'identify_live_server',side_effect=lambda pid:self.identity(pid) if pid in self.native else None))
        self.stack.enter_context(patch.object(s.watchdog.os,'kill',side_effect=self.kill0))
        self.stack.enter_context(patch.object(tools.Configuration,'read',return_value=self.config))
        self.stack.enter_context(patch.object(process.Contract,'prepared',return_value=self.prepared))
        self.stack.enter_context(patch.object(recording.product(self.prepared),'recording_enabled',return_value=True))
        # product() loads a fresh pure schema module; only the native environment seam is controlled.
        real_product = recording.product
        def product(prepared):
            module = real_product(prepared); module.recording_enabled=lambda *_: self.enabled
            return module
        self.enabled=True
        self.stack.enter_context(patch.object(recording,'product',side_effect=product))
        self.owner = owner.Owner(s,self.root,self.declaration,self.binding,lambda:None,lambda:self.now)

    def make_ledger(self,target):
        edit = backend.edit
        captured = None
        for sequence,kind in [(1,'capture'),(2,'release')]:
            request = dict(schemaVersion=2,kind=kind,target=target,validationOnly=False,ownerID=self.capture_owner if captured else str(uuid.uuid4()).upper(),
                inspectionID=self.capture_inspection if captured else str(uuid.uuid4()).upper(),operationID=str(uuid.uuid4()).upper(),sequence=sequence,
                targetEpoch=captured['targetEpoch'] if captured else None)
            if captured: request.update(captureID=captured['captureID'],reason='close')
            else: request.update(replaceCaptureID=None,inspectionScope=dict(self.scope,displayID='main'))
            folder = self.root / ('mac-cu-views-'+str(uuid.uuid4()).upper()); folder.mkdir(mode=0o700)
            with closing(edit.Ledger(request,self.ledger_root)) as ledger:
                self.assertIsNone(ledger.reserve()); wire=ledger.wire(str(uuid.uuid4()).upper()); ledger.bind_wire(wire)
                result = backend.capture_payload(wire) if kind=='capture' else edit.receipt(wire,'success','released','notApplicable')
                result.update(target=target,validationOnly=False,ownerID=wire['ownerID'],inspectionID=wire['inspectionID'],targetEpoch=wire['targetEpoch'],
                    requestDigest=edit.digest(request),evidenceDirectory=str(folder),captureID=wire['newCaptureID'] if kind=='capture' else request['captureID'])
                cleanup={}
                engine=SimpleNamespace(active_call=None,detach=lambda:'success',close=lambda:None)
                self.assertTrue(resident_transport.finish_engine(engine,cleanup))
                self.assertTrue(resident_transport.finish_children(None,None,cleanup))
                cleanup['recovery']=dict(verified=True); result['cleanup']=cleanup
                if kind=='capture':
                    result['inspectionScope']=request['inspectionScope']
                    captured=result; self.capture_owner=wire['ownerID']; self.capture_inspection=wire['inspectionID']
                else:
                    result.update(registryReleased=True,remainingOwnedEntries=0,residualState='tombstone',needsRefresh=False,
                        releaseProof={k:wire[k] for k in ('ownerID','inspectionID','targetEpoch','captureID','operationID','requestDigest','sequence','entryTransitionID')})
                ledger.finish(result)
            for name,value in [('request.json',request),('wire.json',wire),('result.json',result)]:put(folder/name,value)
        return captured

    def add(self,pid,parent,path,*,group=None,start=None,argv=None):
        self.native[pid]=dict(pid=pid,parent=parent,group=group or self.helper_pid,path=path,start=start or [101,pid%1000000],state=2)
        self.argv[pid]=argv or [path]

    def identity(self,pid):
        if pid not in self.native:raise s.watchdog.IdentityReadError('absent',None,'proc_pidinfo',0,errno.ESRCH)
        return dict(self.native[pid])

    def status(self,pid):return self.identity(pid)
    def device_identity(self,pid,device=False):return dict(self.identity(pid),deviceID=self.device,traced=False)
    def kill0(self,pid,sig):
        self.assertEqual(sig,0,'no signal dispatch is authorized in replay')
        if pid not in self.native:raise ProcessLookupError(errno.ESRCH,'absent')

    def rows(self):return [(v['pid'],v['parent'],v['group'],v['path'],'Z' if v['state']==5 else 'S') for v in self.native.values()]

    def observe(self):
        options=dict(isolated_probe=str(self.root/'session-probe'),probe_python=(self.prepared.python,),ui_contract=self.spec)
        actual=s.watchdog.ProcessObservation
        elapsed=[0.0]
        started=time.monotonic()
        def clock():
            elapsed[0] += getattr(self,'observation_step',0)
            return self.now + elapsed[0] + time.monotonic()-started
        def observation(*args,**kwargs):
            value=actual(*args,**kwargs);value.ui_process.ledger_root=self.ledger_root;self.last=value;return value
        with patch.object(s,'monotonic',side_effect=clock),patch.object(s,'probe_family_options',return_value=options), \
             patch.object(s.watchdog,'rows',side_effect=lambda **_:self.rows()),patch.object(s.watchdog,'ProcessObservation',side_effect=observation):
            return s.observe_processes(self.group,self.owner.cursor.binding['target'],self.root,Path('/owned/debugserver'),{},100,
                target_binding=self.owner.cursor.binding,recording_owner=self.owner)

    def marker(self,stage):put(self.ledger_root/(backend.edit.digest(self.old)+'.recording'),dict(stage=stage,target=self.old))
    def gap(self):
        self.observe();self.marker('terminationDispatch');self.native.pop(123);self.observe()
        self.assertEqual(self.owner.cursor.phase,'gap')
    def launch(self):
        self.marker('launchDispatch')
        self.add(600,self.helper_pid,'/usr/bin/xcrun',argv=['/usr/bin/xcrun','simctl','launch',self.device,self.bundle])
        self.observe()
    def successor(self):
        self.native.pop(600,None);self.native.pop(self.helper_pid,None)
        self.add(124,99,str(self.exe),group=124,start=self.new['start'])
        (self.entry/'restart.pending.json').rename(self.entry/'restart.consumed.json')
        with os.fdopen(os.open(self.entry/'restart.spent', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(b'spent-v1')
        put(self.data/'Documents/edit-oracle.json',dict(startupMode='recordingRestart',restartID=self.arm.restart_id,
            oldTarget=self.pending['oldTarget'],currentPID=124,graphOracleCalls=0))
    def result(self,status='success'):
        put(self.folder/'result.json',dict(status=status,stage='newLifetimeBound' if status=='success' else 'launchDispatch',target=self.new))

    def test_positive_real_session_observer_cursor_and_cleanup_selection(self):
        self.gap();self.launch();self.successor();self.result();self.observe()
        self.assertEqual(self.owner.cursor.phase,'admitted');self.assertEqual(self.owner.cursor.revision,1)
        self.assertEqual(self.owner.cursor.binding['target'],self.new)
        self.assertEqual(len(self.owner.cursor.histories),2)
        publication=a.read_json(self.root/'recording-cursor.json',[])
        self.assertEqual(publication['release']['target'],self.old)
        self.assertEqual(publication['binding']['target'],self.new)
        self.assertEqual(self.last.target,self.new)
        worker=object.__new__(owner.Worker);worker.s=s;worker.out=self.root;worker.parent=self.declaration['parent'];worker.binding=self.binding
        worker.target=self.old;worker.installation=self.installation;worker.claim=SimpleNamespace(check=lambda:None);worker.fresh=lambda **_:None;worker.check=lambda:None;worker.deadline=200
        self.make_ledger(self.new)
        with patch.object(s,'monotonic',return_value=10), patch.object(s,'UI_PROCESS_CONTRACT',self.cleanup_spec), patch.object(Path,'home',return_value=self.root/'home'), patch.object(s.watchdog,'rows',return_value=self.rows()):
            with self.assertRaisesRegex(a.ContractError,'child remains'):worker.cleanup_binding()
            self.native.pop(self.ui_pid)
        with patch.object(s,'monotonic',return_value=10), patch.object(s,'UI_PROCESS_CONTRACT',self.cleanup_spec), patch.object(Path,'home',return_value=self.root/'home'), patch.object(s.watchdog,'rows',return_value=self.rows()):
            self.assertEqual(worker.cleanup_binding()['target'],self.new)
        self.assertEqual(a.read_json(self.claim_path,[],private=False)[self.device],self.claim)

    def test_all_actual_admission_commands_without_marker(self):
        self.observe()
        for command in self.owner.cursor.preparation.admission_commands():
            self.add(600,self.helper_pid,command[0],argv=list(command));self.observe();self.native.pop(600)
        self.assertEqual(self.owner.cursor.phase,'preparing')
        self.assertFalse((self.root/'recording-cursor.json').exists())

    def test_changed_request_scope_marker_wire_receipt_owner_and_epoch(self):
        cases=[(self.request_path,'explicitClick',False),(self.request_path,'scope',dict(self.scope,generation=2))]
        state_path=self.ledger_root/(backend.edit.digest(self.old)+'.json')
        state=a.read_json(state_path,[])
        release=state['releaseProof']['operationID']; full=Path(state['results'][release]['evidenceDirectory'])/'result.json'
        wire=Path(state['results'][release]['evidenceDirectory'])/'wire.json'
        cases += [(full,'ownerID',str(uuid.uuid4()).upper()),(full,'targetEpoch',str(uuid.uuid4()).upper()),
                  (full,'cleanup',dict(childrenReaped=True)),(wire,'sequence',99)]
        for path,key,value in cases:
            original=path.read_bytes();v=json.loads(original);v[key]=value;put(path,v)
            with self.subTest(path=path.name,key=key),self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):
                self.observe()
            path.write_bytes(original)
        self.observe();self.marker('terminationDispatch');self.observe()
        self.marker('launchDispatch');self.observe();self.marker('terminationDispatch')
        with self.assertRaisesRegex(a.ContractError,'regressed'):self.observe()

    def test_missing_release_and_active_call_are_refused(self):
        state_path=self.ledger_root/(backend.edit.digest(self.old)+'.json')
        original=state_path.read_bytes();state=json.loads(original);state['authority']='revoked';put(state_path,state)
        with self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()
        state_path.write_bytes(original);state=json.loads(original)
        for stored in state['results'].values():
            path=Path(stored['evidenceDirectory'])/'result.json';value=json.loads(path.read_text());value['cleanup']['activeCall']='submission';put(path,value)
        with self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()

    def test_wrong_argv_orphan_worker_debugger_duplicate_and_capture_overlap(self):
        self.observe()
        tests=[(600,self.helper_pid,'/usr/bin/xcrun',['/usr/bin/xcrun','simctl','boot',self.device]),
            (600,self.helper_pid,self.prepared.python,[self.prepared.python,'-I',str(artifacts.trace.RESOURCE/'resident_transport.py'),'--worker','/tmp/x','7']),
            (600,self.ui_pid,self.prepared.python,self.argv[self.helper_pid]),
            (600,self.helper_pid,'/wrong/Xcode/simctl',['simctl','launch',self.device,self.bundle])]
        for pid,parent,path,argv in tests:
            self.add(pid,parent,path,group=pid if parent==self.ui_pid else self.helper_pid,argv=argv)
            with self.subTest(argv=argv),self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()
            self.native.pop(pid)
        self.native[self.helper_pid]['parent']=1
        with self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()

    def test_zombie_denied_old_and_candidate_before_gap_refuse(self):
        self.observe();self.marker('terminationDispatch');self.native[123]['state']=5
        # Controlled cutoff prevents any unbounded retry in the test.
        self.observation_step=.02
        with self.assertRaises((TimeoutError,a.ContractError,s.watchdog.IdentityChanged)):self.observe()
        self.observation_step=0
        self.native.pop(123);self.add(124,99,str(self.exe),group=124,start=self.new['start'])
        with self.assertRaisesRegex(a.ContractError,'before exited gap'):self.observe()

    def test_same_pid_and_duplicate_successor_are_refused(self):
        self.gap();self.launch();self.native.pop(600)
        self.add(123,99,str(self.exe),group=123,start=[200,1])
        with self.assertRaisesRegex(a.ContractError,'PID reused'):self.observe()
        self.native.pop(123);self.add(124,99,str(self.exe),group=124,start=self.new['start'])
        self.add(125,99,str(self.exe),group=125,start=[201,1])
        with self.assertRaises((a.ContractError,RuntimeError)):self.observe()

    def test_uncertain_result_and_ui_exit_retain_candidate_without_capture(self):
        self.gap();self.launch();self.successor();self.result('outcomeUncertain');self.native.pop(self.ui_pid)
        self.observe()
        self.assertEqual(self.owner.cursor.phase,'custodyOnly')
        self.assertFalse(a.read_json(self.root/'recording-cursor.json',[])['phase']=='admitted')
        with self.assertRaisesRegex(a.ContractError,'unknown launch'):self.owner.cleanup_binding()

    def test_candidate_before_result_cannot_publish_or_capture(self):
        self.gap();self.launch();self.successor();self.observe()
        self.assertEqual(self.owner.cursor.phase,'candidate');self.assertIsNotNone(self.owner.cursor.candidate)
        self.assertFalse((self.root/'recording-cursor.json').exists())
        self.result();self.observe();self.assertEqual(self.owner.cursor.phase,'admitted')

    def test_launch_and_reconciliation_cannot_overlap_or_repeat(self):
        self.gap();self.launch()
        self.add(601,self.helper_pid,'/usr/bin/xcrun',argv=['/usr/bin/xcrun','simctl','spawn',self.device,'launchctl','list'])
        with self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()
        self.native.pop(600);self.observe();self.native.pop(601)
        self.add(602,self.helper_pid,'/usr/bin/xcrun',argv=['/usr/bin/xcrun','simctl','launch',self.device,self.bundle])
        with self.assertRaises((a.ContractError,s.watchdog.IdentityChanged)):self.observe()

    def test_executable_hash_drift_is_refused_even_after_bytes_restored(self):
        original=self.exe.read_bytes();self.exe.write_bytes(original+b'changed')
        with self.assertRaisesRegex(a.ContractError,'stale binding'):self.observe()
        self.exe.write_bytes(original)
        with self.assertRaisesRegex(a.ContractError,'stale binding'):self.observe()

    def test_info_plist_drift(self):
        (self.app/'Info.plist').write_bytes(b'changed')
        with self.assertRaisesRegex(a.ContractError,'stale binding'):self.observe()

    def test_data_mcm_drift(self):
        (self.data/'.com.apple.mobile_container_manager.metadata.plist').write_bytes(b'changed')
        with self.assertRaisesRegex(a.ContractError,'stale binding'):self.observe()

    def test_data_directory_replacement(self):
        self.data.rename(self.data.with_name('preserved'));(self.data/'Documents').mkdir(parents=True)
        with self.assertRaises(a.ContractError):self.observe()

    def test_boot_lifetime_drift(self):
        self.native[99]['start']=[200,1]
        with self.assertRaises(s.capture.CaptureError):self.observe()

    def test_exact_claim_drift_preserves_foreign_claim(self):
        claims=a.read_json(self.claim_path,[],private=False);claims[self.device]['by']='changed';put(self.claim_path,claims)
        with self.assertRaisesRegex(a.ContractError,'held claim changed'):self.observe()
        self.assertEqual(a.read_json(self.claim_path,[],private=False)['FOREIGN'],dict(pid=9,by='other'))

    def test_action_selector_and_disclosure_binding(self):
        action=a.read_json(self.root/'recording-action.json',[]);action['selector']='captureNow';put(self.root/'recording-action.json',action)
        with self.assertRaisesRegex(a.ContractError,'provenance'):self.observe()

    def test_original_host_deadline_not_guest_uptime(self):
        self.now=201
        with self.assertRaisesRegex((a.ContractError,TimeoutError),'deadline|cutoff'):self.observe()
        self.assertEqual(self.pending['issuedUptime'],500)

    def test_denied_old_native_never_becomes_exited_gap(self):
        self.observe();self.marker('terminationDispatch');self.observation_step=.02
        original=self.status
        def status(pid):
            if pid==123:raise s.watchdog.IdentityReadError('denied',None,'proc_pidinfo',0,errno.EACCES)
            return original(pid)
        with patch.object(s.watchdog,'process_status',side_effect=status), self.assertRaises(TimeoutError):self.observe()
        self.assertEqual(self.owner.cursor.phase,'preparing')

    def test_success_result_before_startup_stays_candidate(self):
        self.gap();self.launch();self.successor();self.result()
        put(self.data/'Documents/edit-oracle.json',dict(startupMode='initial',restartID=None,oldTarget=self.pending['oldTarget'],currentPID=123,graphOracleCalls=0))
        self.observe();self.assertEqual(self.owner.cursor.phase,'candidate')
        self.assertFalse((self.root/'recording-cursor.json').exists())
        put(self.data/'Documents/edit-oracle.json',dict(startupMode='recordingRestart',restartID=self.arm.restart_id,oldTarget=self.pending['oldTarget'],currentPID=124,graphOracleCalls=0))
        self.observe();self.assertEqual(self.owner.cursor.phase,'admitted')

    def test_pending_bytes_hash_not_host_reserialization(self):
        self.assertNotEqual(a.digest(a.canonical(self.pending).encode()), self.receipt['pendingSHA256'])
        self.assertEqual(self.arm.pending_pin.sha256,self.receipt['pendingSHA256'])
        (self.entry/'restart.pending.json').write_bytes(a.canonical(self.pending).encode())
        with self.assertRaisesRegex(a.ContractError,'pending changed'):self.arm.dispatch()

    def test_env_missing_and_result_mismatch_cannot_grant_capture(self):
        self.gap();self.launch();self.successor();self.result();self.enabled=False
        with self.assertRaisesRegex(a.ContractError,'env287'):self.observe()
        self.enabled=True
        value=a.read_json(self.folder/'result.json',[]);value['target']['pid']=999;put(self.folder/'result.json',value)
        with self.assertRaisesRegex(a.ContractError,'differs|changed'):self.observe()

    def test_ui_exit_with_success_result_retains_custody_only(self):
        self.gap();self.launch();self.successor();self.result();self.native.pop(self.ui_pid)
        self.observe();self.assertEqual(self.owner.cursor.phase,'custodyOnly')
        self.assertEqual(self.owner.cursor.candidate['target'],self.new)

    def test_recreated_host_arm_cannot_refresh_existing_pending(self):
        another=fixture.Arm(session=self.binding['owner'],target=self.old,installation=self.installation,deadline=999,
            check=lambda:None,clock=lambda:10,wall=lambda:1010)
        with self.assertRaisesRegex(a.ContractError,'budget already used'):another.arm()
        with self.assertRaisesRegex(a.ContractError,'refreshed'):another.arm()
        self.assertEqual((self.entry/'restart.pending.json').read_bytes(),self.pending_raw)

    def test_successor_full_receipt_is_separate_and_required_for_cleanup(self):
        self.gap();self.launch();self.successor();self.result();self.observe();self.make_ledger(self.new)
        release=recording.released_ledger(self.prepared,self.new,self.ledger_root,self.root)
        self.assertEqual(json.loads(release.state_json)['target'],self.new)
        old=recording.released_ledger(self.prepared,self.old,self.ledger_root,self.root)
        self.assertNotEqual(release.state_json,old.state_json)
        state=json.loads(release.state_json);operation=state['releaseProof']['operationID']
        full=Path(state['results'][operation]['evidenceDirectory'])/'result.json'
        value=json.loads(full.read_text());value['cleanup']['debuggerClosed']=False;put(full,value)
        with self.assertRaisesRegex(a.ContractError,'quiescence'):
            recording.released_ledger(self.prepared,self.new,self.ledger_root,self.root)
        recording.released_ledger(self.prepared,self.old,self.ledger_root,self.root)

    def worker_before_arm(self):
        # A separate pristine synthetic data container; earlier arm artifacts stay intact.
        data=self.data.parent/str(uuid.uuid4());(data/'Documents').mkdir(parents=True)
        shutil.copyfile(self.data/'.com.apple.mobile_container_manager.metadata.plist',data/'.com.apple.mobile_container_manager.metadata.plist')
        installation=fixture.Installation.read(self.old,data,self.bundle)
        entry=data/'.recording-entry-v1';entry.mkdir(mode=0o700)
        put(entry/'bootstrap.json',dict(version=1,session=self.binding['owner'],identity=installation.identity,oldTarget=self.pending['oldTarget']))
        out=self.root/'worker-out';out.mkdir(mode=0o700)
        put(out/'target-observation.json',self.binding)
        self.assertEqual(self.bridge_writer.publish(out, {'recording-ready.json': self.ready}), 0)
        put(data/'Documents/edit-oracle.json',dict(restartReceipt={}))
        claim=SimpleNamespace(owner=self.claim,path=self.claim_path,check=lambda:None)
        real_arm=fixture.Arm
        self.stack.enter_context(patch.object(fixture,'Arm',side_effect=lambda **kw:real_arm(**kw,wall=lambda:1010)))
        self.stack.enter_context(patch.object(s,'monotonic',return_value=10))
        with patch.object(s,'BUNDLE',self.bundle),patch.object(owner.os,'getppid',return_value=os.getpid()):
            worker=owner.Worker(s,out,self.old,data,claim,200,lambda:None)
        return worker,data,entry,out

    def worker_ack(self,worker,data,entry):
        pending=dict(self.pending,restartID=worker.arm.restart_id,identity=worker.installation.identity)
        raw=json.dumps(pending,sort_keys=True,indent=1).encode()
        with os.fdopen(os.open(entry/'restart.pending.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(raw)
        receipt=dict(version=1,status='armed',restartID=worker.arm.restart_id,pendingSHA256=a.digest(raw),pending=pending)
        put(data/'Documents/edit-oracle.json',dict(restartReceipt=receipt))
        return receipt

    def test_actual_worker_waits_for_guest_receipt_and_parent_before_click_permission(self):
        worker,data,entry,out=self.worker_before_arm()
        worker.tick();self.assertEqual(worker.arm.state,'arming')
        self.assertFalse((out/'recording-session.json').exists())
        receipt=self.worker_ack(worker,data,entry);worker.tick()
        self.assertEqual(worker.arm.state,'armed');self.assertFalse((out/'recording-click-ready.json').exists())
        declaration=a.read_json(out/'recording-session.json',[])
        self.assertEqual(declaration['receipt'],receipt)
        owner.Owner(s,out,declaration,self.binding,lambda:None,lambda:10)
        worker.tick();self.assertEqual(worker.arm.state,'dispatchUnknown')
        self.assertTrue((out/'recording-click-ready.json').is_file())
        self.assertFalse((out/'recording-action.json').exists(),'worker must never perform a UI action')
        self.assertFalse((self.ledger_root/(backend.edit.digest(self.old)+'.recording')).exists())

    def test_actual_worker_before_dispatch_cancellation_drains_receipt(self):
        worker,data,entry,out=self.worker_before_arm();worker.tick()
        self.assertFalse(worker.cancel_before_dispatch())
        receipt=self.worker_ack(worker,data,entry)
        self.assertFalse(worker.cancel_before_dispatch());self.assertEqual(worker.arm.state,'cancelling')
        put(data/'Documents/edit-oracle.json',dict(restartReceipt=dict(version=1,status='cancelled',restartID=worker.arm.restart_id,pendingSHA256=receipt['pendingSHA256'])))
        self.assertTrue(worker.cancel_before_dispatch());self.assertEqual(worker.arm.state,'cancelled')
        self.assertTrue(worker.cancel_before_dispatch());self.assertFalse(worker.arm.control.exists())

    def test_numeric_budgets_remain_exact(self):
        import importlib.util
        names=('TOTAL','WORK','GRACE','CAPTURE_ADMISSION','BUNDLE','APP_NAME','EXECUTABLE');old={k:getattr(s,k) for k in names}
        try:
            spec=importlib.util.spec_from_file_location('recording_budget_runner',HERE.parent/'simulator-inspector-product-live/runner.py')
            runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
            self.assertEqual([getattr(runner.s,k) for k in names[:4]],[1500,1260,235,195])
            self.assertEqual(s.watchdog.PROCESS_READ_TIMEOUT_SECONDS,3)
        finally:
            for k,v in old.items():setattr(s,k,v)

    def test_per_lifetime_evidence_collects_actual_receipts_separately(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('recording_evidence',HERE.parent/'simulator-inspector-product-live/evidence.py')
        evidence=importlib.util.module_from_spec(spec);spec.loader.exec_module(evidence)
        self.make_ledger(self.new)
        out=self.root/'evidence-out';out.mkdir(mode=0o700)
        for index,target in enumerate((self.old,self.new)):
            state=a.read_json(self.ledger_root/(backend.edit.digest(target)+'.json'),[])
            put(out/(str(index)+'-ledger.json'),state)
        with patch.object(Path,'home',return_value=self.root/'home'):
            operations=evidence.collect_lifetimes([self.old,self.new],out)
        self.assertEqual(len(operations),4)
        self.assertEqual(json.loads((out/'lifetime-0/durable-ledger.json').read_text())['target'],self.old)
        self.assertEqual(json.loads((out/'lifetime-1/durable-ledger.json').read_text())['target'],self.new)
        self.assertEqual(len(json.loads((out/'lifetime-history.json').read_text())),2)

    def test_native_candidate_identity_race_is_refused(self):
        self.gap();self.launch();self.successor();self.result()
        original=self.probe.identity;reads=[0]
        def identity(pid,device=False):
            value=original(pid,device=device)
            if pid==124:
                reads[0]+=1
                if reads[0]>=2:value['start']=[500,1]
            return value
        with patch.object(self.probe,'identity',side_effect=identity),self.assertRaisesRegex(a.ContractError,'changed during native'):
            self.observe()

    def test_cleanup_absence_last_read_cannot_cross_observation_cutoff(self):
        now=[0.0];reads=[0]
        observation=s.watchdog.ProcessObservation(lambda:now[0])
        def late_absent(pid):
            reads[0]+=1
            if reads[0]==2:now[0]=4.0
            raise s.watchdog.IdentityReadError('absent',None,'proc_pidinfo',0,errno.ESRCH)
        with patch.object(s.watchdog,'process_status',side_effect=late_absent),self.assertRaises(s.watchdog.ObservationExpired):
            owner.native_absent(s,observation,999,dict(start=[100,1]))

    def test_guest_control_write_bound_is_8192_and_preserves_foreign_file(self):
        path=self.root/'bounded-control.json'
        with self.assertRaisesRegex(a.ContractError,'exceeds bound'):
            fixture.private_write(path,dict(value='x'*8192),limit=8192)
        self.assertFalse(path.exists())
        put(path,dict(foreign=True));before=path.read_bytes()
        with self.assertRaises(FileExistsError):fixture.private_write(path,dict(value='owned'),limit=8192)
        self.assertEqual(path.read_bytes(),before)

    def test_receipt_version_bool_is_not_integer_version_one(self):
        worker,data,entry,out=self.worker_before_arm();worker.tick()
        receipt=self.worker_ack(worker,data,entry);receipt['version']=True
        with self.assertRaisesRegex(a.ContractError,'receipt differs'):
            worker.arm.acknowledge(dict(restartReceipt=receipt))
        self.assertEqual(worker.arm.state,'arming')

    def test_incomplete_native_family_cannot_publish_successor(self):
        self.gap();self.launch();self.successor();self.result()
        self.add(601,self.ui_pid,'/unowned/helper',group=601,argv=['/unowned/helper'])
        with self.assertRaises(s.watchdog.IdentityChanged):self.observe()
        self.assertFalse((self.root/'recording-cursor.json').exists())
        self.assertEqual(self.owner.cursor.revision,0)
        self.assertEqual(self.owner.cursor.binding,self.binding)

    def test_failed_publication_keeps_new_custody_without_republishing(self):
        self.gap();self.launch();self.successor();self.result()
        def failed(value):raise OSError('controlled publication failure')
        self.owner.cursor.publish=failed
        with self.assertRaisesRegex(OSError,'publication failure'):self.observe()
        self.assertEqual(self.owner.cursor.binding['target'],self.new)
        self.assertEqual(self.owner.cursor.phase,'custodyOnly')
        self.assertEqual(self.owner.cursor.revision,1)
        self.assertFalse(self.owner.cursor.published)
        self.owner.cursor.publish=self.owner.publish;self.observe()
        self.assertFalse((self.root/'recording-cursor.json').exists())
        self.assertEqual(len(self.owner.cursor.histories),2)

    def test_cancel_exact_bytes_before_dispatch_and_no_redundant_reads(self):
        self.arm.cancel();self.assertEqual(self.arm.state,'cancelling')
        receipt=dict(version=1,status='cancelled',restartID=self.arm.restart_id,pendingSHA256=a.digest(self.pending_raw))
        self.assertTrue(self.arm.cancelled(dict(restartReceipt=receipt)))
        self.assertTrue(self.arm.cancelled({}));self.assertFalse(self.arm.control.exists())
        with self.assertRaises(a.ContractError):self.arm.arm()
        with self.assertRaises(a.ContractError):self.arm.dispatch()

    def test_dispatch_unknown_blocks_cancel_and_does_not_refresh(self):
        self.arm.dispatch();self.assertEqual(self.arm.state,'dispatchUnknown')
        with self.assertRaises(a.ContractError):self.arm.cancel()
        with self.assertRaises(a.ContractError):self.arm.arm()
        self.assertEqual(self.arm.expires,70)


if __name__=='__main__':unittest.main()
