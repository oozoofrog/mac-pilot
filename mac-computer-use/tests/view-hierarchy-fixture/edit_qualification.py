"""Bounded serial schema-2 qualification, hosted by the existing protected session."""
import base64
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

TOTAL = 3300
SETUP = 180
PRE = 25
OPERATION = 163  # Unchanged canonical 45s work + 100s cleanup + outer margin.
POST = 72  # Two 25s probes, 8s screenshot, 8s oracle, 6s readback margin.
SESSION_CLEANUP = 117
RECEIPT = 5
GRACE = OPERATION + POST + SESSION_CLEANUP
WORK = TOTAL - GRACE - RECEIPT
COUNT = 10
MINIMUM = SETUP + COUNT * (PRE + OPERATION + POST) + SESSION_CLEANUP + RECEIPT
TARGET_NAME = 'fixture.editTarget'
TARGET_CLASS = 'MacCUQualificationEditTarget'


class DesktopGuard:
    """Read host focus without AX, event injection, activation or a GUI process."""
    def __init__(self, input_guard, host_pid, read_focus=None):
        self.input_guard, self.host_pid = input_guard, host_pid
        if read_focus is None:
            import ctypes as c
            c.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
            objc = c.CDLL('/usr/lib/libobjc.A.dylib')
            objc.objc_getClass.argtypes = [c.c_char_p]; objc.objc_getClass.restype = c.c_void_p
            objc.sel_registerName.argtypes = [c.c_char_p]; objc.sel_registerName.restype = c.c_void_p
            send = c.CFUNCTYPE(c.c_void_p, c.c_void_p, c.c_void_p)(('objc_msgSend', objc))
            pid_send = c.CFUNCTYPE(c.c_int32, c.c_void_p, c.c_void_p)(('objc_msgSend', objc))
            def get_focus():
                pool = send(send(objc.objc_getClass(b'NSAutoreleasePool'), objc.sel_registerName(b'alloc')), objc.sel_registerName(b'init'))
                try:
                    workspace = send(objc.objc_getClass(b'NSWorkspace'), objc.sel_registerName(b'sharedWorkspace'))
                    app = send(workspace, objc.sel_registerName(b'frontmostApplication'))
                    return pid_send(app, objc.sel_registerName(b'processIdentifier')) if app else None
                finally:
                    send(pool, objc.sel_registerName(b'drain'))
            read_focus = get_focus
        self.read_focus = read_focus
        self.check()

    def check(self):
        self.input_guard.check()
        if self.read_focus() != self.host_pid:
            raise InterruptedError('host focus lost; stop, do not reactivate')


def check_process_budget(snapshot, group, target, build, server_path, details):
    """Read-only exact executable/topology budgets. Never grants signal authority."""
    members = [r for r in snapshot if r[2] == group and r[0] != group]
    probes = [r for r in snapshot if r[3] == str((build / 'session-probe').resolve())]
    require(len(probes) <= 1, 'one-probe executable budget exceeded')
    require(sum(r[3] == target['path'] for r in snapshot) <= 1, 'one-fixture executable budget exceeded')
    python_path = str(Path(sys.executable).resolve())
    supervisors = [r for r in members if r[1] == group and r[3] == python_path]
    require(len(supervisors) <= 1, 'one-supervisor direct-child budget exceeded')
    if supervisors:
        supervisor = supervisors[0]
        children = [r for r in members if r[1] == supervisor[0]]
        servers = [r for r in children if r[3] == str(server_path)]
        workers = [r for r in children if r[3] == python_path]
        require(len(servers) <= 1 and len(workers) <= 1, 'one-LLDB-worker/debugserver budget exceeded')
        require(len(children) == len(servers) + len(workers), 'unknown supervisor child')
        # Neither LLDB worker nor debugserver may create an unowned descendant.
        ids = {r[0] for r in children}
        require(not any(r[1] in ids for r in members), 'unexpected debugger descendant')
    details['editProcessBudgetSamples'] = details.get('editProcessBudgetSamples', 0) + 1


def uid():
    return str(uuid.uuid4()).upper()


def require_full_preparation(build):
    manifest = json.loads((build / 'prepared.json').read_text())
    require(manifest.get('wholeProbeVerified') is True and manifest.get('editQualificationReady') is True,
            'edit runtime requires a fresh whole probe after AX native source freeze')


