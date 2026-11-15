"""Filesystem-only refresh regression tests. No native operation is permitted."""
import ast
import hashlib
import types
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('refresh_prepared', HERE / 'refresh_prepared.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.source = self.root / 'prior'; self.source.mkdir()
        self.prepared = self.source / 'prepared'
        self.out = self.root / 'new'
        self.uid = str(uuid.uuid4()).upper()
        for name in r.REQUIRED_INPUTS | r.CONTROLLER_DRIFT:
            self.write(self.repo / name, b'original source')
        self.write(self.repo / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/main.swift', b'main')
        for name in r.REQUIRED_ARTIFACTS:
            self.write(self.prepared / name, b'artifact')
        macho = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 6, 1, 24, 0, 0)
        macho += struct.pack('<II', 0x1b, 24) + uuid.UUID(self.uid).bytes
        self.write(self.prepared / 'resident-simulator.dylib', macho)
        self.write(self.prepared / 'base/SwiftUIProbe.app/Info.plist', plistlib.dumps(dict(
            CFBundleExecutable='SwiftUIProbe', CFBundleIdentifier='local.mac-pilot.swiftui-probe.synthetic')))
        self.sdk = self.root / 'sdk'; self.sdk.mkdir()
        self.write(self.sdk / 'SDKSettings.json', b'sdk')
        hashes = {str(p): r.sha(p) for p in self.repo.rglob('*') if p.is_file()}
        hashes.update({str(self.prepared / n): r.sha(self.prepared / n) for n in r.REQUIRED_ARTIFACTS})
        hashes[str(self.sdk / 'SDKSettings.json')] = r.sha(self.sdk / 'SDKSettings.json')
        self.developer = self.root/'Xcode/Contents/Developer'
        self.developer.mkdir(parents=True)
        self.compiler = self.developer/'Toolchains/clang'
        self.write(self.compiler,b'compiler')
        framework=self.developer.parent/'SharedFrameworks/LLDB.framework'
        self.write(framework/'LLDB', b'lldb'); self.write(framework/'Resources/debugserver',b'debugserver')
        self.write(self.prepared/'base/view-capture/mac-cu-resident-v2.dylib',macho)
        hashes[str(self.prepared/'base/view-capture/mac-cu-resident-v2.dylib')]=r.sha(self.prepared/'base/view-capture/mac-cu-resident-v2.dylib')
        self.write_json(self.prepared/'base/view-capture/resident-build.json', dict(
            abi=2,architecture='arm64',developer=str(self.developer),sdk=str(self.sdk),
            sdkSHA256=r.sha(self.sdk/'SDKSettings.json'), compilerSHA256=r.sha(self.compiler),
            command=[str(self.compiler)],lldbSHA256=r.sha(framework/'LLDB'),
            debugserverSHA256=r.sha(framework/'Resources/debugserver'), image='mac-cu-resident-v2.dylib',
            sha256=r.sha(self.prepared/'base/view-capture/mac-cu-resident-v2.dylib'),uuid=self.uid,sources={}))
        hashes[str(self.prepared/'base/view-capture/resident-build.json')]=r.sha(self.prepared/'base/view-capture/resident-build.json')
        self.runtime={'synthetic':True,'context':{'developer':str(self.developer)}}
        self.ready = dict(hashes=hashes, dispatchPassed=True, wholeProbeVerified=True,
                          editQualificationReady=True, swiftUIProbe=dict(
            helper=str(self.prepared / 'resident-simulator.dylib'), helperUUID=self.uid,
            helperSHA256=r.sha(self.prepared / 'resident-simulator.dylib'),
            appSHA256=r.sha(self.prepared / 'base/SwiftUIProbe.app/SwiftUIProbe'),
            bundleID='local.mac-pilot.swiftui-probe.synthetic', sdk=str(self.sdk),
            workerRuntime=self.runtime, separateModule=True, appGraphCalls=0))
        self.write_json(self.prepared / 'base/prepared.json', self.ready)
        self.write_json(self.prepared / 'worker-runtime.json', self.runtime)
        self.proof = dict(passed=True, processCreated=False, guestLoaded=False, moduleUUID=self.uid,
                          compiler=dict(executable=self.ready['swiftUIProbe']['helper'], sdkPath=str(self.sdk)))
        self.write_json(self.prepared / 'no-target.json', self.proof)
        self.commands = [dict(label=n, returncode=0, timeout=t) for n,t in r.COMMANDS]
        self.write_json(self.prepared / 'commands.json', self.commands)
        self.write_json(self.source / 'preparation-exit.json', dict(returncode=0))
        self.write_json(self.source / 'preparation-command.json', ['python', '-B',
                        'mac-computer-use/tests/swiftui-hierarchy-probe/prepare.py', str(self.prepared)])
        self.seal()
        self.guard = patch.object(r, 'current_guards', return_value={'passed': True, 'cleanupResolved': True})
        self.guard_mock = self.guard.start(); self.addCleanup(self.guard.stop)
        self.verify = patch.object(r, 'verify_runtime', return_value=None)
        self.verify_mock = self.verify.start(); self.addCleanup(self.verify.stop)
        for name in ('run', 'Popen', 'check_output', 'call', 'check_call'):
            mocker = patch.object(subprocess, name, side_effect=AssertionError('native subprocess forbidden'))
            mocker.start(); self.addCleanup(mocker.stop)

    def write(self, p, data):
        p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)

    def write_json(self, p, value):
        self.write(p, json.dumps(value).encode())

    def seal(self):
        self.manifest = self.source / 'artifact-manifest.json'
        self.write_json(self.manifest, {str(p): r.sha(p) for p in self.source.rglob('*')
                                     if p.is_file() and p != self.manifest})
        self.digest = r.sha(self.manifest)

    def refresh(self):
        return r.refresh(self.prepared, self.manifest, self.digest, self.out, repo=self.repo)

    def test_exact_reuse_and_current_controller_pins(self):
        before = {p: p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        controller = self.repo / sorted(r.CONTROLLER_DRIFT)[0]
        controller.write_bytes(b'reviewed controller')
        self.refresh()
        ready = json.loads((self.out / 'base/prepared.json').read_text())
        self.assertEqual(ready['hashes'][str(controller)], r.sha(controller))
        self.assertEqual((self.out/'no-target.json').read_bytes(), (self.prepared/'no-target.json').read_bytes())
        for p, data in before.items(): self.assertEqual(p.read_bytes(), data)
        for name, digest in ready['hashes'].items(): self.assertEqual(r.sha(name), digest)
        self.assertEqual(ready['swiftUIProbe']['helper'], str(self.out/'resident-simulator.dylib'))
        self.assertTrue(ready['refresh']['reusedNoTargetProof'])
        self.guard_mock.assert_called_once(); self.verify_mock.assert_called()

    def test_no_source_changes(self):
        before={p:p.read_bytes() for p in self.repo.rglob('*') if p.is_file()}
        self.refresh(); self.assertTrue((self.out/'base/prepared.json').is_file())
        self.assertEqual(before,{p:p.read_bytes() for p in self.repo.rglob('*') if p.is_file()})

    def test_stale_inputs(self):
        for name in ['mac-computer-use/tests/swiftui-hierarchy-probe/Bridge.swift',
                     'mac-computer-use/tests/swiftui-hierarchy-probe/debugger.py',
                     'mac-computer-use/skills/mac-computer-use/scripts/view-capture/edit_backend.py',
                     'mac-computer-use/tests/native_check_support.py']:
            with self.subTest(name=name):
                p=self.repo/name; old=p.read_bytes(); p.write_bytes(b'drift')
                with self.assertRaises(ValueError): self.refresh()
                p.write_bytes(old)

    def test_current_manifest_verifier_compatibility(self):
        self.refresh()
        tree = ast.parse((HERE.parent/'view-hierarchy-fixture/session.py').read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'verify_prepared')
        namespace = dict(json=json, hashlib=hashlib, Path=Path)
        exec(compile(ast.Module(body=[function], type_ignores=[]), 'session.verify_prepared', 'exec'), namespace)
        namespace['verify_prepared'](self.out/'base')
        ready = json.loads((self.out/'base/prepared.json').read_text())
        self.assertTrue(ready['wholeProbeVerified'])
        for name in ('session-probe', 'fixture-dispatch', 'SwiftUIProbe.app/SwiftUIProbe'):
            self.assertTrue((self.out/'base'/name).is_file())

    def test_guard_adapter_uses_existing_watchdog(self):
        native = types.SimpleNamespace(check_routes=unittest.mock.Mock(), run_owned=unittest.mock.Mock(side_effect=[0,64,64]))
        self.out.mkdir(); logs=self.out/'logs'; logs.mkdir()
        self.guard.stop()
        with patch.object(r, 'load_local', return_value=native), patch.object(subprocess, 'run') as run:
            result=r.current_guards(self.out/'base', self.repo, logs)
        self.assertTrue(result['cleanupResolved'])
        self.assertEqual(run.call_args.kwargs['timeout'],120)
        self.assertEqual(native.check_routes.call_count,2)
        for call in native.run_owned.call_args_list:
            self.assertEqual(call.kwargs['timeout'],5)
            self.assertEqual(call.kwargs['max_instances'],1)

    def test_missing_toolchain_provenance(self):
        (self.prepared/'base/view-capture/resident-build.json').unlink(); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_changed_compiler(self):
        self.compiler.write_bytes(b'changed')
        with self.assertRaises(ValueError): self.refresh()

    def test_invalid_proof_flags(self):
        for key, value in (('passed',False),('processCreated',True),('guestLoaded',True)):
            old=self.proof[key]; self.proof[key]=value
            self.write_json(self.prepared/'no-target.json',self.proof); self.seal()
            with self.subTest(key=key), self.assertRaises(ValueError): self.refresh()
            self.proof[key]=old

    def test_app_identity_join(self):
        self.write(self.prepared/'base/SwiftUIProbe.app/Info.plist',plistlib.dumps(dict(
            CFBundleIdentifier='different',CFBundleExecutable='SwiftUIProbe')))
        self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_missing_import_pin(self):
        del self.ready['hashes'][str(self.repo/'mac-computer-use/tests/swiftui-hierarchy-probe/debugger.py')]
        self.write_json(self.prepared/'base/prepared.json',self.ready); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_copy_mutation_during_guard(self):
        def guard(*args):
            (self.out/'base/session-probe').write_bytes(b'changed after copy')
            return {'passed':True,'cleanupResolved':True}
        self.guard_mock.side_effect=guard
        with self.assertRaises(ValueError): self.refresh()
        self.assertFalse((self.out/'base/prepared.json').exists())

    def test_symlink_output_parent(self):
        alias=self.root/'alias'; alias.symlink_to(self.root,target_is_directory=True)
        self.out=alias/'new'
        with self.assertRaises(ValueError): self.refresh()

    def test_safe_worker_verifier_no_prove_or_lldb(self):
        self.verify.stop()
        worker=types.SimpleNamespace(verify=unittest.mock.Mock(),
                                    prove=unittest.mock.Mock(side_effect=AssertionError('prove forbidden')))
        with patch.object(r,'load_local',return_value=worker), patch.object(
                subprocess,'check_output',return_value=str(self.sdk)) as query:
            r.verify_runtime(self.runtime,self.repo,str(self.sdk))
        worker.verify.assert_called_once_with(self.runtime); worker.prove.assert_not_called()
        self.assertEqual(query.call_args.args[0],['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'])

    def test_import_is_inert(self):
        module=importlib.util.module_from_spec(spec)
        with patch.object(Path,'open',side_effect=AssertionError('import I/O forbidden')):
            spec.loader.exec_module(module)

    def test_wrong_manifest_digest(self):
        self.digest='0'*64
        with self.assertRaises(ValueError): self.refresh()

    def test_artifact_tamper(self):
        (self.prepared/'base/SwiftUIProbe.app/SwiftUIProbe').write_bytes(b'tamper')
        with self.assertRaises(ValueError): self.refresh()

    def test_uuid_mismatch_even_when_resealed(self):
        self.proof['moduleUUID']=str(uuid.uuid4()); self.write_json(self.prepared/'no-target.json', self.proof); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_incomplete_timeout_nonzero_proof(self):
        for value in (None, 1, -9):
            with self.subTest(value=value):
                self.commands[-1]['returncode']=value
                self.write_json(self.prepared/'commands.json', self.commands); self.seal()
                with self.assertRaises(ValueError): self.refresh()

    def test_missing_custody(self):
        (self.source/'preparation-exit.json').unlink(); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_partial_manifest(self):
        del self.ready['swiftUIProbe']; self.write_json(self.prepared/'base/prepared.json', self.ready); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_unexpected_drift(self):
        p=self.repo/'mac-computer-use/tests/swiftui-hierarchy-probe/protocol.py'; p.write_bytes(b'drift')
        with self.assertRaises(ValueError): self.refresh()

    def test_output_exists(self):
        self.out.mkdir()
        with self.assertRaises(ValueError): self.refresh()

    def test_path_escape(self):
        m=json.loads(self.manifest.read_text()); m[str(self.root/'outside')]='0'*64
        self.write_json(self.manifest,m); self.digest=r.sha(self.manifest)
        with self.assertRaises(ValueError): self.refresh()

    def test_symlink_artifact(self):
        p=self.prepared/'base/session-probe'; p.unlink(); p.symlink_to(self.prepared/'base/fixture-dispatch'); self.seal()
        with self.assertRaises(ValueError): self.refresh()

    def test_guard_failure_no_manifest(self):
        self.guard_mock.side_effect=RuntimeError('guard failure')
        with self.assertRaises(RuntimeError): self.refresh()
        self.assertFalse((self.out/'base/prepared.json').exists())

    def test_guard_cleanup_unknown_no_manifest(self):
        self.guard_mock.return_value={'passed': True, 'cleanupResolved': False}
        with self.assertRaises(ValueError): self.refresh()
        self.assertFalse((self.out/'base/prepared.json').exists())

    def test_source_moves_during_guard(self):
        self.guard_mock.side_effect=lambda *a: (self.write(self.repo/sorted(r.CONTROLLER_DRIFT)[0],b'moved') or
                                              {'passed':True,'cleanupResolved':True})
        with self.assertRaises(ValueError): self.refresh()
        self.assertFalse((self.out/'base/prepared.json').exists())

    def test_runtime_verifier_failure(self):
        self.verify_mock.side_effect=RuntimeError('runtime changed')
        with self.assertRaises(RuntimeError): self.refresh()
        self.assertFalse((self.out/'base/prepared.json').exists())


if __name__ == '__main__': unittest.main()
