"""Synthetic headless execution of canonical spawn sites; never invokes a target engine.

This records calls; full observer integration is tested separately. No recorded PID is live.
All subprocess entry points are intercepted before any child can be created.
"""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

RESOURCE = Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture'
sys.path.insert(0, str(RESOURCE))
import resident_transport as t
import resident_support as support
import session as s
import test_ui_family as ui


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def record_canonical_calls(root, kind="capture", preparation=None):
    """Execute admit, stage, discovery, supervise, worker and cleanup using fake CLI IO."""
    events = []
    resource = root / 'resources'; resource.mkdir()
    developer = root / 'Xcode.app/Contents/Developer'; developer.mkdir(parents=True)
    framework = developer.parent / 'SharedFrameworks/LLDB.framework'
    sdk = root / 'Simulator.sdk'; sdk.mkdir()
    files = [framework/'LLDB', framework/'Resources/debugserver', framework/'Resources/Python/lldb/__init__.py',
             sdk/'System/Library/Frameworks/Foundation.framework/Modules/module.modulemap',
             sdk/'System/Library/Frameworks/UIKit.framework/Modules/module.modulemap']
    for f in files:
        f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(b'synthetic fixture')
    (sdk/'SDKSettings.json').write_text(json.dumps(dict(CanonicalName='iphonesimulator27.2', DefaultProperties=dict(PLATFORM_NAME='iphonesimulator'))))
    app = root/'Containers/Bundle/Application/owned/Fixture.app'; app.mkdir(parents=True)
    executable = app/'Fixture'; executable.write_bytes(b'synthetic target, never executable')
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='test.owned.fixture', CFBundleExecutable='Fixture')))
    data = root/'Containers/Data/Application/owned'; data.mkdir(parents=True)
    (data/'Library/Caches').mkdir(parents=True)
    image = resource/'mac-cu-resident-v2.dylib'; image.write_bytes(b'synthetic image, never loaded')
    build = dict(abi=2, image=image.name, architecture='arm64', sha256=sha(image), sources={}, developer=str(developer), sdk=str(sdk),
                 xcodeVersion='Xcode 27.2\nBuild version 27B48', sdkSHA256=sha(sdk/'SDKSettings.json'),
                 lldbSHA256=sha(framework/'LLDB'), debugserverSHA256=sha(framework/'Resources/debugserver'), uuid=str(uuid.uuid4()).upper())
    (resource/'resident-build.json').write_text(json.dumps(build))
    target = dict(pid=123, start=[100,5],path=str(executable),deviceID=str(uuid.uuid4()).upper())
    uid = lambda: str(uuid.uuid4()).upper()
    request = dict(schemaVersion=2,kind='capture',validationOnly=False,ownerID=uid(),operationID=uid(),inspectionID=uid(),
                   targetEpoch=None,sequence=1,replaceCaptureID=None,target=target)
    if kind != 'capture':
        request.pop('replaceCaptureID')
        request.update(kind=kind,targetEpoch=uid(),captureID=uid())
        if kind == 'edit':
            request.update(nodeToken=uid(),expectedParentToken=None,expectedWindowToken=uid(),
                           expectedClass='UILabel',property='hidden',expectedValue=False,value=True)
        elif kind == 'revert': request['undoToken']=uid()
        elif kind == 'release': request['reason']='close'
        else: raise AssertionError(kind)
    t.c.request_contract(request)
    wire = dict(request,newCaptureID=uid())
    folder = root/'host-request'; folder.mkdir()
    (folder/'request.json').write_text(json.dumps(request))
    phase = ['supervisor']
    def output(argv, **kw):
        events.append(dict(parentRole=phase[0],api='check_output',argv=list(argv),timeout=kw.get('timeout')))
        if argv[0] == '/usr/bin/codesign':
            raw = plistlib.dumps({'com.apple.security.get-task-allow':True}) if '-d' in argv else b''
        elif argv == ['/usr/bin/xcode-select','-p']: raw = str(developer).encode()
        elif argv == ['/usr/bin/xcodebuild','-version']: raw = build['xcodeVersion'].encode()
        elif argv == ['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path']: raw = str(sdk).encode()
        elif argv == ['/usr/bin/xcrun','simctl','list','devices','--json']:
            raw = json.dumps({'devices':{'runtime':[{'udid':target['deviceID'],'state':'Booted'}]}}).encode()
        elif argv == ['/usr/bin/xcrun','simctl','list','runtimes','--json']:
            raw = json.dumps({'runtimes':[dict(identifier='runtime',version='27.2',buildversion='24B114',isAvailable=True)]}).encode()
        elif argv[:3] == ['/usr/bin/xcrun','simctl','get_app_container'] and argv[3:5] == [target['deviceID'],'test.owned.fixture'] and argv[5] in ('app','data'):
            raw = str(app if argv[5]=='app' else data).encode()
        else: raise AssertionError('unclassified canonical subprocess: '+repr(argv))
        return raw.decode() if kw.get('text') else raw
    class Child:
        def __init__(self,pid): self.pid=pid; self.returncode=0
        def poll(self): return self.returncode
        def wait(self,timeout): return self.returncode
    def popen(argv, **kw):
        fds=list(kw['pass_fds'])
        for fd in fds:
            assert fd>0; os.fstat(fd) # Actual parent FD exists; no child/socket identity claim.
        events.append(dict(parentRole=phase[0],api='Popen',argv=list(argv),pass_fds=fds,fdOpenInParent=True))
        if argv[0] == str(framework/'Resources/debugserver'): return Child(800)
        assert argv[:4] == [sys.executable,'-I',str(t.HERE/'resident_transport.py'),'--worker']
        phase[0]='worker'
        try:
            with patch.dict(os.environ,kw['env']), patch.object(t.os,'getppid',return_value=os.getpid()):
                assert t.worker(Path(argv[4]),int(argv[5])) == 1
        finally: phase[0]='supervisor'
        return Child(801)
    class Probe:
        def identity(self,pid): return dict(pid=pid,parent=os.getpid(),path=str(framework/'Resources/debugserver'),start=[100,8])
    with ExitStack() as stack:
        stack.enter_context(patch.object(support,'HERE',resource))
        stack.enter_context(patch.object(t.subprocess,'check_output',side_effect=output))
        stack.enter_context(patch.object(t.subprocess,'Popen',side_effect=popen))
        stack.enter_context(patch.object(t.subprocess,'run',side_effect=AssertionError('unexpected run')))
        stack.enter_context(patch.object(t.c,'verify_target',return_value=target))
        stack.enter_context(patch.object(t.c,'recovered',return_value={'verified':True}))
        stack.enter_context(patch.object(t.c,'ProcessProbe',return_value=Probe()))
        stack.enter_context(patch.object(t.signal,'signal'))
        engine = stack.enter_context(patch.object(t,'Engine',side_effect=RuntimeError('HEADLESS engine boundary')))
        if preparation is not None:
            # Reuse the same intercepted production admission, without transport/Engine.
            return preparation(target, folder, resource, developer, events)
        result=t.supervise(request,wire,folder,Probe(),lambda:False,lambda:None)
        engine.assert_called_once()
        assert result['cleanup']['childrenReaped'] is True
        assert result['cleanup']['debuggerClosed'] is True
        assert result['reasonCode']=='unsupportedMainEntry', result
        # Existing pin branch skips staged signing, but creates a fresh operation channel.
        before=len(events)
        admission=json.loads((folder/'admission.json').read_text())
        support.stage(dict(wire,operationID=uid()),admission)
        assert len(events)==before
    channel=json.loads((folder/'channel.json').read_text())
    config=json.loads((Path(channel['path'])/'worker.json').read_text())
    assert config['request']==request and config['supervisor']==os.getpid()
    assert config['image']==channel['image'] and config['admission']==admission
    assert Path(channel['path']).is_relative_to(data)
    return dict(evidence='synthetic headless; no child or target engine executed',events=events,
                request=request,channel=channel,worker=config,sourceHashes={str(RESOURCE/n):sha(RESOURCE/n) for n in
                ('capture.py','resident_support.py','resident_transport.py','resident_protocol.py')})