def require_lldb_python(capture):
    """Import the selected Xcode extension in this worker interpreter, without attaching."""
    _, module_path, _ = capture.tools_for_xcode()
    code = ('import sys,json,os;sys.path.insert(0,sys.argv[1]);import lldb;'
            'print(json.dumps({"executable":os.path.realpath(sys.executable),'
            '"version":sys.version,"module":os.path.realpath(lldb.__file__)}))')
    run = subprocess.run([sys.executable, '-I', '-c', code, str(module_path)],
                         capture_output=True, text=True, timeout=8)
    require(run.returncode == 0, 'LLDB Python preflight failed; run the session with xcrun python3: ' + run.stderr[-2000:])
    result = json.loads(run.stdout)
    require(result['executable'] == str(Path(sys.executable).resolve())
            and result['module'] == str((module_path / 'lldb/__init__.py').resolve()),
            'LLDB Python preflight imported an unexpected interpreter/module')
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def nodes(snapshot):
    pending = list(snapshot['roots'])
    found = []
    while pending:
        require(len(found) < 20000, 'snapshot exceeds node bound')
        node = pending.pop(); found.append(node)
        pending.extend(node.get('children') or [])
    return found


def selection(snapshot, result):
    require(snapshot['captureID'] == result['captureID'], 'snapshot captureID mismatch')
    require(snapshot['processLifetime'] == result['target'], 'snapshot lifetime mismatch')
    # Schema 2 intentionally does not expose accessibilityIdentifier. The explicitly
    # named fixture class is unique and carries the opaque token in the snapshot.
    selected = [n for n in nodes(snapshot) if n.get('className') == TARGET_CLASS]
    require(len(selected) == 1, 'named edit target is missing or ambiguous')
    node = selected[0]
    for key in ('id', 'editToken', 'windowToken'):
        require(str(uuid.UUID(node[key])).upper() == node[key], 'non-token snapshot identity')
    require(node['id'] == node['editToken'], 'snapshot token mismatch')
    assets = snapshot['assets']
    require(snapshot['capabilities']['textures'] is True and bool(assets), 'textured capture unavailable')
    require(node.get('assetID') in assets, 'named target texture unavailable')
    by_token = {n['editToken']: n for n in nodes(snapshot)}
    for asset_id, asset in assets.items():
        require(asset['captureID'] == result['captureID'], 'asset captureID mismatch')
        token = asset['nodeID']
        require(token in by_token and by_token[token].get('assetID') == asset_id, 'asset/token mapping mismatch')
    return node


def clean_receipt(result, request):
    require(result.get('operationID') == request['operationID'], 'operation receipt mismatch')
    for key in ('ownerID', 'inspectionID'):
        require(result.get(key) == request[key], key + ' receipt mismatch')
    require(result.get('status') == 'success', 'operation failed; no retry: ' + str(result.get('status')))
    cleanup = result.get('cleanup', {})
    require(cleanup.get('detach') == 'success' and cleanup.get('childrenReaped') is True
            and cleanup.get('recovery', {}).get('verified') is True, 'operation cleanup unverified')
    encoded = json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    require(result.get('requestDigest') == hashlib.sha256(encoded).hexdigest(), 'request/sequence digest mismatch')
    if request['kind'] != 'release':
        require(result.get('needsRefresh') is False, 'operation authority revoked')


def value_matches(actual, expected):
    if type(expected) is bool:
        return type(actual) is bool and actual == expected
    return type(actual) in (int, float) and math.isfinite(actual) and actual == expected


