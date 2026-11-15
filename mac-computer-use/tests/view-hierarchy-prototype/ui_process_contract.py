"""Join the isolated UI's native inventory to prepared resources and operations.

Candidate topology is not command authority. Only validate() admits a complete
native/argv snapshot. This module never launches, signals, attaches or edits.
"""
import json
import errno
from pathlib import Path
import plistlib
import re
import time
import uuid

import ui_capture_contract as artifacts
import ui_tool_contract as tools
import ui_recording_contract as recording


class Rejected(ValueError):
    pass


class Unstable(RuntimeError):
    """Retry the observation under its original cutoff."""


def require(ok, message):
    if not ok:
        raise Rejected(message)


def native(info):
    return tools.Identity(info['pid'], tuple(info['start']), info['parent'], info['group'], info['path'])


class Contract:
    def __init__(self, specification, python, server, target, target_binding, check, cursor=None):
        self.spec = specification
        self.python = tuple(python)
        self.server = server
        self.target, self.target_binding = target, target_binding
        self.check = check
        self.cursor = cursor
        self.paths = set(tools.required_paths()) | set(self.python) | {server, '/usr/sbin/screencapture'}
        self.paths -= {tools.wrapper('simctl'), tools.wrapper('devicectl')}
        self.histories = {}
        self.matches = {}
        self.operation_bindings = {}
        self.last_pid = None
        self.identities = {}
        self.ledger_root = Path.home() / 'Library/Application Support/mac-cu/view-edit-ledger'

    def candidates(self, members, root, pending=()):
        """Bound paths/ancestry early; argv/artifact checks remain mandatory."""
        bypid = {row[0]: row for row in members}
        direct = {'/usr/bin/xcrun', '/bin/zsh', tools.resources('devicectl') + '/bin/devicectl',
                  '/usr/sbin/screencapture', *self.python}
        result = {}
        for row in members:
            if row[0] == root[0] or (self.target and row[0] == self.target['pid']):
                continue
            ancestry, current = [], row
            while current[1] != root[0]:
                if current[1] not in bypid:
                    break
                current = bypid[current[1]]
                require(current[0] not in {r[0] for r in ancestry} and len(ancestry) < 4,
                        'UI ancestry cycle or depth exceeded')
                ancestry.append(current)
            if current[1] != root[0]:
                if current[1] in pending and row[3] in self.paths:
                    result[row[0]] = 'candidate'
                    continue  # Partial observation only; final membership is strict.
                require(row[2] == root[2], 'unknown UI family group/parent')
                continue  # Existing worker utility callback owns this row.
            self.last_pid = row[0]
            require(current[2] == current[0], 'Foundation UI helper group differs')
            require(row[2] == current[2], 'UI descendant group differs')
            require(row[3] in (direct if not ancestry else self.paths),
                    'unknown UI child executable' if not ancestry else 'unknown UI descendant')
            result[row[0]] = 'candidate'
        # 6 display-family + identity + supervisor + worker + debugger +
        # screenshot + 5 capture-utility-family identities; UI itself is excluded.
        require(len(result) <= 16, 'UI aggregate candidate budget exceeded')
        return result

    def allow_exec(self, pid, previous, current):
        if any(key in current and current[key] != previous.get(key) for key in ('pid', 'start', 'parent', 'group')):
            return False
        old, new = previous.get('path'), current.get('path')
        if not self.forward_paths(old, new):
            return False
        history = self.histories.setdefault(pid, [old])
        if history[-1] != new:
            history.append(new)
        return True  # Candidate only; validate() must join the semantic role.

    def forward_paths(self, old, new):
        chains = [('/usr/bin/xcrun', p) for p in self.python]
        chains += [tuple(state[0] for state in tools.root_states(tool, ('/usr/bin/xcrun', tool)))
                   for tool in tools.WRAPPERS]
        chains += [('/usr/bin/xcodebuild', tools.wrapper('xcodebuild'))]
        chains += [(shell, helper) for shell in ('/bin/bash', '/bin/zsh')
                   for helper in ('/usr/libexec/PlistBuddy', '/usr/bin/sort', '/usr/bin/head')]
        return any(old in chain and new in chain and chain.index(old) < chain.index(new) for chain in chains)

    def gone(self, pid):
        self.histories.pop(pid, None)
        self.matches.pop(pid, None)
        self.operation_bindings.pop(pid, None)

    def read(self, pid):
        if pid in self.live:
            return self.live[pid]
        self.last_pid = pid
        self.check()
        before = self.read_identity(pid)
        argv = tuple(self.read_arguments(pid))
        after = self.read_identity(pid)
        require(all(before.get(k) == after.get(k) for k in ('pid', 'start', 'parent', 'group')),
                'native identity changed across argv')
        if before['path'] != after['path']:
            raise Unstable('exec crossed argv read')
        expected = self.rows.get(pid)
        require(expected is not None and (after['parent'], after['group']) == expected[1:3],
                'native parent/group missing from inventory')
        # The path may have advanced since the initial inventory; native identity
        # and the exact final argv must still match an explicit semantic state.
        self.live[pid] = (after, argv)
        self.identities[pid] = after
        self.check()
        return self.live[pid]

    def owned_fixture(self):
        if self.fixture is not None:
            return self.fixture
        require(self.target is not None and self.target_binding is not None, 'UI target binding missing')
        pins = []
        value = artifacts.read_json(Path(self.spec['output']) / 'ui-request.json', pins)
        initial = self.cursor.original['target'] if self.cursor else self.target
        require(all(value.get(k) == v for k, v in initial.items()) and
                value.get('fixtureSession') == self.target_binding['owner'] and
                value.get('output') == self.spec['output'], 'UI request owner/target differs')
        app = Path(self.target['path']).parent
        data = artifacts.absolute(value['documents']).parent
        prefix = '/data/Containers/Bundle/Application/'
        require(prefix in str(app), 'UI app container scope')
        device = str(app).split(prefix, 1)[0]
        require(Path(device).name == self.spec['device'] and
                data.parent == Path(device) / 'data/Containers/Data/Application' and
                Path(value['documents']).name == 'Documents', 'UI data/device container scope')
        uuid.UUID(data.name)
        raw, pin = artifacts.read_file(app / 'Info.plist', private=False); pins.append(pin)
        info = plistlib.loads(raw)
        require(info['CFBundleExecutable'] == Path(self.target['path']).name, 'UI fixture executable differs')
        raw, pin = artifacts.read_file(data / '.com.apple.mobile_container_manager.metadata.plist', private=False)
        pins.append(pin)
        require(plistlib.loads(raw).get('MCMMetadataIdentifier') == info['CFBundleIdentifier'],
                'UI data container bundle differs')
        self.fixture = (str(app), str(data), info['CFBundleIdentifier'])
        self.file_pins.extend(pins)
        return self.fixture

    def preparation(self, pid):
        require(self.cursor is not None, 'recording lane is not owner bound')
        info, argv = self.read(pid)
        require(info['parent'] == self.root and info['group'] == pid, 'preparation parent/group differs')
        argv = self.python_argv(info, argv)
        app, data, bundle = self.owned_fixture()
        binding = recording.bind_preparation(argv, prepared=self.prepared(argv[0]),
            original=self.cursor.original['target'], expected_scope=self.cursor.scope,
            supervisor=info, ledger_root=self.ledger_root, temporary=self.spec['temporary'],
            app=app, data=data, bundle=bundle)
        if self.cursor.preparation is None:
            old = self.read_identity(self.cursor.original['target']['pid'])
            require(all(old[k] == v for k,v in self.cursor.original['target'].items() if k != 'deviceID') and
                    old['state'] in (2,3), 'preparation first observation requires live original')
        self.cursor.bind(binding, self.read(self.root)[0])
        self.roles[pid] = 'preparation-supervisor'
        return binding

    @artifacts.checked
    def operation_state(self, request):
        """Current durable reservation is independent of request/wire files."""
        path = self.ledger_root / (artifacts.digest(artifacts.canonical(self.target).encode()) + '.json')
        try:
            state = artifacts.read_json(path, [], limit=32 * 1024 * 1024)
        except artifacts.ContractError as error:
            if str(error) == 'file changed during read':
                raise Unstable('UI ledger changed during read') from error
            if isinstance(error.__cause__, OSError) and error.__cause__.errno == errno.ENOENT:
                raise Unstable('UI supervisor has not published its reservation') from error
            raise
        require(isinstance(state, dict) and isinstance(state.get('operations'), dict), 'UI ledger shape differs')
        operation = state['operations'].get(request['operationID'])
        if operation is None and (state.get('highWater', 0) < request['sequence'] or
                                  (state.get('authority') == 'released' and request['sequence'] == 1)):
            raise Unstable('UI reservation has not appeared')
        require(state.get('schema') == 2 and state.get('lifecycleVersion') == 1 and state.get('target') == self.target and
                state.get('ownerID') == request['ownerID'] and state.get('inspectionID') == request['inspectionID'] and
                state.get('highWater') == request['sequence'] and isinstance(operation, dict) and
                operation.get('kind') == request['kind'] and operation.get('sequence') == request['sequence'] and
                operation.get('digest') == artifacts.digest(artifacts.canonical(request).encode()) and
                operation.get('state') in ('reserved','finished'), 'UI active operation ledger differs')
        require(request['targetEpoch'] is None or request['targetEpoch'] == state.get('epoch'), 'UI operation epoch differs')
        if operation['state'] == 'reserved' and 'wireDigest' not in operation:
            raise Unstable('UI final wire binding has not appeared')
        require(operation['state'] == 'finished' or re.fullmatch('[0-9a-f]{64}', operation['wireDigest']),
                'UI durable wire digest is invalid')
        return operation

    def transport_operation(self, capture):
        request = json.loads(capture.request_json)
        operation = self.operation_state(request)
        require(operation['state'] == 'reserved', 'completed UI operation cannot re-enter transport')
        return operation

    def prepared(self, python):
        if python not in self.prepared_by_python:
            resource = Path(self.spec['capture']).parent
            pins = []
            build = artifacts.read_json(resource / 'resident-build.json', pins, private=False)
            framework = Path(build['developer']).parent / 'SharedFrameworks/LLDB.framework'
            selected = dict(server=str((framework / 'Resources/debugserver').resolve()),
                            python=str(framework / 'Resources/Python'),
                            lldb=str((framework / 'LLDB').resolve()), sdk=build['sdk'])
            require(selected['server'] == self.server, 'prepared debugserver differs')
            self.prepared_by_python[python] = artifacts.prepare(capture_resource=resource, resident_resource=resource,
                python=python, resource_hashes=self.spec['resourcePins'], build=build, selected_tools=selected)
        return self.prepared_by_python[python]

    def python_argv(self, info, argv):
        if info['path'] == '/usr/bin/xcrun':
            require(argv[:2] == ('/usr/bin/xcrun', 'python3'), 'UI Python launcher differs')
            return (self.python[-1],) + argv[2:]
        require(info['path'] in self.python and argv[0] in self.python, 'UI Python identity/argv differs')
        return argv

    def capture(self, pid):
        if pid in self.captures:
            return self.captures[pid]
        info, argv = self.read(pid)
        require(info['parent'] == self.root and info['group'] == pid, 'supervisor parent/group differs')
        argv = self.python_argv(info, argv)
        require(len(argv) == 5 and argv[1:4] == ('-I', self.spec['capture'], '--capture'),
                'capture supervisor argv differs')
        app, data, bundle = self.owned_fixture()
        request = artifacts.read_json(Path(argv[-1]), [])
        operation = self.operation_state(request)
        self.last_pid = pid
        binding = artifacts.bind_capture(argv, prepared=self.prepared(argv[0]), target=self.target,
            expected_request=request, owned_app=app, owned_data=data, bundle_id=bundle,
            ui_temporary_root=self.spec['temporary'], supervisor=info)
        prior = self.operation_bindings.get(pid)
        require(prior is None or (all(json.loads(prior.supervisor_json)[k] == json.loads(binding.supervisor_json)[k]
                for k in ('pid','start','parent','group')) and prior.folder == binding.folder and
                prior.request_json == binding.request_json), 'supervisor operation binding changed')
        if prior is not None:
            artifacts.revalidate(prior)
        self.operation_bindings[pid] = binding
        self.captures[pid] = binding
        self.operation_states[pid] = operation
        self.roles[pid] = 'capture-supervisor'
        return binding

    def worker(self, pid):
        if pid in self.workers:
            return self.workers[pid]
        info, argv = self.read(pid)
        capture = self.capture(info['parent'])
        operation = self.transport_operation(capture)
        supervisor, _ = self.read(info['parent'])
        require(info['group'] == supervisor['group'], 'resident worker group differs')
        argv = self.python_argv(info, argv)
        require(len(argv) == 6 and argv[1:4] == ('-I',str(Path(self.spec['capture']).parent/'resident_transport.py'),'--worker'),
                'worker argv mismatch')
        folder = Path(capture.folder)
        config = artifacts.read_json(Path(argv[4]) / 'worker.json', [])
        server, server_argv = self.read(config['server']['pid'])
        require(server['group'] == supervisor['group'] and server['parent'] == supervisor['pid'] and
                server['path'] == self.server and len(server_argv) == 3 and
                server_argv[:2] == (self.server, '--fd') and re.fullmatch(r'[1-9][0-9]{0,9}', server_argv[2]),
                'debugserver native parent/group/argv differs')
        self.last_pid = pid
        wire = artifacts.read_json(folder / 'wire.json', [])
        require(operation.get('wireDigest') == artifacts.digest(artifacts.canonical(wire).encode()),
                'UI wire differs from durable final binding')
        binding = artifacts.bind_worker(argv, capture=capture, observed_supervisor=supervisor,
            observed_parent=supervisor, expected_server=server,
            current_request=artifacts.read_json(folder / 'request.json', []),
            expected_wire=wire, now=time.monotonic())
        self.workers[pid] = binding
        self.roles[pid], self.roles[server['pid']] = 'capture-worker', 'debugserver'
        return binding

    def tool(self, pid, commands, provenance, lane, parent):
        info, argv = self.read(pid)
        self.last_pid = pid
        candidates = []
        for command in commands:
            origin = tools.Origin(native(info), native(parent), tuple(command), provenance, lane, True)
            try:
                matched = tools.match(self.configuration, origin, tools.Observation(native(info), argv, (), True),
                                      self.matches.get(pid))
                candidates.append((origin, matched))
            except tools.Rejected:
                pass
        if not candidates:
            for command in commands:
                origin = tools.Origin(native(info), native(parent), tuple(command), provenance, lane, True)
                for path, args in tools.root_states(tools.origin_tool(origin), origin.argv):
                    if args == argv and path != info['path'] and self.forward_paths(info['path'], path):
                        raise Unstable('tool path/argv straddles exec')
        require(len(candidates) == 1, 'UI utility origin argv differs')
        origin, matched = candidates[0]
        observation = tools.Observation(native(info), argv, (), True)
        self.origins[pid] = origin
        self.tool_rows[pid] = (origin, observation, self.matches.get(pid))
        self.roles[pid] = 'display' if lane == 'display' else 'capture-utility'
        if lane == 'recording': self.cursor.tool(origin.argv, info)
        return origin, observation

    def role(self, pid):
        if pid in self.roles:
            return self.roles[pid]
        info, argv = self.read(pid)
        parent, _ = self.read(info['parent'])
        self.last_pid = pid
        if parent['pid'] == self.root:
            if info['path'] == '/usr/sbin/screencapture':
                labels = {'inspector-open','swiftui-selected','swiftui-branch','hidden-readback','alpha-readback',
                          'lcd-normal','inspector-normal','lcd-minimum','inspector-minimum','inspector-minimum-editor',
                          'receipt-summary','receipt-cleared'}
                require(len(argv) == 6 and argv[:4] == ('/usr/sbin/screencapture','-x','-o','-l') and
                        argv[4].isdigit() and int(argv[4]) > 0 and
                        Path(argv[5]).parent == Path(self.spec['output']) and Path(argv[5]).name in {s+'.png' for s in labels},
                        'UI screenshot argv differs')
                self.roles[pid] = 'screenshot'
            elif info['path'] in self.python or (info['path'] == '/usr/bin/xcrun' and argv[1:2] == ('python3',)):
                python_args = self.python_argv(info, argv)
                if python_args[1:4] == ('-I', self.spec['capture'], '--identity'):
                    identities = [self.target] if self.target is not None else []
                    if self.cursor and self.cursor.candidate: identities.append(self.cursor.candidate['target'])
                    require(any(python_args[4:] == (str(target['pid']), self.spec['device']) for target in identities),
                            'UI identity target differs')
                    self.prepared(python_args[0]); self.roles[pid] = 'identity'
                elif python_args[1:4] == ('-I', self.spec['capture'], '--prepare-recording'):
                    self.preparation(pid)
                else:
                    require(self.cursor is None or self.cursor.phase in ('original','admitted'), 'capture during recording custody')
                    self.capture(pid)
            else:
                # Recover semantic origin from each exact supported wrapper state.
                tail = argv[2:] if info['path'] in ('/usr/bin/xcrun', '/bin/zsh') else argv[1:]
                require(len(tail) == 8 and tail[:5] == ('device','info','displays','--device', self.spec['device']) and
                        tail[5:7] == ('--quiet','--json-output'), 'UI display argv differs')
                output = artifacts.absolute(tail[-1])
                prefix = 'mac-cu-displays-' + self.spec['device'] + '-'
                require(output.parent == Path(self.spec['temporary']) and output.name.startswith(prefix) and
                        output.suffix == '.json', 'UI display output differs')
                uuid.UUID(output.name[len(prefix):-5])
                self.tool(pid, [('/usr/bin/xcrun','devicectl') + tail], 'display:' + str(output), 'display', parent)
        else:
            parent_role = self.role(parent['pid'])
            self.last_pid = pid
            if parent_role == 'preparation-supervisor':
                require(info['path'] not in (*self.python, self.server), 'preparation worker/debugger refused')
                self.tool(pid, self.cursor.commands(), self.cursor.preparation.request_json, 'recording', parent)
            elif parent_role == 'capture-supervisor':
                self.transport_operation(self.capture(parent['pid']))
                if info['path'] in self.python:
                    self.worker(pid)
                elif info['path'] == self.server:
                    require(len(argv) == 3 and argv[:2] == (self.server,'--fd') and
                            re.fullmatch(r'[1-9][0-9]{0,9}',argv[2]), 'debugserver argv differs')
                    self.roles[pid] = 'debugserver'
                else:
                    capture = self.capture(parent['pid'])
                    self.tool(pid, capture.commands('supervisor'), capture.request_json, 'capture', parent)
            elif parent_role == 'capture-worker':
                worker = self.worker(parent['pid'])
                self.tool(pid, worker.commands(), worker.capture.request_json, 'capture', parent)
            else:
                require(parent['pid'] in self.tool_rows, 'unknown UI semantic descendant')
                origin, parent_row, _ = self.tool_rows[parent['pid']]
                row = tools.Observation(native(info), argv, (parent_row,) + parent_row.ancestors, True)
                tools.match(self.configuration, origin, row, self.matches.get(pid))
                self.tool_rows[pid] = (origin, row, self.matches.get(pid))
                self.roles[pid] = 'wrapper-child'
        return self.roles[pid]

    def validate(self, snapshot, root, candidates, read_identity, read_arguments):
        self.check()
        self.configuration = tools.Configuration.read(tools.DEVELOPER, self.spec['toolHashes'])
        self.rows = {r[0]: r for r in snapshot}
        self.root = root
        self.read_identity, self.read_arguments = read_identity, read_arguments
        self.live, self.roles, self.captures, self.workers = {}, {}, {}, {}
        self.operation_states = {}
        self.origins, self.tool_rows, self.prepared_by_python = {}, {}, {}
        self.fixture, self.file_pins = None, []
        root_info, root_argv = self.read(root)
        require(root_argv == (self.spec['binary'], '--native-check'), 'UI root argv differs')
        raw, _ = artifacts.read_file(self.spec['binary'], limit=artifacts.IMAGE_LIMIT, private=False)
        require(artifacts.digest(raw) == self.spec['binarySHA256'], 'UI executable pin changed')
        for pid in sorted(candidates):
            self.role(pid)
        limits = dict(display=2, identity=1, **{'capture-supervisor':1, 'capture-worker':1,
                      'preparation-supervisor':1, 'debugserver':1, 'screenshot':1, 'capture-utility':1})
        for role, limit in limits.items():
            require(sum(v == role for v in self.roles.values()) <= limit, 'UI exact helper role budget exceeded: ' + role)
        require(sum(v in ('capture-supervisor','preparation-supervisor') for v in self.roles.values()) <= 1,
                'shared capture/preparation supervisor slot exceeded')
        if 'preparation-supervisor' in self.roles.values():
            require(not any(v in ('capture-worker','debugserver') for v in self.roles.values()), 'preparation transport overlap')
        rows = list(self.tool_rows.items())
        display_outputs = [origin.provenance for origin in self.origins.values() if origin.lane == 'display']
        require(len(display_outputs) == len(set(display_outputs)), 'display output invocation reused')
        results = tools.validate_snapshot(self.configuration, list(self.origins.values()), [v for _,v in rows])
        for (pid, _), result in zip(rows, results):
            self.matches[pid] = result
        for pid, paths in self.histories.items():
            if pid not in self.roles:
                continue  # Only caller's native exit reconciliation can remove it.
            if pid in self.tool_rows:
                origin, row, _ = self.tool_rows[pid]
                tool = tools.origin_tool(origin)
                chain = [state[0] for state in tools.root_states(tool, origin.argv)] if pid in self.origins else [tools.WRAPPERS[tool][0], row.identity.path]
            else:
                chain = ['/usr/bin/xcrun', self.live[pid][0]['path']]
            require(all(path in chain for path in paths) and all(chain.index(a) < chain.index(b) for a,b in zip(paths,paths[1:])),
                    'observed exec history differs from semantic role')
        # Re-read native parents after all descendant argv/artifact joins. This
        # also covers PID orders where children sort before their parents.
        for pid, (info, _) in self.live.items():
            self.last_pid = pid
            fresh = read_identity(pid)
            require(all(fresh.get(k) == info.get(k) for k in ('pid','start','parent','group')), 'UI native edge changed')
            if fresh['path'] != info['path']:
                raise Unstable('UI exec changed after semantic validation')
        for pin in self.file_pins:
            _, fresh = artifacts.read_file(pin.path, limit=pin.limit, private=pin.private)
            require(fresh == pin, 'UI fixture ownership artifact changed')
        for pid, capture in self.captures.items():
            if self.operation_state(json.loads(capture.request_json)) != self.operation_states[pid]:
                raise Unstable('UI operation changed during observation')
        if self.cursor and self.cursor.preparation:
            a_stage = self.cursor.marker_stage
            if self.cursor.marker() != a_stage:
                raise Unstable('preparation marker advanced during observation')
        self.check()
        return dict(self.roles)
