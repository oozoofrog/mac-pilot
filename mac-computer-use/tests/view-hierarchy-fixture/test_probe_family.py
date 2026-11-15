"""Real shared observation/callback regression contract; no native processes."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import session as s

SERVER = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
# Resolve through Contents explicitly: framework Versions nesting is toolchain-dependent.
CONTENTS = next(p for p in SERVER.parents if p.name == 'Contents')
PYTHON = str((CONTENTS / 'Developer/usr/bin/python3').resolve())
PYTHON_APP = str(Path(PYTHON).parent.parent / 'Resources/Python.app/Contents/MacOS/Python')


def callbacks():
    # Load real owning callbacks without leaking their runtime configuration into
    # the fixture suite. Eager restoration also covers next(callbacks()).
    result = []
    names = ('protocol', 'debugger', 'runner', 'graph', 'worker_runtime')
    fields = ('TOTAL', 'WORK', 'GRACE', 'CAPTURE_ADMISSION', 'BUNDLE', 'APP_NAME', 'EXECUTABLE')
    for name in ('swiftui-hierarchy-probe', 'view-resident-lifetime', 'view-resident-product'):
        directory = s.TESTS / name
        saved = {key:sys.modules.get(key) for key in names}
        values = {key:getattr(s,key) for key in fields}
        oldpath = list(sys.path)
        try:
            for key in names: sys.modules.pop(key, None)
            sys.path[:0] = [str(directory), str(s.TESTS / 'view-resident-lifetime')]
            spec = importlib.util.spec_from_file_location('family_' + name.replace('-', '_'), directory / 'runner.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            result.append((name, module.process_budget))
        finally:
            sys.path[:] = oldpath
            for key in names:
                sys.modules.pop(key,None)
                if saved[key] is not None: sys.modules[key] = saved[key]
            for key,value in values.items(): setattr(s,key,value)
    return iter(result)


class ProbeFamily(unittest.TestCase):
    def observe(self, callback, transform=lambda rows: rows, unknown=None, changed=None, argv=None):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve(); (build / 'session-probe').touch()
            self.build = build
            rows = transform([(100, 40, 100, str(build / 'session-probe'), 'S'),
                              (101, 100, 101, PYTHON_APP, 'S')])
            now = [0.0]
            def snapshot(timeout): now[0] += .2; return rows
            def identify(pid):
                row = next(r for r in rows if r[0] == pid)
                info = dict(pid=pid, parent=row[1], group=row[2], path=row[3], start=[10, pid], state=2)
                s.watchdog._observation.get().record(pid, 'controlled-kernel', 1, 0, info)
                if changed: return changed(pid, info)
                return s.watchdog.UNVERIFIED if pid == unknown else info
            args = ['python3', '-I', str(build / 'view-capture/capture.py'), '--identity', '222',
                    '11111111-1111-4111-8111-111111111111']
            self.details = {}
            with patch.object(s, 'monotonic', side_effect=lambda: now[0]), \
                 patch.object(s.watchdog, 'rows', side_effect=snapshot), \
                 patch.object(s.watchdog, 'identify_live_server', side_effect=identify), \
                 patch.object(s.watchdog, 'process_identity', side_effect=identify), \
                 patch.object(s.watchdog, 'process_arguments', **({'side_effect': argv} if callable(argv) else {'return_value': args if argv is None else argv})), \
                 patch.object(os, 'kill', side_effect=AssertionError('observation cannot signal')), \
                 patch.object(os, 'killpg', side_effect=AssertionError('observation cannot signal')), \
                 patch.object(os, 'waitpid', side_effect=AssertionError('observation cannot reap')):
                return s.observe_processes(40, None, build, SERVER, self.details, 1, process_check=callback)

    def test_canonical_identity_python_own_group_through_all_callbacks(self):
        for name, callback in callbacks():
            with self.subTest(callback=name): self.assertEqual(len(self.observe(callback)), 2)

    def test_identity_has_separate_budget_from_direct_lldb_worker(self):
        name, callback = next(callbacks())
        rows = self.observe(callback, lambda r: r + [(102, 40, 40, str(Path(sys.executable).resolve()), 'S')])
        self.assertEqual(len(rows), 3)

    def test_wrong_parent_group_path_extra_helper_and_illegal_deep_chain(self):
        cases = [lambda r: [r[0], (101, 40, 101, PYTHON_APP, 'S')],
                 lambda r: [r[0], (101, 100, 999, PYTHON_APP, 'S')],
                 lambda r: [r[0], (101, 100, 100, PYTHON_APP, 'S')],
                 lambda r: [r[0], (101, 100, 40, PYTHON_APP, 'S')],
                 lambda r: [r[0], (101, 100, 101, '/unselected/Python', 'S')],
                 lambda r: r + [(102, 100, 102, PYTHON_APP, 'S')],
                 lambda r: r + [(102, 40, 40, '/bin/ps', 'S')],
                 lambda r: r + [(102, 101, 101, '/bin/ps', 'S')],
                 lambda r: r + [(102, 101, 40, '/bin/ps', 'S')],
                 lambda r: r + [(102, 101, 40, str(SERVER), 'S')],
                 lambda r: r + [(102, 101, 102, PYTHON_APP, 'S')]]
        for name, callback in callbacks():
            for case in cases:
                with self.subTest(callback=name, case=cases.index(case)), self.assertRaises(RuntimeError):
                    self.observe(callback, case)

    def test_nonidentity_python_is_not_a_read_helper(self):
        for name, callback in callbacks():
            for args in (['python3','-c','pass'], ['python3','-I','/wrong/capture.py','--identity','222','device']):
                with self.subTest(callback=name, args=args), self.assertRaises(RuntimeError):
                    self.observe(callback, argv=args)

    def test_identity_change_still_rejected(self):
        def change(pid, info):
            if pid == 101:
                s.watchdog._observation.get().record(pid,'changed',1,0,dict(info,start=[20,1]))
            return info
        with self.assertRaises(s.watchdog.IdentityChanged): self.observe(next(callbacks())[1],changed=change)

    def test_orphan_identity_is_retained_after_probe_exit(self):
        def exits(pid, info): return None if pid == 100 else info
        with self.assertRaises(RuntimeError): self.observe(next(callbacks())[1],changed=exits)

    def test_unknown_parent_expires_under_single_cutoff(self):
        with self.assertRaises(s.watchdog.ObservationExpired): self.observe(next(callbacks())[1],unknown=100)

    def identity_args(self):
        return ['python3', '-I', str(self.build / 'view-capture/capture.py'), '--identity', '222',
                '11111111-1111-4111-8111-111111111111']

    def test_selected_launcher_alias_is_admitted_but_other_python_is_not(self):
        callback = next(callbacks())[1]
        self.observe(callback, lambda r: [r[0], (101,100,101,PYTHON,'S')])
        with self.assertRaises(RuntimeError):
            self.observe(callback, lambda r: [r[0], (101,100,101,'/usr/bin/python3','S')])

    def test_one_exact_worker_monitor_can_overlap_identity(self):
        callback = next(callbacks())[1]
        def args(pid):
            return ['/bin/ps','-axo','pid=,ppid=,pgid=,stat=,comm='] if pid == 102 else self.identity_args()
        self.observe(callback, lambda r: r + [(102,40,40,'/bin/ps','S')], argv=args)
        with self.assertRaises(RuntimeError):
            self.observe(callback, lambda r: r + [(102,40,40,'/bin/ps','S'),(103,40,40,'/bin/ps','S')], argv=args)

    def display_args(self, pid):
        if pid == 102:
            return ['/usr/libexec/PlistBuddy','-c','Print :CFBundleVersion',
                    '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist']
        device='11111111-1111-4111-8111-111111111111'
        return ['/bin/zsh', str(CONTENTS/'Developer/usr/bin/devicectl'), 'device','info','displays',
                '--device',device,'--quiet','--json-output','/private/tmp/mac-cu-displays-'+device+'-test.json']

    def test_display_wrapper_and_one_version_reader(self):
        def tree(r): return [r[0],(101,100,101,'/bin/zsh','S'),(102,101,101,'/usr/libexec/PlistBuddy','S')]
        for name, callback in callbacks():
            with self.subTest(callback=name): self.observe(callback,tree,argv=self.display_args)

    def test_display_wrapper_rejects_wrong_argv_extra_reader_and_fallback(self):
        def tree(r): return [r[0],(101,100,101,'/bin/zsh','S'),(102,101,101,'/usr/libexec/PlistBuddy','S')]
        callback=next(callbacks())[1]
        cases=[lambda r: tree(r)+[(103,101,101,'/usr/libexec/PlistBuddy','S')],
               lambda r: tree(r)+[(103,102,101,'/usr/libexec/PlistBuddy','S')],
               lambda r: [r[0],(101,100,101,'/bin/zsh','S'),(102,101,101,str(CONTENTS/'Developer/usr/bin/xcodebuild'),'S')],
               lambda r: [r[0],(101,100,101,'/bin/zsh','S'),(102,101,102,'/usr/libexec/PlistBuddy','S')]]
        for case in cases:
            with self.subTest(case=cases.index(case)),self.assertRaises(RuntimeError):
                self.observe(callback,case,argv=self.display_args)
        with self.assertRaises(RuntimeError): self.observe(callback,tree,argv=['/bin/zsh','-c','anything'])

    def test_unknown_argv_read_expires_without_replacing_cutoff(self):
        def unavailable(pid): raise s.watchdog.IdentityReadError('unknown argv',None,'sysctl-argv',-1,3)
        with self.assertRaises(s.watchdog.ObservationExpired): self.observe(next(callbacks())[1],argv=unavailable)


class ExecTransitions(unittest.TestCase):
    def run_transition(self, wrong=False, changed=None, post_state=False):
        callback=next(callbacks())[1]
        with tempfile.TemporaryDirectory() as directory:
            build=Path(directory).resolve();(build/'session-probe').touch()
            rows=[(100,40,100,str(build/'session-probe'),'S'),(101,100,101,'/usr/bin/xcrun','S')]
            def info(pid,path=None):
                row=next(r for r in rows if r[0]==pid)
                return dict(pid=pid,parent=row[1],group=row[2],path=path or row[3],start=[10,pid],state=2)
            stage=[0]
            def args(pid):
                tail=['-I',str(build/'view-capture/capture.py'),'--identity','222','11111111-1111-4111-8111-111111111111']
                if wrong and stage[0]:return ['python3','-c','pass']
                return ['/usr/bin/xcrun','python3',*tail] if stage[0]==0 else ['python3',*tail]
            def fresh(pid):
                stage[0]=1
                value=info(pid,PYTHON_APP)
                if changed:value.update(changed)
                s.watchdog._observation.get().record(pid,'proc_pidpath',1,0,value)
                return dict(value,state=3) if post_state else value
            details={}
            with patch.object(s,'monotonic',return_value=0),patch.object(s.watchdog,'rows',return_value=rows), \
                 patch.object(s.watchdog,'identify_live_server',side_effect=info), \
                 patch.object(s.watchdog,'process_identity',side_effect=fresh), \
                 patch.object(s.watchdog,'process_arguments',side_effect=args):
                result=s.observe_processes(40,None,build,SERVER,details,3,process_check=callback)
            return result,details

    def test_forward_exec_requires_same_lifetime_parent_group_and_exact_role(self):
        result,details=self.run_transition()
        self.assertEqual(result[-1][3],PYTHON_APP)
        self.assertEqual(sum(e.get('status')=='verifiedExecTransition' for e in details['residentExecutableObservations']),1)

    def test_scheduling_state_change_during_exec_is_not_a_lifetime_change(self):
        result,details=self.run_transition(post_state=True)
        self.assertEqual(result[-1][3],PYTHON_APP)

    def test_exec_does_not_hide_changed_identity_or_wrong_command(self):
        with self.assertRaises(s.watchdog.IdentityChanged): self.run_transition(wrong=True)
        for change in ({'start':[20,1]},{'parent':99},{'group':99},{'path':'/unrelated/Python'}):
            with self.subTest(change=change),self.assertRaises(s.watchdog.IdentityChanged): self.run_transition(changed=change)


class ProbeCleanup(unittest.TestCase):
    def test_unreadable_direct_child_can_finish_by_its_own_reap(self):
        class Child:
            pid=100
            returncode=None
            def poll(self):
                self.returncode=0
                return 0
        child=Child()
        family=s.ProbeFamilyReadback(child,Path('/private/test/session-probe'))
        exiting=(100,40,100,'/unavailable/(session-probe)','R')
        with patch.object(s.watchdog,'rows',side_effect=[[exiting],[]]), \
             patch.object(s.watchdog,'identify_live_server',return_value=s.watchdog.UNVERIFIED), \
             patch.object(os,'kill',side_effect=ProcessLookupError()):
            family.sample()
            family.finish(True)
        self.assertTrue(family.report['observedFamilyEmpty'])
        self.assertEqual(family.report['samples'][0]['identities'][0]['status'],'directReaped')
        self.assertFalse(family.report['signalAuthority'])

    def test_unknown_identity_needs_unreaped_direct_child_with_normal_completion(self):
        for initial,completion,pid in [(None,None,100),(None,1,100),(0,0,100),(None,0,101)]:
            with self.subTest(initial=initial,completion=completion,pid=pid):
                class Child:
                    returncode=initial
                    polls=0
                    def poll(self):
                        self.polls+=1
                        self.returncode=completion
                        return completion
                child=Child();child.pid=100
                family=s.ProbeFamilyReadback(child,Path('/private/test/session-probe'))
                row=(pid,100 if pid==101 else 40,pid,'/unavailable/exiting','R')
                with patch.object(s.watchdog,'rows',return_value=[row]), \
                     patch.object(s.watchdog,'identify_live_server',return_value=s.watchdog.UNVERIFIED), \
                     self.assertRaises(s.ProbeCleanupUnknown):
                    family.sample()
                self.assertEqual(child.polls,1 if initial is None and pid==100 else 0)

    def test_direct_reap_does_not_extend_readback_cutoff(self):
        class Child:
            pid=100
            returncode=None
            def poll(self):
                self.returncode=0
                return 0
        family=s.ProbeFamilyReadback(Child(),Path('/private/test/session-probe'))
        with patch.object(s.watchdog,'rows',return_value=[(100,40,100,'/unavailable/exiting','R')]), \
             patch.object(s.watchdog,'identify_live_server',return_value=s.watchdog.UNVERIFIED), \
             patch.object(s,'monotonic',side_effect=[0,5]), \
             self.assertRaisesRegex(s.ProbeCleanupUnknown,'cutoff'):
            family.sample(cutoff=4)

    def test_discovered_own_group_child_retained_after_parent_exit(self):
        child=type('Child',(),{'pid':100,'returncode':0})()
        family=s.ProbeFamilyReadback(child,Path('/private/test/session-probe'))
        parent=(100,40,100,'/private/test/session-probe','S')
        helper=(101,100,101,PYTHON_APP,'S')
        def identity(pid):
            row=parent if pid==100 else helper
            return dict(pid=pid,parent=row[1],group=row[2],path=row[3],start=[10,pid],state=2)
        with patch.object(s.watchdog,'rows',side_effect=[[parent,helper],[helper]]), \
             patch.object(s.watchdog,'identify_live_server',side_effect=identity):
            family.sample()
            with self.assertRaises(s.ProbeCleanupUnknown):family.finish(True)
        self.assertEqual(family.report['groups'],[100,101])
        self.assertEqual(family.report['remaining'],[helper])

    def test_abnormal_probe_exit_never_proves_unsampled_descendants_clean(self):
        child=type('Child',(),{'pid':100,'returncode':1})()
        family=s.ProbeFamilyReadback(child,Path('/private/test/session-probe'))
        with patch.object(s.watchdog,'rows',return_value=[]),self.assertRaises(s.ProbeCleanupUnknown): family.finish(False)
        self.assertTrue(family.report['unobservedDescendantsPossible'])

    def test_normal_exit_needs_empty_groups_and_fresh_absence(self):
        child=type('Child',(),{'pid':100,'returncode':0})()
        for absent in (False,True):
            family=s.ProbeFamilyReadback(child,Path('/private/test/session-probe'))
            with patch.object(s.watchdog,'rows',return_value=[]), \
                 patch.object(os,'kill',side_effect=ProcessLookupError() if absent else None):
                if absent: family.finish(True);self.assertTrue(family.report['observedFamilyEmpty'])
                else:
                    with self.assertRaises(s.ProbeCleanupUnknown): family.finish(True)

class CLIGuardReconciliation(unittest.TestCase):
    def run_case(self, descendant=False, expires=False):
        import prove_probe_family as proof
        class Child:
            pid=100
            returncode=None
            polls=0
            def poll(self):
                self.polls+=1
                if self.polls>1:self.returncode=64
                return self.returncode
            def wait(self,timeout):self.returncode=64;return 64
        child=Child()
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory).resolve();exe=out/'session-probe'
            identity=dict(pid=100,parent=os.getpid(),group=100,path=str(exe),start=[10,1],state=2)
            family=[dict(pid=100,parent=os.getpid(),group=100,observation='unknown')]
            if descendant:family.append(dict(pid=101,parent=100,group=101,observation='unknown'))
            times=iter([0,6,6,6]) if expires else None
            with patch.object(proof,'exact_instances',return_value=[]), \
                 patch.object(proof,'kernel_rows',return_value=[]), \
                 patch.object(proof,'full_family',return_value=family), \
                 patch.object(proof.subprocess,'Popen',return_value=child), \
                 patch.object(proof.w,'process_identity',return_value=identity), \
                 patch.object(proof.s,'monotonic',side_effect=(lambda:next(times)) if expires else lambda:0), \
                 patch.object(proof.time,'sleep'):
                if descendant or expires:
                    with self.assertRaises(RuntimeError if descendant else TimeoutError):
                        proof.run_guard(out,exe,['--native-check'],{}, {64},'controlled')
                else:proof.run_guard(out,exe,['--native-check'],{}, {64},'controlled')
            record=__import__('json').loads((out/'guard-controlled.json').read_text())
            self.assertEqual(record['finalReturncode'],64)
            self.assertTrue(record['reaped'])
            self.assertEqual(record['observations'][0][0]['observation'],'unknown')
            return record

    def test_unknown_owned_root_can_finish_with_fresh_wait_status(self):
        self.assertEqual(self.run_case()['exit'],64)

    def test_unknown_descendant_is_never_discarded(self):
        self.assertIn('descendant',self.run_case(descendant=True)['error'])

    def test_guard_reconciliation_keeps_original_deadline(self):
        self.assertIn('deadline',self.run_case(expires=True)['error'])

class FocusedAdvisory(unittest.TestCase):
    def identity(self, pid):
        return dict(pid=pid, parent=pid-1, group=pid, start=[1,pid], path='/owned', state=2)

    def test_recursive_cross_group_and_retained_parent_exit(self):
        import prove_probe_family as p
        family=p.AdvisoryFamily({100})
        def select(kind, value):
            return [value+1] if kind==6 and value<102 else []
        with patch.object(p,'selected_pids',side_effect=select), patch.object(p.w,'process_identity',side_effect=self.identity), \
             patch.object(p,'kernel_rows',side_effect=AssertionError('global scan')), \
             patch.object(os,'kill',side_effect=AssertionError('signal')), \
             patch.object(os,'killpg',side_effect=AssertionError('signal')), \
             patch.object(os,'waitpid',side_effect=AssertionError('reap')), \
             patch.object(p.s,'observe_processes',side_effect=AssertionError('acceptance')):
            rows=family.sample()
            self.assertEqual({r['pid'] for r in rows},{100,101,102})
            self.assertTrue(all(not r['signalAuthority'] and not r['acceptanceAuthority'] and not r['roleAuthority'] for r in rows))
        error=p.w.IdentityReadError('gone',None,'proc_pidinfo',0,3)
        with patch.object(p,'selected_pids',return_value=[]), patch.object(p.w,'process_identity',side_effect=lambda pid: self.identity(pid) if pid!=100 else (_ for _ in ()).throw(error)):
            rows=family.sample()
        self.assertEqual({r['pid'] for r in rows},{100,101,102})
        self.assertEqual(family.groups,{100,101,102})
        self.assertTrue(family.unknowns)

    def test_selector_abi_empty_denied_partial_saturated(self):
        import prove_probe_family as p
        from unittest.mock import Mock
        import ctypes
        for size, error, valid in [(0,0,True),(0,1,False),(-1,0,False),(3,0,False),(256,0,False),(260,0,False)]:
            lib=Mock(); lib.proc_listpids.return_value=size
            with self.subTest(size=size,error=error), patch.object(p.ctypes,'CDLL',return_value=lib), patch.object(p.ctypes,'get_errno',return_value=error):
                if valid:self.assertEqual(p.selected_pids(6,100),[])
                else:
                    with self.assertRaises(p.AdvisoryUnknown):p.selected_pids(6,100)
                self.assertEqual(lib.proc_listpids.argtypes,[ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_int])
                self.assertIs(lib.proc_listpids.restype,ctypes.c_int)

    def test_depth_member_query_and_time_caps(self):
        import prove_probe_family as p
        for cap,value in [('ADVISORY_DEPTH',1),('ADVISORY_MEMBERS',1),('ADVISORY_QUERIES',1),('ADVISORY_SECONDS',0)]:
            family=p.AdvisoryFamily({100})
            with self.subTest(cap=cap), patch.object(p,cap,value), patch.object(p.w,'process_identity',side_effect=self.identity), \
                 patch.object(p,'selected_pids',side_effect=lambda kind,v:[v+1] if kind==6 else []):
                with self.assertRaises(p.AdvisoryUnknown):family.sample()
            self.assertTrue(family.unknowns)

    def test_selector_failure_keeps_discovered_members(self):
        import prove_probe_family as p
        family=p.AdvisoryFamily({100})
        def select(kind, value):
            if value==101:raise p.AdvisoryUnknown('denied selector')
            return [101] if kind==6 else []
        with patch.object(p,'selected_pids',side_effect=select),patch.object(p.w,'process_identity',side_effect=self.identity):
            with self.assertRaises(p.AdvisoryUnknown):family.sample()
        self.assertEqual(set(family.depths),{100,101})
        self.assertEqual(family.groups,{100,101})
        self.assertTrue(family.unknowns)

    def test_only_fixed_positive_selectors_allowed(self):
        import prove_probe_family as p
        for kind,value in [(1,100),(6,0),(2,-1),(6,2**31),(6,True)]:
            with self.subTest(kind=kind,value=value),patch.object(p.ctypes,'CDLL',side_effect=AssertionError('must not call kernel')):
                with self.assertRaises(p.AdvisoryUnknown):p.selected_pids(kind,value)

    def test_partial_identity_is_explicit_unknown(self):
        import prove_probe_family as p
        family=p.AdvisoryFamily({100})
        error=p.w.IdentityReadError('partial',dict(pid=100,parent=9,group=100),'proc_pidpath',0,1)
        with patch.object(p,'selected_pids',return_value=[]),patch.object(p.w,'process_identity',side_effect=error):
            rows=family.sample()
        self.assertEqual(rows[0]['observation'],'unknown')
        self.assertEqual(rows[0]['errno'],1)
        self.assertFalse(rows[0]['acceptanceAuthority'])

if __name__ == '__main__': unittest.main()

class TargetRole(unittest.TestCase):
    """All readers and clocks are deterministic; no process is launched."""
    def run_role(self, name, callback, attached=True, mutate=None, legacy=False, binding_change=None,
                 target_change=None, unknown=False, expired=False, interrupted=False, read_change=None, device_change=None, stale_parent=False):
        build = Path('/private/mock/build')
        python = str(Path(sys.executable).resolve())
        def info(pid, parent, group, path):
            return dict(pid=pid, parent=parent, group=group, path=path, start=[10, pid], state=2)
        worker = info(40, 30, 40, python)
        original = info(50, 1, 50, '/launchd')
        target = dict(pid=200, start=[10, 200], path='/fixture', deviceID='device')
        server = info(100, 40, 40, str(SERVER))
        identities = {40:worker, 50:original, 100:server}
        if name == 'view-resident-product':
            identities[80] = info(80, 40, 40, str(build / 'session-probe'))
            identities[90] = info(90, 80, 40, python)
            server['parent'] = 90
        current = info(200, 100 if attached else 50, 200, '/fixture')
        identities[200] = current
        binding = dict(version=1, owner='11111111-1111-4111-8111-111111111111',
                       worker=s.watchdog.lifetime(worker), target=dict(target), group=200,
                       originalParent=s.watchdog.lifetime(original))
        if binding_change: binding_change(binding)
        if target_change: target_change(target)
        rows = [(i['pid'], i['parent'], i['group'], i['path'], 'S') for i in identities.values() if i['pid'] not in (40, 50)]
        if mutate: mutate(identities, rows)
        for row in rows:
            identities.setdefault(row[0], info(row[0], row[1], row[2], row[3]))
        now = [0.0]
        snapshots = [0]
        def snapshot(timeout):
            now[0] += .05
            snapshots[0] += 1
            if stale_parent and snapshots[0] == 1:
                return [(r[0], (50 if attached else 100) if r[0] == 200 else r[1], *r[2:]) for r in rows]
            return rows
        calls = {}
        def read(pid):
            calls[pid] = calls.get(pid, 0) + 1
            if unknown and pid == 200:
                now[0] += .3
                raise s.watchdog.IdentityReadError('denied', None, 'mock', -1, 1)
            value = dict(identities[pid])
            if read_change: read_change(pid, calls[pid], value)
            return value
        def device(pid, device=False):
            self.assertTrue(device)
            if expired: now[0] = 10
            if interrupted: raise InterruptedError('input')
            value = dict(identities[pid], deviceID='device', traced=attached)
            if device_change: device_change(value)
            return value
        details = {'targetObservationBinding':binding}
        with patch.object(s, 'monotonic', side_effect=lambda: now[0]), \
             patch.object(s.watchdog, 'rows', side_effect=snapshot), \
             patch.object(s.watchdog, 'process_identity', side_effect=read), \
             patch.object(s.watchdog, 'identify_live_server', side_effect=read), \
             patch.object(s.capture.ProcessProbe, 'identity', side_effect=device), \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(s.subprocess, 'Popen', side_effect=AssertionError('no launch')), \
             patch.object(os, 'kill', side_effect=AssertionError('no signal')), \
             patch.object(os, 'waitpid', side_effect=AssertionError('no reap')):
            if legacy:
                callback(rows, 40, target, build, SERVER, details)
            else:
                s.observe_processes(40, target, build, SERVER, details, 1, process_check=callback)
        self.assertGreaterEqual(calls[40], 2)
        self.assertTrue(any(e.get('status') == 'verifiedTargetRole' for e in details['residentExecutableObservations']))

    def test_attached_detached_and_legacy_correct_callback_topologies(self):
        for name, callback in callbacks():
            for attached in (False, True):
                for legacy in (False, True):
                    with self.subTest(name=name, attached=attached, legacy=legacy):
                        self.run_role(name, callback, attached, legacy=legacy)

    def test_target_identity_group_device_and_missing_binding_reject(self):
        for name, callback in callbacks():
            cases = [dict(target_change=lambda t: t.update(start=[99, 0])),
                     dict(target_change=lambda t: t.update(path='/wrong')),
                     dict(target_change=lambda t: t.update(deviceID='wrong')),
                     dict(mutate=lambda i,r: i[200].update(group=999)),
                     dict(binding_change=lambda b: b.clear())]
            for case in cases:
                with self.subTest(name=name, case=case), self.assertRaises((RuntimeError, ValueError)):
                    self.run_role(name, callback, **case)

    def test_parent_reuse_wrong_debugger_unknown_and_descendants_reject(self):
        for name, callback in callbacks():
            for attached, change in [(True, lambda i,r: i[100].update(path='/wrong')),
                                     (False, lambda i,r: i[50].update(start=[99, 0])),
                                     (False, lambda i,r: i[50].update(path='/wrong')),
                                     (True, lambda i,r: i[40].update(start=[99, 0])),
                                     (True, lambda i,r: r.append((201, 200, 200, '/unexpected', 'S'))),
                                     (False, lambda i,r: r.append((201, 200, 999, '/unexpected', 'S'))),
                                     (False, lambda i,r: r.append((201, 1, 200, '/unexpected', 'S'))),
                                     (True, lambda i,r: r.append((202, 1, 202, '/fixture', 'S')))]:
                with self.subTest(name=name, attached=attached), self.assertRaises(RuntimeError):
                    self.run_role(name, callback, attached, mutate=change)

    def test_denied_cutoff_and_input_never_accept(self):
        name, callback = next(callbacks())
        for case in (dict(unknown=True), dict(expired=True), dict(interrupted=True)):
            with self.subTest(case=case), self.assertRaises((TimeoutError, InterruptedError)):
                self.run_role(name, callback, **case)

    def test_fresh_debugger_original_parent_and_target_brackets_reject_reuse(self):
        for name, callback in callbacks():
            for attached, pid, key, value in [(True,100,'start',[99,0]), (True,100,'path','/wrong'),
                                             (True,100,'parent',999), (True,100,'group',999),
                                             (False,50,'start',[99,0]), (False,50,'path','/wrong'),
                                             (True,200,'start',[99,0]), (True,200,'parent',50)]:
                def change(read_pid, count, info):
                    if read_pid == pid and count >= 2: info[key]=value
                with self.subTest(name=name,pid=pid,key=key), self.assertRaises(RuntimeError):
                    self.run_role(name,callback,attached,read_change=change)

    def test_incoherent_attach_detach_unknown_parent_and_state_reject(self):
        for name, callback in callbacks():
            for attached, change in [(True,lambda v:v.update(traced=False)),
                                     (False,lambda v:v.update(traced=True)),
                                     (True,lambda v:v.update(parent=999)),
                                     (False,lambda v:v.update(state=4)),
                                     (True,lambda v:v.pop('traced'))]:
                with self.subTest(name=name,attached=attached), self.assertRaises(RuntimeError):
                    self.run_role(name,callback,attached,device_change=change)

    def test_attach_detach_snapshot_order_reconciles_under_original_cutoff(self):
        for name,callback in callbacks():
            for attached in (False,True):
                with self.subTest(name=name,attached=attached):
                    self.run_role(name,callback,attached,stale_parent=True)
