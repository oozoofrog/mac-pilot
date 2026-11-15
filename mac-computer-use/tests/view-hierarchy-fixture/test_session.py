"""Fixed, headless session safety checks; no Simulator mutation or debugger connection."""
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import session


class StartupBindingTests(unittest.TestCase):
    def test_launcher_snapshot_requires_runtime_boundary(self):
        # Reproduce the observed mismatch without depending on private evidence.
        launch = dict(pid=40, start=[2, 0], path='/synthetic/python-launcher', parent=30, group=40)
        parent = {'worker': launch}
        binding = dict(version=1, owner='11111111-1111-4111-8111-111111111111',
            worker=dict(launch, path='/synthetic/python-runtime'),
            target=dict(pid=200, start=[3, 0], path='/synthetic/target', deviceID='DEVICE'),
            group=200, originalParent=dict(pid=201, start=[1, 0], path='/synthetic/parent', parent=1, group=201))
        with self.assertRaisesRegex(session.watchdog.IdentityChanged, 'binding mismatch'):
            session.watchdog.validate_target_binding(binding, binding['target'], parent['worker'], binding['owner'])
        self.assertEqual([k for k in session.watchdog.LIFETIME_KEYS
                          if parent['worker'][k] != binding['worker'][k]], ['path'])
        from types import SimpleNamespace
        parent_id=dict(pid=parent['worker']['parent'],start=[1,0],path=binding['worker']['path'],parent=1,group=1)
        stage=['launch']; child=SimpleNamespace(pid=parent['worker']['pid'],poll=lambda:None)
        ready=dict(version=1,owner=binding['owner'],parent=parent_id,worker=binding['worker'])
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory);details={}
            def identity(pid):
                if pid==parent_id['pid']:return parent_id
                return parent['worker'] if stage[0]=='launch' else binding['worker']
            def transition(_):
                stage[0]='ready';session.save(out/'worker-ready.json',ready)
            with patch.object(session.watchdog,'process_identity',side_effect=identity), \
                 patch.object(session.sys,'executable',parent['worker']['path']), \
                 patch.object(session,'monotonic',return_value=0), \
                 patch.object(session.time,'sleep',side_effect=transition):
                session.await_worker_ready(child,out,binding['owner'],parent_id,1,lambda:None,details)
            self.assertEqual(details['workerLaunch'],session.watchdog.lifetime(parent['worker']))
            self.assertEqual(details['workerReady'],ready)
            session.watchdog.validate_target_binding(binding,binding['target'],details['worker'],binding['owner'])

    def run_startup_parent(self, mode='launcher'):
        from types import SimpleNamespace
        parent_id = dict(pid=os.getpid(), start=[1, 0], path='/runtime', parent=1, group=1)
        launch = dict(pid=40, start=[2, 0], path='/launcher' if mode != 'direct' else '/runtime',
                      parent=os.getpid(), group=40)
        runtime = dict(launch, path='/runtime')
        now, stage, checks, cleanup = [0.0], ['launch'], [], []
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'run'
            child = SimpleNamespace(pid=40, returncode=None)
            child.poll = lambda: child.returncode
            child.wait = lambda **kw: child.returncode
            def launch_child(argv, env, **kwargs):
                checks.append('launch')
                return child
            def identity(pid):
                if mode == 'kernel': raise PermissionError('kernel unreadable')
                if pid == os.getpid(): return dict(parent_id)
                if stage[0] == 'acked' and mode in ('exit-race', 'exit-denied', 'exit-unknown'):
                    import errno
                    child.returncode = None if mode == 'exit-unknown' else 0
                    raise session.watchdog.IdentityReadError('worker identity read failed', None,
                        'proc_pidinfo', 0, errno.EPERM if mode == 'exit-denied' else errno.ESRCH)
                value = dict(launch if stage[0] == 'launch' else runtime)
                if stage[0] != 'launch':
                    changes = {'path': {'path':'/wrong'}, 'pid': {'pid':41}, 'start': {'start':[3,0]},
                               'parent': {'parent':99}, 'group': {'group':99}}
                    value.update(changes.get(mode, {}))
                    if mode in ('post-exec','post-reuse') and stage[0] == 'acked':
                        value.update({'path':'/wrong'} if mode == 'post-exec' else {'start':[3,0]})
                return value
            def sleep(_):
                now[0] += .1
                if stage[0] == 'launch':
                    stage[0] = 'ready'
                    value = dict(version=1, owner=owner, parent=parent_id, worker=runtime)
                    if mode == 'owner': value['owner']='wrong'
                    if mode == 'token': value['token']='wrong'
                    if mode == 'metadata': (out / 'worker-ready.json').write_text('{')
                    elif mode != 'timeout': session.save(out / 'worker-ready.json', value)
                    if mode == 'exit': child.returncode=1
                elif (out / 'worker-ack.json').exists():
                    stage[0]='acked'
                    if mode not in ('post-exec','post-reuse'):
                        session.save(out / 'session.json', dict(deadlineMonotonic=360,
                            workerReceivedMonotonic=0,workerRemainingAtReceiptSeconds=360,passed=True))
                        if mode not in ('exit-race', 'exit-denied', 'exit-unknown'):
                            child.returncode=0
            def check_input():
                if mode in ('input','cancel') and stage[0] != 'launch':
                    raise (session.native.NativeCheckInterrupted('cancelled') if mode == 'cancel' else InterruptedError('input'))
            owner='11111111-1111-4111-8111-111111111111'
            with patch.object(session.uuid,'uuid4',return_value=owner), \
                 patch.object(session,'verify_prepared'), patch.object(session,'booted'), \
                 patch.object(session,'InputGuard',return_value=SimpleNamespace(check=check_input)), \
                 patch.object(session.capture,'tools_for_xcode',return_value=(Path('/server'),None,None)), \
                 patch.object(session.sys,'executable','/launcher'), \
                 patch.object(session.subprocess,'Popen',side_effect=launch_child), \
                 patch.object(session.watchdog,'process_identity',side_effect=identity), \
                 patch.object(session,'monotonic',side_effect=lambda:now[0]), \
                 patch.object(session.time,'sleep',side_effect=sleep), patch.object(session.signal,'signal'), \
                 patch.object(session.watchdog,'graceful_stop',side_effect=lambda c,*a,**kw:cleanup.append(c)), \
                 patch.object(session.watchdog,'wait_group_readback',return_value={'groupEmpty':True}):
                result=session.parent(Path('/mock'),out,'DEVICE',360,{})
            report=json.loads((out/'parent.json').read_text())
            if checks: self.assertEqual(cleanup,[child])
            return result,report

    def test_worker_ack_requires_exact_parent_self_owner_and_token(self):
        from types import SimpleNamespace
        for mode in ('normal','owner','token','parent','self','ack','missing','unreadable','cancel','after-ack'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                out=Path(directory)
                parent=dict(pid=30,start=[1,0],path='/runtime',parent=1,group=1)
                worker=dict(pid=40,start=[2,0],path='/runtime',parent=30,group=40)
                now,stage=[0.0],['ready']
                context=dict(owner='owner',parent=parent,cutoff=1)
                env=dict(MAC_CU_FIXTURE_STARTUP=json.dumps(context),MAC_CU_FIXTURE_WORKER='owner')
                if mode=='owner': context['owner']='wrong';env['MAC_CU_FIXTURE_STARTUP']=json.dumps(context)
                if mode=='token': env['MAC_CU_FIXTURE_WORKER']='wrong'
                def identity(pid):
                    value=dict(parent if pid==30 else worker)
                    if mode=='parent' and pid==30:value['start']=[9,0]
                    if mode=='self' and (out/'worker-ready.json').exists() and pid==40:value['path']='/wrong'
                    if mode=='after-ack' and stage[0]=='read-ack' and pid==40:value['start']=[9,0]
                    return value
                def sleep(_):
                    now[0]+=.1
                    if mode!='missing':
                        value=json.loads((out/'worker-ready.json').read_text())
                        if mode=='ack':value['owner']='wrong'
                        session.save(out/'worker-ack.json',value)
                real_read=session.read_startup
                def read(path):
                    if mode=='unreadable':raise PermissionError('metadata unreadable')
                    value=real_read(path);stage[0]='read-ack';return value
                def check():
                    if mode=='cancel':raise session.native.NativeCheckInterrupted('cancelled')
                with patch.dict(os.environ,env),patch.object(session.os,'getpid',return_value=40), \
                     patch.object(session.os,'getppid',return_value=30), \
                     patch.object(session.watchdog,'process_identity',side_effect=identity), \
                     patch.object(session,'monotonic',side_effect=lambda:now[0]), \
                     patch.object(session.time,'sleep',side_effect=sleep),patch.object(session,'read_startup',side_effect=read):
                    if mode=='normal':self.assertEqual(session.worker_startup(out,'owner',30,1,check)['worker'],worker)
                    else:
                        with self.assertRaises((RuntimeError,OSError)):
                            session.worker_startup(out,'owner',30,1,check)

    def test_real_worker_startup_failure_precedes_claim_and_inventory(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ,MAC_CU_FIXTURE_WORKER='owner'), \
             patch.object(session,'verify_prepared'),patch.object(session,'InputGuard',return_value=SimpleNamespace(check=lambda:None)), \
             patch.object(session.Claim,'acquire',side_effect=AssertionError('claim before ack')), \
             patch.object(session,'booted',side_effect=AssertionError('inventory before ack')):
            os.environ.pop('MAC_CU_FIXTURE_STARTUP',None)
            result=session.worker(Path(directory),Path(directory),'DEVICE','owner',os.getppid(),session.monotonic()+session.TOTAL)
            self.assertEqual(result,1)
            report=json.loads((Path(directory)/'session.json').read_text())
            self.assertFalse(report['passed'])
            self.assertNotIn('claimReleased',report)

    def test_real_parent_launch_and_direct_runtime(self):
        for mode in ('launcher','direct'):
            with self.subTest(mode=mode):
                result,report=self.run_startup_parent(mode)
                self.assertEqual(result,0,report)
                self.assertEqual(report['worker']['path'],'/runtime')
                self.assertEqual(report['workerReady']['worker'],session.watchdog.lifetime(report['worker']))

    def test_parent_reconciles_exit_between_poll_and_identity_read(self):
        result, report = self.run_startup_parent('exit-race')
        self.assertEqual(result, 0, report.get('error'))
        self.assertTrue(report['workerDeadlineTransmissionVerified'])
        for mode in ('exit-denied', 'exit-unknown'):
            with self.subTest(mode=mode):
                result, report = self.run_startup_parent(mode)
                self.assertEqual(result, 1)
                self.assertIn('error', report)

    def test_real_parent_rejects_drift_and_unavailable_readiness(self):
        for mode in ('path','pid','start','parent','group','owner','token','metadata','kernel',
                     'timeout','input','cancel','exit','post-exec','post-reuse'):
            with self.subTest(mode=mode):
                result,report=self.run_startup_parent(mode)
                self.assertEqual(result,1,report)
                self.assertIn('error',report)


class SessionChecks(unittest.TestCase):
    def test_texture_worker_dispatch_is_explicit_and_guard_cannot_enable_it(self):
        base = ['session.py', '--worker', '/build', '/out', 'device', 'token', '123', '400']
        for suffix, expected in (([], False), (['--texture-probe'], True)):
            with patch.object(sys, 'argv', base + suffix), patch.object(session, 'worker', return_value=0) as worker:
                self.assertEqual(session.main(), 0)
                self.assertIs(worker.call_args.args[-1], expected)
        with patch.object(sys, 'argv', [base[0], '--worker-guard', *base[2:], '--texture-probe']), \
             patch.object(session, 'guard_worker', side_effect=AssertionError('guard must reject option')):
            self.assertEqual(session.main(), 64)

    def test_input_counters_interrupt_without_collecting_event_contents(self):
        counts = [1, 2]
        guard = session.InputGuard(read=lambda: tuple(counts))
        guard.check()
        counts[0] += 1
        with self.assertRaises(InterruptedError):
            guard.check()

    def test_cancelled_restore_never_launches_foreground(self):
        from types import SimpleNamespace
        with patch.object(session, 'reserve'), patch.object(session, 'probe', return_value={'hostPID': 2, 'frontPID': 3}), \
             patch.object(session.subprocess, 'check_output', side_effect=AssertionError('foreground input')):
            with self.assertRaises(InterruptedError):
                session.restore_foreground(None, None, 'device', {'hostPID': 2, 'frontPID': 1}, None, 0, stopped=True)

    def test_imports_are_inert(self):
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('import launched process')):
            for name in ('session.py', 'prepare.py', 'compare.py'):
                runpy.run_path(str(HERE / name), run_name='import_guard')

    def test_deadline_composition_keeps_reaper_alive(self):
        self.assertGreaterEqual(session.GRACE, session.CAPTURE - (session.WORK - session.CAPTURE_ADMISSION) + session.CLEANUP_BUDGET)
        self.assertEqual(session.WORK + session.GRACE + session.RECEIPT, session.TOTAL)
        self.assertEqual(session.CAPTURE_ADMISSION + session.CAPTURE + session.CLEANUP_BUDGET + session.RECEIPT, session.TOTAL)
        # Fixture cleanup 47s + two whole probes 50s + optional original launch 8s + local margin12s.
        self.assertEqual(8 + 4 + 11 + 8 + 11 + 5 + 2 * session.PROBE_BUDGET + 8 + 12, session.CLEANUP_BUDGET)
        self.assertGreaterEqual(session.CAPTURE, session.capture.WORK_SECONDS + session.capture.CLEANUP_SECONDS + 18)

    def test_server_exit_race_and_unknown_remain_distinct_without_signals(self):
        rows = [(1, 10, 99, '/server', 'S'), (2, 10, 99, '/server', 'S'), (3, 10, 99, '/server', 'Z')]
        report = {'serverObservations': []}
        live = {'pid': 1, 'start': [1, 0], 'path': '/server', 'parent': 10, 'state': 2}
        with patch.object(session.watchdog, 'identify_live_server', side_effect=[None, session.watchdog.UNVERIFIED, None]), \
             patch.object(os, 'kill', side_effect=AssertionError('observer signal')):
            self.assertEqual(session.observe_servers(rows, 99, Path('/server'), report), 1)
        self.assertEqual([e['status'] for e in report['serverObservations']], ['goneOrZombie', 'unknown', 'goneOrZombie'])
        self.assertTrue(all(e['signalAuthority'] is False for e in report['serverObservations']))
        report = {'serverObservations': []}
        with patch.object(session.watchdog, 'identify_live_server', side_effect=[live, session.watchdog.UNVERIFIED, None]):
            self.assertEqual(session.observe_servers(rows, 99, Path('/server'), report), 2)

    def test_admission_denial_preserves_full_cleanup_budget(self):
        with patch.object(session, 'monotonic', return_value=75.001):
            with self.assertRaises(TimeoutError):
                session.reserve(75, 0, 'admission')
            session.reserve(355, session.CLEANUP_BUDGET, 'cleanup')
        with patch.object(session, 'monotonic', return_value=240):
            with self.assertRaises(TimeoutError):
                session.reserve(355, session.CLEANUP_BUDGET, 'cleanup')

    def test_claim_refuses_existing_and_preserves_other_devices(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'claims.json'
            other = {'other': {'pid': 1, 'by': 'leave untouched'}}
            path.write_text(json.dumps(other))
            claim = session.Claim('device', 'ours', path)
            claim.acquire()
            try:
                self.assertEqual(json.loads(path.read_text())['other'], other['other'])
                duplicate = session.Claim('device', 'other-owner', path)
                with self.assertRaises(BlockingIOError):
                    duplicate.acquire()
                duplicate.lock.close()
            finally:
                claim.release()
            self.assertEqual(json.loads(path.read_text()), other)
            path.write_text(json.dumps({'device': {'pid': -1, 'by': 'stale'}}))
            stale = session.Claim('device', 'ours', path)
            with self.assertRaisesRegex(RuntimeError, 'existing claim'):
                stale.acquire()
            stale.lock.close()
            self.assertEqual(json.loads(path.read_text())['device']['by'], 'stale')

    def test_openstep_simctl_inventory_is_converted_without_launch(self):
        raw = b'{ "local.mac-pilot.hierarchy-fixture" = { Path = "/owned/HierarchyFixture.app"; }; }'
        with patch.object(session.subprocess, 'check_output', return_value=raw):
            self.assertEqual(session.fixture_inventory('device')['Path'], '/owned/HierarchyFixture.app')

    def test_claim_change_is_not_released(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'claims.json'
            claim = session.Claim('device', 'ours', path)
            claim.acquire()
            path.write_text(json.dumps({'device': {'by': 'changed'}}))
            with self.assertRaises(RuntimeError):
                claim.release()
            claim.lock.close()
            self.assertEqual(json.loads(path.read_text())['device']['by'], 'changed')

    def test_unknown_or_reused_target_has_no_signal_authority(self):
        class Probe:
            def status(self, _):
                return {'start': [2, 0], 'state': 2}
        with patch.object(os, 'kill', side_effect=AssertionError('signal')):
            self.assertEqual(session.residual(Probe(), {'pid': 42, 'start': [1, 0]})['state'], 'identityChanged')

    def test_capture_cancellation_waits_for_owner(self):
        class Child:
            returncode = None
            def poll(self):
                if (folder / 'cancel').exists():
                    self.returncode = 0
                return self.returncode
            def wait(self, timeout):
                self.waited = True
                return self.returncode
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            child = Child()
            with patch.object(subprocess.Popen, 'kill', side_effect=AssertionError('kill reaper')):
                self.assertEqual(session.finish_capture(child, folder, lambda: True), 0)
            self.assertTrue(child.waited)
            self.assertTrue((folder / 'cancel').exists())

    def test_failed_capture_finishes_before_fixture_restore_and_release(self):
        from types import SimpleNamespace
        import plistlib
        original_reserve = session.reserve
        for admission_denied in (False, True):
            events = []
            with tempfile.TemporaryDirectory() as name:
                out = Path(name).resolve()
                app = out / 'HierarchyFixture.app'; app.mkdir()
                (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': session.BUNDLE}))
                data = out / 'data'; (data / 'Documents').mkdir(parents=True)
                (data / 'Documents/geometry-oracle.json').write_text('{}')
                before = {'frontPID': 11, 'frontStart': [1, 0], 'frontBundle': 'original', 'frontPath': '/original',
                          'hostPID': 22, 'hostWindows': [], 'desktopUnlocked': True,
                          'displays': [{'type': {'integrated': {}}, 'active': True, 'currentOrientation': 'rot0'}]}
                target = {'pid': 42, 'start': [100, 0], 'path': str(app / 'HierarchyFixture'), 'deviceID': 'device',
                          'state': 2, 'traced': False}
                installed = False
                class Claim:
                    def __init__(self, *_): pass
                    def acquire(self): events.append('claim')
                    def check(self): pass
                    def release(self): events.append('release')
                def run(argv, **kw):
                    nonlocal installed
                    events.append(argv[2])
                    if argv[2] == 'install': installed = True
                    if argv[2] == 'uninstall': installed = False
                def launch(argv, **kw):
                    events.append('launch')
                    return session.BUNDLE + ': 42\n'
                def popen(argv, **kw):
                    kw['stdout'].write(json.dumps({'status': 'unsupported'})); kw['stdout'].flush()
                    return SimpleNamespace(poll=lambda: 0)
                def finish(*args, **kw): events.append('capture-cleanup'); return 0
                def restore(*args): events.append('restore'); return before
                def reserve(deadline, seconds, label):
                    if admission_denied and label == 'capture admission':
                        raise TimeoutError('admission denied')
                    return original_reserve(deadline, seconds, label)
                with patch.object(session, 'worker_startup'), patch.dict(os.environ, MAC_CU_FIXTURE_WORKER='token'), \
                     patch.multiple(session, reserve=reserve, verify_prepared=lambda _: None, booted=lambda _: {}, Claim=Claim,
                        InputGuard=lambda: SimpleNamespace(check=lambda: None),
                        probe=lambda build, out, name, device: before if name == 'before' else dict(before, frontPID=42, frontStart=target['start'], frontPath=target['path'], deviceID='device'),
                        fixture_inventory=lambda _: {'Path': str(app)} if installed else None,
                        fixture_data=lambda *args: [str(data)] if installed else [],
                        finish_capture=finish, restore_foreground=restore,
                        publish_target_binding=lambda *args: {'test': 'bound target'},
                        publish_target_cleanup=lambda *args: events.append('cleanup-phase')), \
                     patch.object(session.capture, 'ProcessProbe', return_value=SimpleNamespace(identity=lambda *a, **k: target)), \
                     patch.object(session.capture, 'verify_target', return_value=target), \
                     patch.object(session.time, 'time', return_value=100), \
                     patch.object(session.subprocess, 'run', side_effect=run), \
                     patch.object(session.subprocess, 'check_output', side_effect=launch), \
                     patch.object(session.subprocess, 'Popen', side_effect=popen), \
                     patch.object(session, 'residual', side_effect=[{'state': 'live', 'current': target}, {'state': 'gone'}, {'state': 'gone'}]):
                    self.assertEqual(session.worker(out, out, 'device', 'token', os.getppid(), session.monotonic() + session.TOTAL), 1)
                report = json.loads((out / 'session.json').read_text())
                self.assertTrue(report['fixtureRemoved'] and report['restorationVerified'] and report['claimReleased'])
                self.assertLess(events.index('cleanup-phase'), events.index('terminate'))
                if admission_denied:
                    self.assertNotIn('capture-cleanup', events)
                    self.assertIn('admission denied', str(report['errors']))
                else:
                    self.assertIn('capture-cleanup', events, str(report))
                    self.assertLess(events.index('capture-cleanup'), events.index('terminate'))
                for a, b in zip(('terminate', 'uninstall', 'restore'), ('uninstall', 'restore', 'release')):
                    self.assertLess(events.index(a), events.index(b))


    def test_live_probe_uses_fixed_direct_child_cleanup_without_group_signals(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as name:
            out = Path(name)
            child = SimpleNamespace(pid=42, returncode=0, poll=lambda: 0)
            def start(argv, **kw):
                self.assertEqual(argv, [str(out / 'session-probe'), '--native-check'])
                self.assertTrue(kw['start_new_session'])
                kw['stdout'].write('{"readOnly":true}'); kw['stdout'].flush()
                return child
            with patch.object(session.native, 'instances', return_value=[]), \
                 patch.object(session, 'ProbeFamilyReadback') as family_type, \
                 patch.object(session.subprocess, 'Popen', side_effect=start), \
                 patch.object(session.watchdog, 'graceful_stop') as graceful, \
                 patch.object(session.watchdog, 'finish_direct_worker') as finish, \
                 patch.object(session.watchdog, 'wait_group_readback', return_value={'groupEmpty': True}), \
                 patch.object(os, 'killpg', side_effect=AssertionError('PGID signal')):
                family_type.return_value.report = {}
                self.assertEqual(session.probe(out, out, 'read-only', 'device'), {'readOnly': True})
            graceful.assert_called_once(); finish.assert_called_once()

    def test_probe_does_not_launch_after_preflight_uses_work_budget(self):
        now = [0.0]
        def preflight(executable):
            now[0] = 12.0
            return []
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with patch.object(session, 'monotonic', side_effect=lambda: now[0]), \
                 patch.object(session.native, 'instances', side_effect=preflight), \
                 patch.object(session.subprocess, 'Popen', side_effect=AssertionError('late probe launch')) as launch:
                with self.assertRaisesRegex(TimeoutError, 'probe deadline'):
                    session.probe(out, out, 'expired-preflight', 'unused')
                launch.assert_not_called()

    def test_probe_failure_and_cancellation_keep_direct_cleanup_and_group_readback(self):
        from types import SimpleNamespace
        for cancellation in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                def poll():
                    if cancellation: raise InterruptedError('controlled cancellation')
                    return 1
                child = SimpleNamespace(pid=42, returncode=1, poll=poll)
                with patch.object(session.native, 'instances', return_value=[]), \
                     patch.object(session, 'ProbeFamilyReadback') as family_type, \
                     patch.object(session.subprocess, 'Popen', return_value=child), \
                     patch.object(session.watchdog, 'graceful_stop') as graceful, \
                     patch.object(session.watchdog, 'finish_direct_worker') as finish, \
                     patch.object(session.watchdog, 'wait_group_readback', return_value={'groupEmpty': True}) as readback, \
                     patch.object(os, 'killpg', side_effect=AssertionError('group signal')):
                    family_type.return_value.report = {}
                    with self.assertRaises(InterruptedError if cancellation else RuntimeError):
                        session.probe(out, out, 'failure', 'unused')
                    graceful.assert_called_once(); finish.assert_called_once()
                    readback.assert_called_once_with(42, timeout=0)

    def test_launch_diagnostics_keep_exact_fixture_argv_and_no_console_or_terminate(self):
        argv = session.fixture_launch_arguments('device', 'token')
        self.assertEqual(argv[-4:], ['device', session.BUNDLE, '--fixture-session', 'token'])
        self.assertFalse(any(a.startswith(('--stdout=', '--stderr=')) for a in argv))
        self.assertFalse(any(a in argv for a in ('--console', '--console-pty', '--terminate-running-process')))

    def test_ready_oracle_is_preserved_before_orientation_guard_failure(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); data = root / 'data'; (data / 'Documents').mkdir(parents=True)
            out = root / 'evidence'; out.mkdir()
            raw = '{"orientation":3,"coordinateSpace":"UIScreen.fixedCoordinateSpace points"}'
            (data / 'Documents/geometry-oracle.json').write_text(raw)
            (data / 'Documents/fixture-lifecycle.log').write_text('fixture.scene.didBecomeActive\n')
            result = session.preserve_fixture_evidence(data, out, 'before')
            with self.assertRaises(RuntimeError):
                session.require_static_portrait({'desktopUnlocked': True, 'displays': [
                    {'type': {'integrated': {}}, 'active': True, 'currentOrientation': 'rot90'}]})
            self.assertEqual((out / 'oracle-before.json').read_text(), raw)
            self.assertIn('fixture-lifecycle.log', result)

    def test_oracle_wait_observes_owned_exit_without_extending_timeout(self):
        with tempfile.TemporaryDirectory() as name, \
             patch.object(session, 'residual', return_value={'state': 'gone'}), \
             patch.object(session.time, 'sleep', side_effect=AssertionError('waited after known exit')):
            with self.assertRaisesRegex(RuntimeError, 'exact target residual'):
                session.wait_for_oracle(Path(name) / 'missing.json', None, {'pid': 42}, lambda: False)

    def test_diagnostic_alternative_never_replaces_original_pass_criterion(self):
        import compare, copy, struct
        expected = [[0,0],[10,0],[10,20],[0,20]]
        bad = [[0,0],[10,0],[10,0],[0,0]]
        screen = {'scale':1,'orientation':1,'bounds':[0,0,100,200]}
        nodes, roots, oracle_views = {}, [], []
        for i, name in enumerate(sorted(compare.EXPECTED)):
            identity = 'synthetic-' + str(i)
            stages = {'rawBounds':[0,0,10,20], 'getters':{'minX':0,'minY':0,'maxX':10,'maxY':20},
                      'originalStored':bad,'originalWindow':bad,'originalScreen':bad,
                      'duplicateMakeImmediate':bad,'duplicateMakeStored':bad,'duplicateMakeWindow':bad,'duplicateMakeScreen':bad,
                      'fieldStored':expected,'fieldWindow':expected,'fieldScreen':expected}
            g = {'id':identity,'bounds':[0,0,10,20],'corners':bad,'cornerDiagnostics':stages,'screen':screen,
                 'clipsToBounds':False,'verified':False,'overlayEnabled':False,'clippingVerified':False}
            nodes[identity] = g
            roots.append({'id':identity,'accessibilityIdentifier':name,'geometry':g,'hidden':False,'parentID':None,'children':None})
            oracle_views.append({'id':name,'corners':expected,'hidden':False,'clipsToBounds':False,'parentID':None})
        target = {'pid':42,'start':[1,0],'path':'/synthetic','deviceID':'synthetic'}
        recovery = {'verified':True,'target':target}
        result = {'status':'success','detach':'success','connected':True,'attachRequested':True,
            'mainThread':{'queue':'com.apple.main-thread','isMainThread':True},'target':target,
            'clockTransmission':{'clock':'CLOCK_MONOTONIC','deadlineMonotonic':100,'sentMonotonic':1,'remainingAtSendSeconds':99},
            'deadlineReceipt':{'clock':'CLOCK_MONOTONIC','deadlineMonotonic':100,'receivedMonotonic':2,'remainingAtReceiptSeconds':98},
            'cleanup':{'childrenReaped':True,'recovery':recovery},'recovery':recovery,'verified':False,'overlayEnabled':False,
            'geometry':{'nodes':nodes},'captureIntervalUnixSeconds':[1,2]}
        oracle = {'views':oracle_views,'orientation':1,'screenScale':1,'screenBounds':[0,0,100,200],'capturedAt':'synthetic'}
        original = copy.deepcopy(result)
        with tempfile.TemporaryDirectory() as name:
            png=Path(name)/'dimensions.png';png.write_bytes(b'\x89PNG\r\n\x1a\n'+b'\x00\x00\x00\x0dIHDR'+struct.pack('>II',100,200))
            report=compare.diagnose(result,{'roots':roots},oracle,png)
            self.assertFalse(report['strictGate']['passed'])
            self.assertEqual(len(report['rows']),7)
            for row in report['rows']:
                self.assertEqual(row['measurements']['originalScreenVsOracle'],20)
                self.assertEqual(row['measurements']['fieldScreenVsOracle'],0)
                self.assertTrue(row['causeHints'])
            self.assertFalse(report['verified'] or report['overlayEnabled'])
            self.assertEqual(result,original)

    def test_nonportrait_and_folded_are_refused(self):
        good = {'desktopUnlocked': True, 'displays': [{'type': {'integrated': {}}, 'active': True, 'currentOrientation': 'rot0'}]}
        session.require_static_portrait(good)
        for bad in ({**good, 'desktopUnlocked': False}, {**good, 'displays': good['displays'] * 2},
                    {**good, 'displays': [{**good['displays'][0], 'currentOrientation': 'rot90'}]}):
            with self.assertRaises(RuntimeError):
                session.require_static_portrait(bad)

class DeadlineChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.out = Path(self.folder.name)
        self.build = self.out / 'prepared'; self.build.mkdir()
        (self.build / 'prepared.json').write_text(json.dumps({'dispatchPassed': True, 'hashes': {}}))

    def tearDown(self):
        self.folder.cleanup()

    def command(self, deadline, output):
        return [sys.executable, '-B', str(HERE / 'session.py'), '--guard', '--build', str(self.build),
                '--output', str(output), '--device', '00000000-0000-0000-0000-000000000001', '--deadline', deadline]

    def utc(self, seconds):
        import datetime
        return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    def test_strict_utc_expiry_and_internal_cap(self):
        with patch.object(session.time, 'time', return_value=1000), patch.object(session, 'monotonic', return_value=500):
            end, _ = session.received_deadline(self.utc(1300))
            self.assertEqual(end, 800)
            end, _ = session.received_deadline(self.utc(2000))
            self.assertEqual(end, 860)
            for invalid in ('tomorrow', '2026-11-09T08:27:08+09:00', '2026-11-08T23:27:08.000Z', self.utc(999), self.utc(1000)):
                with self.assertRaises(ValueError):
                    session.received_deadline(invalid)

    def test_clock_change_cannot_restart_deadline(self):
        with patch.object(session.time, 'time', return_value=1000) as wall, patch.object(session, 'monotonic', return_value=500):
            end, _ = session.received_deadline(self.utc(1320))
            self.assertEqual(wall.call_count, 1)
        with patch.object(session.time, 'time', side_effect=AssertionError('wall clock reread')), \
             patch.object(session, 'monotonic', return_value=540):
            budget = session.session_budget(end)
            self.assertEqual(budget['deadlineMonotonic'], 820)
            self.assertEqual(budget['captureAdmissionMonotonic'], 535)
            with self.assertRaises(TimeoutError):
                session.reserve(budget['captureAdmissionMonotonic'], 0, 'delayed admission')
            self.assertEqual(budget['usableDeadlineMonotonic'], 815)

    def test_real_cli_parent_worker_guard_preserves_exact_deadline(self):
        import time
        output = self.out / 'guard'
        run = subprocess.run(self.command(self.utc(time.time() + 310), output), capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        parent = json.loads((output / 'parent.json').read_text())
        worker = json.loads((output / 'session.json').read_text())
        self.assertTrue(parent['guard'] and worker['guard'] and worker['passed'])
        self.assertEqual(worker['mutationCount'], 0)
        self.assertEqual(parent['deadlineMonotonic'], worker['deadlineMonotonic'])
        self.assertEqual(worker['usableDeadlineMonotonic'], parent['deadlineMonotonic'] - 5)
        self.assertEqual(worker['captureAdmissionMonotonic'], parent['deadlineMonotonic'] - (163 + 117 + 5))
        self.assertEqual(worker['parentStopMonotonic'], parent['deadlineMonotonic'] - 240)
        self.assertGreaterEqual(worker['workerReceivedMonotonic'], parent['receivedMonotonic'])
        self.assertTrue(parent['group']['groupEmpty'])
        self.assertTrue(parent['workerDeadlineTransmissionVerified'])
        self.assertLessEqual(worker['workerRemainingAtReceiptSeconds'], parent['remainingAtWorkerSendSeconds'] + .001)

    def test_xcode_python_cli_parent_worker_share_clock_epoch(self):
        import time
        output = self.out / 'xcode-guard'
        argv = self.command(self.utc(time.time() + 310), output)
        run = subprocess.run(['/usr/bin/xcrun', 'python3', *argv[1:]], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        parent = json.loads((output / 'parent.json').read_text())
        worker = json.loads((output / 'session.json').read_text())
        self.assertEqual(parent['clock'], worker['clock'])
        self.assertGreaterEqual(worker['workerReceivedMonotonic'], parent['workerSendMonotonic'] - .001)
        self.assertLessEqual(worker['workerRemainingAtReceiptSeconds'], parent['remainingAtWorkerSendSeconds'] + .001)
        self.assertTrue(parent['workerDeadlineTransmissionVerified'])
        self.assertEqual(worker['mutationCount'], 0)

    def test_cli_bad_expired_or_below_reserve_never_starts_worker(self):
        import time
        for i, deadline in enumerate(('not-UTC', self.utc(time.time() - 1), self.utc(time.time() + 284))):
            output = self.out / str(i)
            run = subprocess.run(self.command(deadline, output), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(output.exists(), run.stderr)

    def test_actual_worker_dispatch_below_reserve_has_no_claim_or_simctl(self):
        import time
        output = self.out / 'actual-worker-admission'; output.mkdir()
        argv = ['session.py', '--worker', str(self.build), str(output), 'device', 'token', str(os.getppid()), str(session.monotonic() + 284)]
        with patch.object(sys, 'argv', argv), patch.dict(os.environ, MAC_CU_FIXTURE_WORKER='token'), \
             patch.object(session.Claim, 'acquire', side_effect=AssertionError('claim mutation')), \
             patch.object(session.subprocess, 'run', side_effect=AssertionError('simctl mutation')), \
             patch.object(session.subprocess, 'check_output', side_effect=AssertionError('inventory or launch')), \
             patch.object(session.subprocess, 'Popen', side_effect=AssertionError('child launch')):
            self.assertEqual(session.main(), 1)
        report = json.loads((output / 'session.json').read_text())
        self.assertFalse(report['passed'])
        self.assertIn('worker admission', str(report['errors']))
        self.assertNotIn('target', report)
        self.assertNotIn('claimReleased', report)

    def test_same_cli_route_rejects_delayed_worker_without_mutation(self):
        clock = [500.0]
        output = self.out / 'delayed-worker'
        command = self.command(self.utc(1310), output)[3:]
        class DelayedChild:
            pid = os.getpid()
            def __init__(self, argv, env, **kwargs):
                clock[0] += 31  # Parent had 310s; worker receives 279s, below the 285s reserve.
                with patch.dict(os.environ, env), patch.object(os, 'getppid', return_value=os.getpid()):
                    self.returncode = session.guard_worker(Path(argv[5]), float(argv[9]), argv[7], int(argv[8]))
            def poll(self): return self.returncode
            def wait(self, timeout): return self.returncode
        with patch.object(sys, 'argv', ['session.py', *command]), \
             patch.object(session.time, 'time', return_value=1000), \
             patch.object(session, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(session.subprocess, 'Popen', side_effect=DelayedChild), \
             patch.object(session.watchdog, 'process_identity', return_value=dict(pid=os.getpid(),start=[1,0],path='/python',parent=1,group=1)), \
             patch.object(session, 'await_worker_ready'), \
             patch.object(session.watchdog, 'wait_group_readback', return_value={'groupEmpty': True}), \
             patch.object(session.Claim, 'acquire', side_effect=AssertionError('mutation')):
            self.assertEqual(session.main(), 1)
        parent = json.loads((output / 'parent.json').read_text())
        worker = json.loads((output / 'session.json').read_text())
        self.assertEqual(parent['deadlineMonotonic'], worker['deadlineMonotonic'])
        self.assertFalse(worker['passed'])
        self.assertEqual(worker['mutationCount'], 0)
        self.assertIn('insufficient', worker['error'])


class ProcessObservationParentTests(unittest.TestCase):
    def test_initial_ps_shares_parent_clock_cutoff_and_legacy_callback(self):
        now = [1000.0]
        timeouts, calls = [], []
        def rows(timeout):
            timeouts.append(timeout)
            now[0] += .25
            return []
        def legacy(snapshot, group, target, build, server, details):
            calls.append((snapshot, group))
        with patch.object(session, 'monotonic', side_effect=lambda: now[0]), \
             patch.object(session.watchdog, 'rows', side_effect=rows):
            session.observe_processes(40, None, Path('/tmp/build'), None, {}, 1001,
                                      process_check=legacy)
        self.assertEqual(timeouts, [1])
        self.assertEqual(calls, [([], 40)])


if __name__ == '__main__':
    unittest.main()

class TargetBindingPublication(unittest.TestCase):
    def test_running_sleeping_transitions_preserve_identity_but_invalid_second_reads_reject(self):
        from types import SimpleNamespace
        target = dict(pid=200, start=[10, 200], path='/fixture', deviceID='DEVICE')
        owner = '11111111-1111-4111-8111-111111111111'
        for first_state, second_state, change, accepted in (
                (2, 3, {}, True), (3, 2, {}, True),
                (2, 4, {}, False), (2, 5, {}, False),
                (2, 3, {'traced': True}, False),
                (2, 3, {'start': [99, 0]}, False),
                (2, 3, {'path': '/other'}, False),
                (2, 3, {'deviceID': 'OTHER'}, False),
                (2, 3, {'parent': 51}, False)):
            with self.subTest(first=first_state, second=second_state, change=change), \
                    tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                values = iter([dict(target, parent=50, state=first_state, traced=False),
                               {**target, 'parent': 50, 'state': second_state, 'traced': False, **change}])
                pp = SimpleNamespace(identity=lambda *a, **k: next(values))
                def read(pid):
                    return dict(pid=pid, start=[10, pid], path='/fixture' if pid == 200 else '/parent',
                                parent=50 if pid == 200 else 1, group=pid, state=2)
                with patch.object(session, 'monotonic', return_value=0), \
                        patch.object(session.watchdog, 'process_identity', side_effect=read):
                    if accepted:
                        session.publish_target_binding(out, target, pp, owner, 1, SimpleNamespace(check=lambda: None))
                    else:
                        with self.assertRaises(RuntimeError):
                            session.publish_target_binding(out, target, pp, owner, 1, SimpleNamespace(check=lambda: None))
                self.assertEqual((out / 'target.json').exists(), accepted)

    def test_order_closed_wire_schema_and_bounded_read(self):
        from types import SimpleNamespace
        target = dict(pid=200, start=[10, 200], path='/fixture', deviceID='DEVICE')
        def info(pid, parent, group, path):
            return dict(pid=pid, start=[10, pid], path=path, parent=parent, group=group, state=2)
        identities = {200:info(200, 50, 200, '/fixture'), 50:info(50, 1, 50, '/launchd'),
                      os.getpid():info(os.getpid(), 30, os.getpid(), '/python')}
        actual = dict(target, parent=50, state=2, traced=False)
        pp = SimpleNamespace(identity=lambda *args, **kw: dict(actual))
        owner = '11111111-1111-4111-8111-111111111111'
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory); order=[]; original=session.save
            def save(path, value):
                order.append(path.name)
                if path.name == 'target.json':
                    self.assertTrue((out/'target-observation.json').is_file())
                    self.assertEqual(set(value), {'pid','start','path','deviceID'})
                original(path,value)
            with patch.object(session, 'monotonic', return_value=0), \
                 patch.object(session.watchdog, 'process_identity', side_effect=lambda pid: dict(identities[pid])), \
                 patch.object(session, 'save', side_effect=save):
                binding=session.publish_target_binding(out,target,pp,owner,1,SimpleNamespace(check=lambda:None))
            self.assertEqual(order,['target-observation.json','target.json'])
            self.assertEqual(session.read_target_binding(out,target,identities[os.getpid()],owner),binding)
            for change in (lambda b:b.update(extra=1), lambda b:b.update(owner='wrong'),
                           lambda b:b['worker'].update(start=[99,0]),
                           lambda b:b['originalParent'].update(extra=1)):
                value=json.loads(json.dumps(binding));change(value)
                original(out/'target-observation.json',value)
                with self.assertRaises(RuntimeError):session.read_target_binding(out,target,identities[os.getpid()],owner)
            (out/'target-observation.json').write_bytes(b' '*16385)
            with self.assertRaises(RuntimeError):session.read_target_binding(out,target,identities[os.getpid()],owner)
            (out/'target-observation.json').unlink()
            with self.assertRaises(FileNotFoundError):session.read_target_binding(out,target,identities[os.getpid()],owner)

    def test_publication_identity_change_input_and_deadline_leave_target_hidden(self):
        from types import SimpleNamespace
        target=dict(pid=200,start=[10,200],path='/fixture',deviceID='DEVICE')
        owner='11111111-1111-4111-8111-111111111111'
        for mode in ('traced','changed','input','deadline'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                out=Path(directory);now=[0];calls=[0]
                def read(pid):
                    calls[0]+=1
                    if mode=='deadline':now[0]=5
                    return dict(pid=pid,start=[10,pid],path='/fixture' if pid==200 else '/parent',
                                parent=50 if pid==200 else 1,group=pid,state=2)
                def device(*args,**kw):
                    return dict(target,parent=50,traced=mode=='traced',state=2,
                                **({'start':[99,0]} if mode=='changed' else {}))
                def check():
                    if mode=='input':raise InterruptedError('input')
                with patch.object(session,'monotonic',side_effect=lambda:now[0]), \
                     patch.object(session.watchdog,'process_identity',side_effect=read), self.assertRaises((RuntimeError,TimeoutError,InterruptedError)):
                    session.publish_target_binding(out,target,SimpleNamespace(identity=device),owner,1,SimpleNamespace(check=check))
                self.assertFalse((out/'target.json').exists())


class TargetCleanupObservation(unittest.TestCase):
    """The real parent/observer runs; process, clock and cleanup effects are mocked."""
    def run_parent(self, mode='normal', callback=None):
        from types import SimpleNamespace
        from test_probe_family import SERVER
        owner = '11111111-1111-4111-8111-111111111111'
        target = dict(pid=200, start=[10, 200], path='/fixture', deviceID='DEVICE')
        def info(pid, parent, group, path):
            return dict(pid=pid, parent=parent, group=group, path=path, start=[10, pid], state=2)
        identities = {os.getpid(): info(os.getpid(), 1, 1, '/python'),
                      200: info(200, 50, 200, '/fixture'), 50: info(50, 1, 50, '/launchd'),
                      40: info(40, os.getpid(), 40, '/python')}
        binding = dict(version=1, owner=owner, worker=session.watchdog.lifetime(identities[40]),
                       target=target, group=200, originalParent=session.watchdog.lifetime(identities[50]))
        now, sleeps, seen = [0.0], [0], []
        stage = ['live' if mode in ('normal', 'during-read') else 'gone']
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'session'
            child = SimpleNamespace(pid=40, returncode=None)
            child.poll = lambda: child.returncode
            child.wait = lambda **kw: 0 if child.returncode is None else child.returncode
            def cleanup_phase():
                value = {'phase': 'cleanup', 'binding': binding}
                if mode == 'wrong-owner':
                    value = json.loads(json.dumps(value)); value['binding']['owner'] = '22222222-2222-4222-8222-222222222222'
                session.save(out / 'target-cleanup.json', value)
            def launch(*a, **k):
                session.save(out / 'worker-ready.json', dict(version=1, owner=owner,
                    parent=session.watchdog.lifetime(identities[os.getpid()]), worker=binding['worker']))
                session.save(out / 'target-observation.json', binding)
                session.save(out / 'target.json', target)
                if stage[0] == 'gone' and mode != 'unannounced': cleanup_phase()
                return child
            worker_reads = [0]
            def identity(pid):
                now[0] += .01
                if pid == 40:
                    worker_reads[0] += 1
                    if mode == 'worker-reused' and worker_reads[0] > 1:
                        return dict(identities[pid], start=[99, 0])
                if pid == 200 and stage[0] != 'live':
                    if mode == 'reused': return dict(identities[pid], start=[99, 0])
                    raise session.watchdog.IdentityReadError('target read unavailable', None, 'mock', 0, 1 if mode == 'denied' else 3)
                if pid == 201:
                    if mode == 'retained' and snapshots[0] == 1:
                        raise session.watchdog.IdentityReadError('child unresolved', None, 'mock', 0, 1)
                    return info(201, 1, 999 if mode == 'retained' else 200, '/unexpected')
                return dict(identities[pid])
            def status(pid):
                if mode == 'expired': now[0] += 10
                if mode in ('zombie', 'zombie-to-gone') and (mode == 'zombie' or snapshots[0] == 1):
                    return dict(identities[pid], state=5)
                return identity(pid)
            def device(pid, device=False):
                if mode == 'during-read' and stage[0] == 'live':
                    cleanup_phase(); stage[0] = 'gone'
                    raise session.capture.CaptureError('identityUnknown', 'target exited during device read')
                return dict(identity(pid), deviceID='DEVICE', traced=False)
            def kill(pid, sig):
                if mode == 'retained' and pid == 201:
                    self.assertEqual(sig, 0)
                    return 0  # The known descendant is still alive after reparenting.
                self.assertEqual((pid, sig), (200, 0))
                if mode in ('denied', 'kill-denied'): raise PermissionError(1, 'denied')
                raise ProcessLookupError(3, 'absent')
            snapshots = [0]
            def rows(**kw):
                now[0] += .05; snapshots[0] += 1
                values = [(200, 50, 200, '/fixture', 'S')] if stage[0] == 'live' else []
                if mode == 'orphan': values.append((201, 1, 200, '/unexpected', 'S'))
                if mode == 'descendant': values.append((201, 200, 200, '/unexpected', 'S'))
                if mode == 'duplicate': values.append((202, 1, 202, '/fixture', 'S'))
                if mode == 'retained' and snapshots[0] == 1:
                    values.append((201, 200, 999, '/unexpected', 'S'))
                return values
            def sleep(_):
                sleeps[0] += 1; now[0] += .1
                if stage[0] == 'live':
                    cleanup_phase(); stage[0] = 'gone'
                else:
                    session.save(out / 'session.json', dict(workerReceivedMonotonic=0,
                        workerRemainingAtReceiptSeconds=360, deadlineMonotonic=360, passed=True))
                    child.returncode = 0
            def check(snapshot, *args):
                seen.append(stage[0])
                if callback: callback(snapshot, *args)
            def input_check():
                if mode == 'input' and snapshots[0]: raise InterruptedError('input during cleanup observation')
            with patch.object(session.uuid, 'uuid4', return_value=owner), \
                    patch.object(session, 'verify_prepared'), patch.object(session, 'booted'), \
                    patch.object(session, 'InputGuard', return_value=SimpleNamespace(check=input_check)), \
                    patch.object(session.capture, 'tools_for_xcode', return_value=(SERVER, None, None)), \
                    patch.object(session.capture, 'ProcessProbe', return_value=SimpleNamespace(identity=device)), \
                    patch.object(session.subprocess, 'Popen', side_effect=launch), \
                    patch.object(session.watchdog, 'process_identity', side_effect=identity), \
                    patch.object(session.watchdog, 'process_status', side_effect=status), \
                    patch.object(session.watchdog, 'rows', side_effect=rows), \
                    patch.object(session.os, 'kill', side_effect=kill), \
                    patch.object(session, 'monotonic', side_effect=lambda: now[0]), \
                    patch.object(session.time, 'sleep', side_effect=sleep), patch.object(session.signal, 'signal'), \
                    patch.object(session.watchdog, 'graceful_stop'), \
                    patch.object(session.watchdog, 'wait_group_readback', return_value={'groupEmpty': True}):
                result = session.parent(Path('/mock'), out, 'DEVICE', 360, {}, process_check=check)
            return result, json.loads((out / 'parent.json').read_text()), seen

    def test_normal_worker_cleanup_and_inflight_target_exit_complete_parent(self):
        from test_probe_family import callbacks
        for name, callback in callbacks():
            for mode in ('normal', 'during-read', 'zombie-to-gone'):
                with self.subTest(callback=name, mode=mode):
                    result, report, seen = self.run_parent(mode, callback)
                    self.assertEqual(result, 0, report)
                    self.assertIn('gone', seen)
                    self.assertTrue(report['workerDeadlineTransmissionVerified'])

    def test_exit_without_cleanup_unknown_or_reused_target_never_accept(self):
        for mode in ('unannounced', 'denied', 'kill-denied', 'reused', 'worker-reused', 'wrong-owner', 'zombie', 'expired', 'input'):
            with self.subTest(mode=mode):
                result, report, _ = self.run_parent(mode)
                self.assertEqual(result, 1)
                self.assertIn('error', report)

    def test_cleanup_keeps_descendant_orphan_and_duplicate_checks_in_all_callbacks(self):
        from test_probe_family import callbacks
        for name, callback in callbacks():
            for mode in ('orphan', 'descendant', 'duplicate', 'retained'):
                with self.subTest(callback=name, mode=mode):
                    result, report, _ = self.run_parent(mode, callback)
                    self.assertEqual(result, 1)
                    self.assertTrue(report.get('error', '').startswith('IdentityChanged('), report.get('error'))

    def test_cleanup_marker_is_bounded_and_bound_to_the_complete_session(self):
        target = dict(pid=200, start=[10, 200], path='/fixture', deviceID='DEVICE')
        worker = dict(pid=40, start=[10, 40], path='/python', parent=30, group=40)
        parent = dict(pid=50, start=[10, 50], path='/launchd', parent=1, group=50)
        binding = dict(version=1, owner='11111111-1111-4111-8111-111111111111',
                       worker=worker, target=target, group=200, originalParent=parent)
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory); path = out / 'target-cleanup.json'
            self.assertFalse(session.read_target_cleanup(path, binding))
            session.publish_target_cleanup(out, binding)
            self.assertTrue(session.read_target_cleanup(path, binding))
            for change in (lambda v: v.update(extra=1), lambda v: v.update(phase='running'),
                           lambda v: v['binding']['worker'].update(start=[99, 0]),
                           lambda v: v['binding']['target'].update(path='/other'),
                           lambda v: v['binding'].update(group=999)):
                value = dict(phase='cleanup', binding=json.loads(json.dumps(binding)))
                change(value); session.save(path, value)
                with self.assertRaises(RuntimeError): session.read_target_cleanup(path, binding)
            path.write_bytes(b' ' * 16385)
            with self.assertRaises(RuntimeError): session.read_target_cleanup(path, binding)