class Sequence:
    """No retry, inverse-value construction, address lookup or expiry renewal."""
    def __init__(self, runtime):
        self.runtime = runtime
        self.owner = uid()
        self.inspection = None
        self.context = None
        self.sequence = 0
        self.selected = None

    def call(self, kind, label, **fields):
        self.sequence += 1
        request = dict(schemaVersion=2, kind=kind, target=self.runtime.target, validationOnly=True,
            ownerID=self.owner, inspectionID=self.inspection, operationID=uid(), sequence=self.sequence,
            targetEpoch=self.context['targetEpoch'] if self.context else None, **fields)
        if self.context:
            require(time.time() < self.context['editing']['expiresAt'], 'capture TTL 120s expired; explicit new session required')
            require(self.runtime.now() < self.expiry_monotonic, 'capture monotonic TTL expired; no auto-extension')
        result = self.runtime.operation(request, label)
        clean_receipt(result, request)
        if kind != 'capture':
            require(result.get('targetEpoch') == self.context['targetEpoch']
                    and result.get('captureID') == self.context['captureID'], 'capture/epoch receipt mismatch')
        return result

    def capture(self, label, new_owner=False):
        if new_owner:
            self.owner = uid()
        self.inspection, self.context, self.sequence = uid(), None, 0
        began = self.runtime.now()
        result = self.call('capture', label, replaceCaptureID=None)
        self.context = result
        # Conservative receipt-independent cap. Actual host/target expiry is unchanged.
        self.expiry_monotonic = began + 120
        snapshot = self.runtime.convert(result, label)
        self.selected = selection(snapshot, result)
        require(self.selected['hidden'] is False and self.selected['alpha'] == 1, 'capture initial values differ')
        self.runtime.observe(label, False, 1, 0, 0)

    def edit_and_undo(self, property_, old, value, hidden_delta, alpha_delta):
        node = self.selected
        result = self.call('edit', property_, captureID=self.context['captureID'], nodeToken=node['editToken'],
            expectedParentToken=node['parentID'], expectedWindowToken=node['windowToken'], expectedClass=node['className'],
            property=property_, expectedValue=old, value=value)
        require(result.get('mutationOutcome') == 'appliedObserved' and result.get('setterEntered') is True
                and result.get('nodeToken') == node['editToken'] and result.get('property') == property_
                and value_matches(result.get('before'), old) and value_matches(result.get('requested'), value)
                and value_matches(result.get('observed'), value),
                'setter/readback receipt differs; preserve uncertainty')
        self.runtime.observe(property_, value if property_ == 'hidden' else False,
                             value if property_ == 'alpha' else 1, hidden_delta, alpha_delta)
        undo = result.get('undoToken')
        require(isinstance(undo, str), 'server undo receipt missing')
        result = self.call('revert', property_ + '-undo', captureID=self.context['captureID'], undoToken=undo)
        require(result.get('mutationOutcome') == 'appliedObserved' and result.get('setterEntered') is True
                and result.get('nodeToken') == node['editToken'] and result.get('property') == property_
                and value_matches(result.get('before'), value) and value_matches(result.get('requested'), old)
                and value_matches(result.get('observed'), old), 'undo readback differs')
        self.runtime.observe(property_ + '-undo', False, 1, int(property_ == 'hidden'), int(property_ == 'alpha'))

    def release(self, label):
        result = self.call('release', label, captureID=self.context['captureID'], reason='close')
        require(result.get('registryReleased') is True and result.get('remainingOwnedEntries') == 0
                and result.get('authorityRevoked') is True and isinstance(result.get('releaseProof'), dict),
                'release proof missing; no recapture/reopen')
        self.runtime.observe(label, False, 1, 0, 0)
        self.context = None

    def run(self):
        self.capture('capture')
        self.edit_and_undo('hidden', False, True, 1, 0)
        self.edit_and_undo('alpha', 1.0, 0.5, 0, 1)
        self.release('release')
        self.capture('recapture')
        self.release('recapture-release')
        self.capture('reopen', new_owner=True)
        self.release('final-release')


