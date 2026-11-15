"""Headless synthetic native identities; never execute tools or target engines."""
from dataclasses import replace
import hashlib
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'view-hierarchy-prototype'))
import ui_tool_contract as c
import test_canonical_call_trace as trace


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.config = c.Configuration(c.DEVELOPER, tuple((p, 'fixture') for p in c.required_paths()))
        self.parent = c.Identity(10, (1, 0), 1, 10, '/owned/UI')
        self.origin = self.make_origin(('/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'))

    def make_origin(self, argv, pid=20, lane='capture'):
        return c.Origin(c.Identity(pid, (2, pid), 10, 20, argv[0]), self.parent, tuple(argv), 'validated-fixture-artifact', lane, True)

    def root(self, origin=None, phase=1):
        origin = origin or self.origin
        state = c.root_states(c.origin_tool(origin), origin.argv)[phase]
        return c.Observation(replace(origin.identity, path=state[0]), state[1], (), True)

    def child(self, path, argv, ancestors=None, pid=30):
        ancestors = ancestors or (self.root(),)
        return c.Observation(c.Identity(pid, (3, pid), ancestors[0].identity.pid, 20, path), tuple(argv), ancestors, True)

    def assertRejected(self, reason, origin, row, prior=None):
        with self.assertRaisesRegex(c.Rejected, reason): c.match(self.config, origin, row, prior)

    def test_actual_production_traces_all_four_operations(self):
        for kind in ('capture', 'edit', 'revert', 'release'):
            with tempfile.TemporaryDirectory() as d:
                result = trace.record_canonical_calls(Path(d).resolve(), kind)
                for event in result['events']:
                    if event['api'] != 'check_output': continue
                    origin = self.make_origin(event['argv'])
                    previous = None
                    for phase in range(len(c.root_states(c.origin_tool(origin), origin.argv))):
                        row = self.root(origin, phase)
                        previous = c.match(self.config, origin, row, previous)
                        self.assertEqual(previous.role, 'origin')

    def test_simctl_source_children(self):
        root = self.root()
        sub = self.child(root.identity.path, root.argv)
        nested = self.child(root.identity.path, root.argv, (sub, root), 31)
        for row in (sub, nested):
            self.assertEqual(c.match(self.config, self.origin, row).role, 'shell-child')
        for path, argv, role in (
            ('/usr/libexec/PlistBuddy', ('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', c.resources('simctl')+'/Info.plist'), 'plist'),
            ('/usr/bin/sort', ('sort', '--version-sort'), 'sort'),
            ('/usr/bin/head', ('head', '-n1'), 'head')):
            for ancestors in ((root,), (sub, root)):
                row = self.child(path, argv, ancestors, 32)
                self.assertEqual(c.match(self.config, self.origin, row).role, role)

    def display(self, pid=20, lane='display-passive'):
        return self.make_origin(('/usr/bin/xcrun','devicectl','device','info','displays','--device','fixture-device','--quiet','--json-output','/owned/output.json'), pid, lane)

    def test_display_forward_and_plist(self):
        origin = self.display(); prior = None
        for phase in range(3):
            prior = c.match(self.config, origin, self.root(origin, phase), prior)
        root = self.root(origin)
        row = self.child('/usr/libexec/PlistBuddy', ('/usr/libexec/PlistBuddy','-c','Print :CFBundleVersion', c.resources('devicectl')+'/Info.plist'), (root,))
        self.assertEqual(c.match(self.config, origin, row).role, 'plist')

    def test_mutations_and_unvalidated_origins(self):
        for argv in (('/usr/bin/xcodebuild','-runFirstLaunch'),('/usr/bin/xcrun','simctl','boot','device'),('/usr/bin/xcrun','devicectl','device','orientation','set'),('/usr/bin/codesign','--sign','-', '/app')):
            origin = self.make_origin(argv)
            self.assertRejected('unsupported-origin', origin, self.root(self.origin))
        self.assertRejected('unvalidated-origin', replace(self.origin, provenance=''), self.root())
        self.assertRejected('unvalidated-origin', replace(self.origin, edges_verified=False), self.root())

    def test_identity_ancestry_argv_rejections(self):
        root = self.root()
        child = self.child(root.identity.path, root.argv)
        cases = [
            ('wrong-group', replace(child, identity=replace(child.identity, group=99))),
            ('unverified-parent', replace(child, edges_verified=False)),
            ('wrong-parent', replace(child, identity=replace(child.identity, parent=99))),
            ('wrapper-depth', replace(child, ancestors=())),
            ('wrong-origin', replace(child, ancestors=(replace(root, identity=replace(root.identity,pid=99)),))),
            ('unknown-wrapper', replace(child, argv=('/bin/bash','-c','true'))),
            ('unknown-wrapper', replace(child, identity=replace(child.identity,path='/tmp/bash'))),
            ('unknown-wrapper', replace(child, argv=('/bin/bash','/wrong/script'))),
            ('unknown-wrapper', self.child('/usr/bin/unknown', ('unknown',))),
            ('unknown-wrapper', self.child('/usr/libexec/PlistBuddy', ('/usr/libexec/PlistBuddy','-c','Print :CFBundleVersion','/wrong/plist'))),
            ('unknown-wrapper', self.child(c.resources('simctl')+'/bin/simctl', (c.resources('simctl')+'/bin/simctl',)+self.origin.argv[2:])),
            ('parent-not-wrapper', replace(child, ancestors=(self.root(phase=2),))),
        ]
        for reason, row in cases:
            with self.subTest(reason=reason): self.assertRejected(reason, self.origin, row)

    def test_reverse_exec_and_mixed_xcodebuild_read(self):
        final = c.match(self.config, self.origin, self.root(phase=2))
        self.assertRejected('reverse', self.origin, self.root(), final)
        x = self.make_origin(('/usr/bin/xcodebuild','-version'))
        mixed = replace(self.root(x, 0), argv=(c.wrapper('xcodebuild'),'-version'))
        self.assertRejected('unsupported-root', x, mixed)
        self.assertRejected('unsupported-root', x, replace(self.root(x,1),argv=('xcodebuild','-version')))

    def test_aggregate_aliases_missing_root_and_counts(self):
        root=self.root(); sub=self.child(root.identity.path,root.argv)
        rows=[(self.origin, self.child(root.identity.path,root.argv,pid=p),None) for p in (30,31,32)]
        with self.assertRaisesRegex(c.Rejected,'too-many-shell-child'):
            c.validate_snapshot(self.config,[self.origin],rows)
        d1=self.display(); d2=self.display(21,'display-synchronous')
        c.validate_snapshot(self.config,[d1,d2],[(d1,self.root(d1,0),None),(d2,self.root(d2,2),None)])
        with self.assertRaisesRegex(c.Rejected,'display-concurrency'):
            c.validate_snapshot(self.config,[d1,d2,self.display(22)],[])
        c.validate_snapshot(self.config,[d1,self.display(21)],[])
        with self.assertRaisesRegex(c.Rejected,'duplicate-native'):
            c.validate_snapshot(self.config,[self.origin],[(self.origin,root,None),(self.origin,self.root(phase=2),None)])
        # Five processes: root reservation, comparison shell, builtin printf shell, sort, head.
        rows=[(self.origin,sub,None),(self.origin,self.child(root.identity.path,root.argv,(sub,root),31),None),
              (self.origin,self.child('/usr/bin/sort',('sort','--version-sort'),(sub,root),32),None),
              (self.origin,self.child('/usr/bin/head',('head','-n1'),(sub,root),33),None)]
        c.validate_snapshot(self.config,[self.origin],rows)
        rows.append((self.origin,self.child('/usr/libexec/PlistBuddy',('/usr/libexec/PlistBuddy','-c','Print :CFBundleVersion',c.resources('simctl')+'/Info.plist'),pid=34),None))
        with self.assertRaisesRegex(c.Rejected,'too-many-total'): c.validate_snapshot(self.config,[self.origin],rows)

    def test_display_budget_does_not_invent_calling_lane_identity(self):
        # Native argv/ancestry identifies the UI and exact read, not the Swift queue.
        displays = [self.display(pid, 'display') for pid in (20, 21)]
        c.validate_snapshot(self.config, displays, [(d, self.root(d, 2), None) for d in displays])
        with self.assertRaisesRegex(c.Rejected, 'display-concurrency'):
            c.validate_snapshot(self.config, displays + [self.display(22, 'display')], [])

    def test_child_terminal_exec_is_bound_and_forward_only(self):
        root = self.root()
        sub = self.child(root.identity.path, root.argv)
        prior = c.match(self.config, self.origin, sub)
        terminal = replace(sub, identity=replace(sub.identity, path='/usr/bin/sort'), argv=('sort','--version-sort'))
        final = c.match(self.config, self.origin, terminal, prior)
        self.assertIn((terminal.identity.path, terminal.argv), prior.forward_chain)
        self.assertRejected('reverse', self.origin, sub, final)
        self.assertRejected('changed-native', self.origin, replace(terminal,identity=replace(terminal.identity,start=(9,9))), prior)
        self.assertRejected('reverse', self.origin, replace(terminal,identity=replace(terminal.identity,path='/usr/bin/head'),argv=('head','-n1')), final)

    def test_sdk_has_no_wrapper_children(self):
        origin=self.make_origin(('/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'))
        row=self.child('/bin/bash',('/bin/bash',c.wrapper('simctl')), (self.root(origin,0),))
        self.assertRejected('unexpected-tool-child',origin,row)

    def test_configuration_pins_and_versions(self):
        data={p:b'fixture' for p in c.required_paths()}
        for tool in c.WRAPPERS:
            data[c.resources(tool)+'/Info.plist']=plistlib.dumps({'CFBundleVersion':c.WRAPPERS[tool][2]})
        hashes={p:hashlib.sha256(v).hexdigest() for p,v in data.items()}
        wrappers={tool:values[:3]+(hashes[c.wrapper(tool)],) for tool,values in c.WRAPPERS.items()}
        with patch.object(c,'SOURCE_PINS',{r:hashes[str(c.SOURCE_ROOT/r)] for r in c.SOURCE_PINS}), patch.object(c,'WRAPPERS',wrappers), patch.object(Path,'read_bytes',lambda p:data[str(p)]):
            c.Configuration.read(c.DEVELOPER,hashes)
            with self.assertRaisesRegex(c.Rejected,'unsupported-developer'): c.Configuration.read('/wrong',hashes)
            with self.assertRaisesRegex(c.Rejected,'incomplete-configured'): c.Configuration.read(c.DEVELOPER,{})
            bad=dict(hashes);bad['/bin/bash']='wrong'
            with self.assertRaisesRegex(c.Rejected,'configuration-hash'): c.Configuration.read(c.DEVELOPER,bad)
            changed=dict(hashes); changed[c.wrapper('simctl')]=hashlib.sha256(b'changed').hexdigest()
            before=data[c.wrapper('simctl')]; data[c.wrapper('simctl')]=b'changed'
            with self.assertRaisesRegex(c.Rejected,'unsupported-wrapper'): c.Configuration.read(c.DEVELOPER,changed)
            data[c.wrapper('simctl')]=before
            data[c.resources('simctl')+'/Info.plist']=plistlib.dumps({'CFBundleVersion':'999'})
            hashes[c.resources('simctl')+'/Info.plist']=hashlib.sha256(data[c.resources('simctl')+'/Info.plist']).hexdigest()
            with self.assertRaisesRegex(c.Rejected,'framework-version'): c.Configuration.read(c.DEVELOPER,hashes)

if __name__ == '__main__': unittest.main()