class CanonicalCallTrace(unittest.TestCase):
    def test_audited_sources_require_explicit_reclassification(self):
        pins=json.loads(Path(__file__).with_name('canonical-call-audit.json').read_text())
        repository=Path(__file__).resolve().parents[3]
        for relative, evidence in pins['sources'].items():
            self.assertEqual(sha(repository/relative), evidence['sha256'],
                             'canonical source changed: re-audit all calls before updating audit pin: '+relative)

    def test_edit_revert_release_use_the_same_canonical_transport(self):
        for kind in ('edit','revert','release'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as d:
                trace=record_canonical_calls(Path(d).resolve(),kind)
                self.assertEqual(len(trace['events']),17)
                self.assertEqual(trace['worker']['request']['kind'],kind)

    def test_production_spawn_trace_retains_canonical_role_counts(self):
        with tempfile.TemporaryDirectory() as d:
            trace=record_canonical_calls(Path(d).resolve())
        events=trace['events']
        self.assertEqual(len(events),17)
        self.assertEqual([e['api'] for e in events].count('Popen'),2)
        self.assertEqual([e['parentRole'] for e in events].count('worker'),2)
        worker=next(e for e in events if e['api']=='Popen' and '--worker' in e['argv'])
        self.assertEqual(Path(worker['argv'][2]).name,'resident_transport.py')
        # Positive complete-observer qualification now lives in
        # test_ui_process_contract, using these actual canonical traces.

if __name__=='__main__':
    if len(sys.argv)==2:
        root=Path(sys.argv[1]).resolve(); root.mkdir(mode=0o700)
        trace=record_canonical_calls(root)
        (root/'trace.json').write_text(json.dumps(trace,indent=2)+'\n')
    else: unittest.main()