class Runtime:
    def __init__(self, session, build, out, device, target, before, data, claim, input_guard, stopping, deadline):
        self.s, self.build, self.out, self.device = session, build, out, device
        self.target, self.before, self.claim = target, before, claim
        self.input_guard, self.stopping, self.deadline = input_guard, stopping, deadline
        self.oracle = Path(data) / 'Documents/edit-oracle.json'
        self.pp = session.capture.ProcessProbe()
        self.records = []
        self.last_sample = None
        self.child = None
        self.operation_index = 0
        self.last_operation_start = 0
        self.now = session.monotonic
        (out / 'operations').mkdir(mode=0o700)

    def check(self):
        self.claim.check(); self.input_guard.check()
        if self.stopping():
            raise InterruptedError('session cancellation; no further operation')

    def foreground(self, label):
        self.check()
        state = self.s.probe(self.build, self.out, label, self.device)
        self.s.require_static_portrait(state)
        require(state['frontPID'] == self.target['pid'] and state['frontStart'] == self.target['start']
                and state['frontPath'] == self.target['path'] and state['hostPID'] == self.before['hostPID']
                and state.get('hostStart') == self.before.get('hostStart')
                and self.s.display_state(state) == self.s.display_state(self.before), 'focus/display/lifetime changed')
        self.check()

    def operation(self, request, label):
        self.s.reserve(self.deadline, OPERATION + POST + SESSION_CLEANUP + self.s.PROBE_BUDGET,
                       'complete operation, post-observation and session cleanup')
        self.foreground(label + '-before')
        self.s.capture.verify_target(self.pp, self.target)
        self.s.capture.request_contract(request)  # Closed production schema, never widened here.
        self.operation_index += 1
        folder = self.out / 'operations' / ('%02d-' % self.operation_index + label)
        folder.mkdir(mode=0o700)
        self.s.save(folder / 'request.json', request)
        record = {'label': label, 'request': request, 'folder': str(folder), 'operationBudgetSeconds': OPERATION,
                  'postBudgetSeconds': POST, 'sessionCleanupReservedSeconds': SESSION_CLEANUP,
                  'startedMonotonic': self.now(), 'startedUnixSeconds': time.time()}
        self.last_operation_start = record['startedUnixSeconds']
        self.records.append(record)
        self.persist()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'PYTHON'))}
        env['MAC_CU_EDIT_PARENT'] = str(os.getpid())
        failure = None
        with (folder / 'supervisor.log').open('w') as log:
            self.child = subprocess.Popen([sys.executable, '-I', str(self.s.HERE / 'edit-supervisor.py'),
                '--owned-operation', str(folder), str(self.out / 'ledger')], env=env,
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            try:
                record['supervisor'] = self.s.watchdog.process_identity(self.child.pid)
                self.s.finish_capture(self.child, folder, self.stopping, check=self.check,
                                      deadline=record['startedMonotonic'] + OPERATION)
            except BaseException as error:
                failure = error
                record['observerError'] = repr(error)
                (folder / 'cancel').touch(mode=0o600, exist_ok=True)
                if self.child.poll() is None and self.now() < record['startedMonotonic'] + OPERATION:
                    try:
                        self.s.finish_capture(self.child, folder, lambda: True,
                                              deadline=record['startedMonotonic'] + OPERATION)
                    except BaseException as cleanup_error:
                        record['supervisorCleanupError'] = repr(cleanup_error)
            finally:
                record['supervisorExit'] = self.child.poll()
                # A returned direct child is reaped. The canonical result attests its
                # children; the outer parent independently reads the entire group.
                if self.child.poll() is not None:
                    self.child.wait(timeout=1)
                if (folder / 'result.json').is_file():
                    try:
                        record['receipt'] = self.s.capture.read_json(folder / 'result.json')
                    except Exception as error:
                        record['receiptReadError'] = repr(error)
                self.persist()
        result = record.get('receipt')
        self.last_operation_start = time.time()  # Require an oracle sample after debugger cleanup, not merely before the setter.
        if not isinstance(result, dict):
            raise self.s.ProbeCleanupUnknown('missing receipt; outcome and cleanup unknown, never retry')
        cleanup = result.get('cleanup', {})
        if not isinstance(cleanup, dict) or not isinstance(cleanup.get('recovery'), dict):
            raise self.s.ProbeCleanupUnknown('malformed cleanup receipt; preserve fixture and claim')
        ownership = folder / 'owned-children.json'
        try:
            owned = self.s.capture.read_json(ownership) if ownership.is_file() else {}
            require(isinstance(owned, dict), 'child ownership evidence is not an object')
        except Exception as error:
            raise self.s.ProbeCleanupUnknown('child ownership readback unavailable') from error
        never_attached = (result.get('connected') is False and result.get('attachRequested') is False
            and result.get('setterEntered') is False and result.get('mutationOutcome') == 'notEntered'
            and result.get('phase') == 'admission' and result.get('reasonCode') == 'notDispatched'
            and cleanup.get('detach') == 'not attempted' and cleanup.get('closeError') is None
            and not any((folder / name).exists() for name in ('dispatch.json', 'answer.json', 'main-thread-entry.json')))
        if (self.child.poll() is None or cleanup.get('childrenReaped') is not True or cleanup.get('recovery', {}).get('verified') is not True
                or (cleanup.get('detach') != 'success' and not never_attached) or owned.get('allReapedAndAbsent') is not True):
            raise self.s.ProbeCleanupUnknown('edit operation cleanup unverified; preserve fixture and claim')
        record['ownedChildren'] = owned
        if never_attached:
            if (result.get('target') != self.target
                    or not self.s.capture.same_target(cleanup['recovery'].get('target', {}), self.target)):
                raise self.s.ProbeCleanupUnknown('pre-attach recovery lifetime mismatch; preserve fixture and claim')
            self.s.capture.verify_target(self.pp, self.target)
            record.update(cleanupClassification='verifiedNeverAttached', finishedMonotonic=self.now())
            self.persist()
            raise RuntimeError('operation failed before attach; cleanup verified: ' + str(result.get('message')))
        if failure:
            self.persist()
            raise failure
        self.check()
        require(result.get('target') == self.target, 'result target lifetime differs')
        entry = folder / 'main-thread-entry.json'
        require(entry.is_file(), 'pre-injection selected main stack missing')
        recorded = self.s.capture.read_json(entry)
        require(recorded == result.get('mainThreadEntry') and recorded.get('candidateIdle') is True,
                'main stack receipt differs or safe-entry rejected')
        record['selectedMainStack'] = str(entry)
        for key in ('targetBefore', 'beforeAttach', 'afterAttach'):
            require(self.s.capture.same_target(result.get(key, {}), self.target), key + ' lifetime mismatch')
        require(self.s.capture.same_target(cleanup['recovery'].get('target', {}), self.target), 'recovery lifetime mismatch')
        self.s.capture.verify_target(self.pp, self.target)
        record['finishedMonotonic'] = self.now()
        self.persist()
        return result

    def convert(self, result, label):
        self.check()
        folder = Path(self.records[-1]['folder'])
        snapshot = self.s.probe(self.build, self.out, label + '-snapshot', self.device, folder / 'result.json')
        selected = selection(snapshot, result)
        exported = []
        for asset_id, asset in snapshot['assets'].items():
            # Canonical Swift already validated PNG/CRC, limits and same-operation joins.
            encoded = asset.get('data')
            require(isinstance(encoded, str), 'canonical asset base64 is missing')
            pixels = base64.b64decode(encoded, validate=True)
            name = 'asset-%03d.png' % len(exported)
            (folder / name).write_bytes(pixels)
            exported.append({'assetID': asset_id, 'nodeToken': asset['nodeID'], 'captureID': asset['captureID'],
                             'path': str(folder / name), 'sha256': hashlib.sha256(pixels).hexdigest(),
                             'descendantContent': asset.get('descendantContent')})
        self.s.save(folder / 'asset-map.json', {'assets': exported, 'selectedToken': selected['editToken'],
                                             'pixelsReviewed': False, 'LCD3DQualified': False})
        return snapshot

    def observe(self, label, hidden, alpha, hidden_delta, alpha_delta):
        self.foreground(label + '-after')
        until = self.now() + 8
        previous = self.last_sample
        while True:
            self.check()
            require(self.oracle.is_file() and not self.oracle.is_symlink()
                    and self.oracle.stat().st_size <= 262144, 'bounded edit oracle missing')
            oracle = json.loads(self.oracle.read_text())
            require(oracle['schemaVersion'] == 1 and 0 < len(oracle['samples']) <= 128, 'invalid edit oracle')
            sample = oracle['samples'][-1]
            if sample['unixSeconds'] >= self.last_operation_start and (previous is None or sample['sequence'] > previous['sequence']):
                break
            require(self.now() < until, 'no fresh independent oracle sample')
            time.sleep(.05)
        self.s.save(self.out / (label + '-edit-oracle.json'), oracle)
        require(sample['pid'] == self.target['pid'] and sample['name'] == TARGET_NAME
                and sample['className'] == TARGET_CLASS and sample['sceneActivationState'] == 0,
                'oracle target/active scene mismatch')
        if previous:
            for key in ('nodeGeneration', 'parentGeneration', 'windowGeneration', 'sceneGeneration', 'sceneID'):
                require(sample[key] == previous[key], 'oracle generation changed: ' + key)
            counts = previous['setterCounts']
        else:
            counts = oracle['constructionBaseline']
        require(sample['setterCounts'] == {'hidden': counts['hidden'] + hidden_delta,
                'alpha': counts['alpha'] + alpha_delta}, 'independent setter count differs')
        require(type(sample['hidden']) is bool and sample['hidden'] == hidden
                and not isinstance(sample['alpha'], bool) and sample['alpha'] == alpha, 'independent values differ')
        self.last_sample = sample
        self.records[-1]['oracleSample'] = sample
        self.check()
        if label in ('capture', 'hidden', 'hidden-undo', 'alpha', 'alpha-undo', 'reopen'):
            image = self.out / (label + '-device.png')
            subprocess.run(['xcrun', 'simctl', 'io', self.device, 'screenshot', str(image)], check=True, timeout=8)
            self.records[-1]['screenshot'] = {'path': str(image), 'sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
                                            'visiblePixelsReviewed': False}
        self.persist()

    def persist(self):
        try:
            self.s.save(self.out / 'edit-sequence.json', {'operations': self.records, 'automaticRetries': 0,
                'captureTTLSeconds': 120, 'generalAppQualified': False, 'renderedUIQualified': False})
        except Exception as error:
            raise self.s.ProbeCleanupUnknown('operation evidence persistence failed; preserve fixture and claim') from error
