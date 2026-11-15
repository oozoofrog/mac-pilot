"""Closed fixture edit protocol, durable host admission and fixed expression generation.

No transport lives here: capture.supervise/run_engine own every debugger operation.
The ledger is private, fsync/rename committed before dispatch, and locked for the
whole operation. An interrupted reservation is NEVER resumed, even after restart.
"""
import base64
import fcntl
import hashlib
import json
import math
import re
import os
from pathlib import Path
import stat
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
MAX_OPERATIONS = 4096
MAX_RESULTS = 256
MAX_RETIRED_EPOCHS = 64  # Never evict: losing a fence could revive a delayed initial capture.
MAX_NODES = 20000
TTL = 120
FIXTURE_EDIT_ENABLED = True  # Experimental execution only, NOT runtime qualification.
GENERAL_APP_EDIT_QUALIFIED = False


class BackendError(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


def fail(status, message):
    raise BackendError(status, message)


def identifier(value, nullable=False):
    if value is None and nullable:
        return
    try:
        if type(value) is not str or str(uuid.UUID(value)) != value.lower():
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        fail('invalidRequest', 'Expected canonical UUID')


def scalar(prop, value):
    if prop == 'hidden' and type(value) is bool:
        return value
    if prop == 'alpha' and type(value) in (int, float) and 0 <= value <= 1 and math.isfinite(value):
        return float(value)  # Only 64-bit Simulator CGFloat is admitted by the engine.
    fail('invalidRequest', 'hidden requires Bool; alpha requires a finite number in 0...1')


def swiftui_product():
    # Explicit sibling loading also works in the production Python -I route.
    import importlib.util
    import sys
    name = 'mac_cu_swiftui_product'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, HERE / 'swiftui_product.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules[name] = module
    return sys.modules[name]


def contract(raw, validate_v1):
    common = {'schemaVersion', 'kind', 'target', 'validationOnly', 'ownerID', 'inspectionID',
              'targetEpoch', 'operationID', 'sequence'}
    extras = {'capture': {'replaceCaptureID'},
              'edit': {'captureID', 'nodeToken', 'expectedParentToken', 'expectedWindowToken',
                       'expectedClass', 'property', 'expectedValue', 'value'},
              'revert': {'captureID', 'undoToken'},
              'release': {'captureID', 'reason'}}
    if type(raw) is not dict or type(raw.get('kind')) is not str or raw['kind'] not in extras:
        fail('invalidRequest', 'Invalid edit operation')
    kind = raw['kind']
    if set(raw) - ({'inspectionScope'} if kind == 'capture' else set()) != common | extras[kind] or type(raw['schemaVersion']) is not int or raw['schemaVersion'] != 2:
        fail('invalidRequest', 'Invalid schema 2 fields')
    validate_v1({'schemaVersion': 1, 'target': raw['target'], 'query': '', 'validationOnly': raw['validationOnly']})
    if len(raw['target']['path'].encode()) > 4096 or raw['target']['start'][0] > (1 << 64) - 1:
        fail('invalidRequest', 'Target identity exceeds fixed bounds')
    if raw['validationOnly'] and not FIXTURE_EDIT_ENABLED:
        fail('unavailable', 'Editable execution is limited to the validation fixture')
    for key in ('ownerID', 'inspectionID', 'operationID'):
        identifier(raw[key])
    identifier(raw['targetEpoch'], nullable=kind == 'capture')
    if type(raw['sequence']) is not int or not 1 <= raw['sequence'] <= MAX_OPERATIONS:
        fail('invalidRequest', 'Sequence exceeds bounded epoch capacity')
    if kind == 'capture':
        identifier(raw['replaceCaptureID'], nullable=True)
        if (raw['targetEpoch'] is None) != (raw['replaceCaptureID'] is None):
            fail('invalidRequest', 'Refresh requires both epoch and replaced capture')
    else:
        identifier(raw['captureID'])
    if kind == 'edit':
        for key in ('nodeToken', 'expectedWindowToken'):
            identifier(raw[key])
        identifier(raw['expectedParentToken'], nullable=True)
        if (type(raw['expectedClass']) is not str or not 1 <= len(raw['expectedClass'].encode()) <= 512
                or '\0' in raw['expectedClass']):
            fail('invalidRequest', 'Invalid class identity')
        if type(raw['property']) is not str or raw['property'] not in ('hidden', 'alpha'):
            fail('invalidRequest', 'Unsupported property')
        scalar(raw['property'], raw['expectedValue'])
        scalar(raw['property'], raw['value'])
    if kind == 'revert':
        identifier(raw['undoToken'])
    if kind == 'release' and raw['reason'] not in ('close', 'refresh', 'expired', 'cancel', 'targetChanged'):
        fail('invalidRequest', 'Invalid release reason')
    if 'inspectionScope' in raw:
        try: swiftui_product().validate_scope(raw['inspectionScope'], raw['target']['deviceID'])
        except ValueError as error: fail('invalidRequest', str(error))
    normalized = dict(raw)
    normalized['target'] = {**raw['target'], 'deviceID': raw['target']['deviceID'].upper(),
                            'path': os.path.realpath(raw['target']['path'])}
    for key in ('ownerID', 'inspectionID', 'operationID', 'targetEpoch', 'replaceCaptureID', 'captureID',
                'nodeToken', 'expectedParentToken', 'expectedWindowToken', 'undoToken'):
        if normalized.get(key) is not None:
            normalized[key] = normalized[key].upper()
    return normalized


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def release_proof_valid(proof):
    fields = {'ownerID', 'inspectionID', 'targetEpoch', 'captureID', 'operationID', 'requestDigest', 'sequence', 'entryTransitionID'}
    if type(proof) is not dict or set(proof) != fields:
        return False
    try:
        identifier(proof['entryTransitionID'], nullable=True)
        for key in fields - {'requestDigest', 'sequence', 'entryTransitionID'}:
            identifier(proof[key])
            if proof[key] != proof[key].upper():
                return False
        return (type(proof['sequence']) is int and 1 <= proof['sequence'] <= MAX_OPERATIONS
                and type(proof['requestDigest']) is str and len(proof['requestDigest']) == 64
                and all(c in '0123456789abcdef' for c in proof['requestDigest']))
    except BackendError:
        return False


def retired_valid(retired):
    return (type(retired) is list and len(retired) <= MAX_RETIRED_EPOCHS
            and all(release_proof_valid(p) for p in retired)
            and len({p['targetEpoch'] for p in retired}) == len(retired)
            and len({p['inspectionID'] for p in retired}) == len(retired)
            and len({p['entryTransitionID'] for p in retired if p['entryTransitionID'] is not None})
                == sum(p['entryTransitionID'] is not None for p in retired))


def receipt(request, status, reason, outcome='notEntered'):
    return {'schemaVersion': 2, 'operationID': request['operationID'], 'requestDigest': digest(request),
            'status': status, 'reasonCode': reason, 'phase': 'admission', 'mutationOutcome': outcome,
            'before': None, 'requested': request.get('value'), 'observed': None, 'undoToken': None,
            'setterEntered': False, 'postcondition': 'unavailable', 'needsRefresh': status != 'success', 'cleanup': {}}


def secure_directory(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail('ownershipFailed', 'Ledger directory must be owned, private and not a symlink')
    return path


def atomic_write(path, value):
    """Private atomic replacement with data AND directory synchronization; no stale .new reuse."""
    fd, name = tempfile.mkstemp(prefix='.reservation-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Ledger:
    def __init__(self, request, root=None, now=time.time):
        self.request, self.now = request, now
        self.root = secure_directory(root or Path.home() / 'Library/Application Support/mac-cu/view-edit-ledger')
        key = digest(request['target'])
        self.path = self.root / (key + '.json')
        # Bound persistent target lifetimes. No automatic eviction of unresolved authority.
        if not self.path.exists() and len(list(self.root.glob('*.json'))) >= 128:
            fail('capacityExceeded', 'Ledger target capacity exhausted; explicit maintenance required')
        self.lock = os.open(self.root / (key + '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(self.lock)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                fail('ownershipFailed', 'Invalid ledger lock')
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail('busy', 'Target already has a host operation')
            self.state = self.read()
            if self.state and any(op.get('state') == 'reserved' for op in self.state['operations'].values()):
                # A new ID is not a retry escape after a supervisor/host crash.
                self.state['authority'] = 'quarantined'
        except BaseException:
            os.close(self.lock)
            raise

    def read(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                fail('ownershipFailed', 'Invalid ledger file')
            data = stream.read(32 * 1024 * 1024 + 1)
        if len(data) > 32 * 1024 * 1024:
            fail('ownershipFailed', 'Ledger exceeds capacity')
        try:
            state = json.loads(data)
            assert type(state['schema']) is int and state['schema'] == 2 and state['target'] == self.request['target']
            # Older/unrecognized ledgers cannot prove retirement. Never infer release
            # from a revoked bit or silently upgrade a target's old tombstone.
            assert type(state['lifecycleVersion']) is int and state['lifecycleVersion'] == 1 and retired_valid(state['retired'])
            for key in ('ownerID', 'inspectionID', 'epoch', 'captureID'):
                identifier(state[key])
            assert state['authority'] in ('inactive', 'active', 'revoked', 'released', 'quarantined', 'expired')
            assert type(state['highWater']) is int and 0 <= state['highWater'] <= MAX_OPERATIONS
            assert type(state['operations']) is dict and len(state['operations']) <= MAX_OPERATIONS
            assert type(state['results']) is dict and len(state['results']) <= MAX_RESULTS
            assert type(state['nodes']) is dict and len(state['nodes']) <= MAX_NODES
            assert type(state['undo']) is dict and len(state['undo']) <= MAX_RESULTS
            for op_id, operation in state['operations'].items():
                identifier(op_id)
                assert type(operation) is dict and operation['state'] in ('reserved', 'finished')
                assert operation['kind'] in ('capture', 'edit', 'revert', 'release')
                assert type(operation['sequence']) is int and 1 <= operation['sequence'] <= state['highWater']
                assert type(operation['digest']) is str and len(operation['digest']) == 64
                if 'wireDigest' in operation:
                    assert type(operation['wireDigest']) is str and len(operation['wireDigest']) == 64
                    assert all(c in '0123456789abcdef' for c in operation['wireDigest'])
            assert not any(p['targetEpoch'] == state['epoch'] or p['inspectionID'] == state['inspectionID'] for p in state['retired'])
            proof = state.get('releaseProof')
            if proof is not None:
                assert release_proof_valid(proof)
                assert all(proof[k] == state[v] for k, v in (('ownerID', 'ownerID'), ('inspectionID', 'inspectionID'), ('targetEpoch', 'epoch')))
                assert proof['sequence'] == state['highWater']
                operation = state['operations'][proof['operationID']]
                assert {k: v for k, v in operation.items() if k != 'wireDigest'} == {
                    'kind': 'release', 'digest': proof['requestDigest'], 'sequence': proof['sequence'], 'state': 'finished'}
                assert proof['entryTransitionID'] == (state.get('transition') or {}).get('transitionID')
            if state['authority'] == 'released':
                assert proof is not None and not state['nodes'] and not state['undo']
                assert all(v['state'] == 'finished' for v in state['operations'].values())
                release = state['results'][proof['operationID']]
                assert release['status'] == 'success' and release['registryReleased'] is True
                assert release['releaseProof'] == proof and release['remainingOwnedEntries'] == 0
                assert release['residualState'] == 'tombstone' and release['mutationOutcome'] == 'notApplicable'
                assert release['setterEntered'] is False and release['authorityRevoked'] is True
                assert release['cleanup']['detach'] == 'success' and release['cleanup']['childrenReaped'] is True
                assert release['cleanup']['recovery']['verified'] is True and not release['cleanup']['closeError']
            transition = state.get('transition')
            assert bool(state['retired']) == (transition is not None)
            if transition is not None:
                assert type(transition) is dict
                assert set(transition) == {'transitionID', 'predecessor', 'retired'}
                identifier(transition['transitionID'])
                assert retired_valid(transition['retired']) and release_proof_valid(transition['predecessor'])
                assert state['retired'] == transition['retired'] + [transition['predecessor']]
                assert not any(p['entryTransitionID'] == transition['transitionID'] for p in state['retired'])
        except (ValueError, KeyError, TypeError, AssertionError, BackendError):
            fail('ownershipFailed', 'Ledger is invalid; lost authority cannot be reconstructed')
        return state

    def close(self):
        os.close(self.lock)

    def save(self):
        atomic_write(self.path, self.state)

    def new_epoch(self, retired, transition=None):
        r = self.request
        epoch = str(uuid.uuid4()).upper()
        if any(p['targetEpoch'] == epoch for p in retired):
            fail('ownershipFailed', 'Generated epoch collision')
        return {'schema': 2, 'lifecycleVersion': 1, 'target': r['target'], 'ownerID': r['ownerID'],
                'inspectionID': r['inspectionID'], 'epoch': epoch, 'highWater': 0,
                'captureID': str(uuid.uuid4()).upper(), 'expiresAt': 0, 'authority': 'inactive', 'nodes': {},
                'operations': {}, 'results': {}, 'undo': {}, 'retired': retired, 'transition': transition}

    def reserve(self):
        r, s = self.request, self.state
        if s is not None:
            if any(p['inspectionID'] == r['inspectionID'] or p['targetEpoch'] == r['targetEpoch'] for p in s['retired']):
                fail('expired', 'retiredInspectionOrEpoch')
            if s['ownerID'] != r['ownerID'] or s['inspectionID'] != r['inspectionID']:
                if r['kind'] != 'capture' or r['targetEpoch'] is not None or r['sequence'] != 1 or r['inspectionID'] == s['inspectionID']:
                    fail('ownershipConflict', 'Another inspection owns this target lifetime')
                if s['authority'] != 'released' or not s.get('releaseProof'):
                    fail('ownershipConflict', 'predecessorNotVerifiedReleased; noTargetStateRetirementUnsupported')
                if len(s['retired']) >= MAX_RETIRED_EPOCHS:
                    fail('capacityExceeded', 'Retired epoch capacity exhausted; no fence may be evicted')
                transition = {'transitionID': str(uuid.uuid4()).upper(), 'predecessor': s['releaseProof'], 'retired': s['retired']}
                if any(p['entryTransitionID'] == transition['transitionID'] for p in s['retired'] + [s['releaseProof']]):
                    fail('ownershipFailed', 'Generated transition identity collision')
                s = self.new_epoch(s['retired'] + [s['releaseProof']], transition)
                self.state = s
                # The successor reservation and predecessor fence commit together below.
                # No wire exists before save. An interrupted reservation never resumes.
                return self.reserve_new(s)
            old = s['operations'].get(r['operationID'])
            if old:
                if old['digest'] != digest(r):
                    fail('conflict', 'operationID digest conflict')
                if old['state'] == 'reserved':
                    s['authority'] = 'quarantined'
                    self.save()
                    return {**receipt(r, 'outcomeUncertain', 'interruptedReservation', 'uncertain'),
                            'target': s['target'], 'ownerID': s['ownerID'], 'inspectionID': s['inspectionID'],
                            'targetEpoch': s['epoch'], 'captureID': s['captureID']}
                cached = dict(s['results'].get(r['operationID'], receipt(r, 'resultUnavailable', 'resultEvicted', 'uncertain')))
                cached['replayed'] = True
                if s['authority'] != 'active' and r['kind'] != 'release':
                    cached.update(needsRefresh=True, undoToken=None)
                    cached.pop('editing', None)
                return cached
            if r['sequence'] <= s['highWater']:
                fail('resultUnavailable', 'Sequence is at or below high-water; never replay')
            if r['targetEpoch'] != s['epoch']:
                fail('expired', 'Target epoch differs')
            if r['kind'] == 'capture':
                if r['replaceCaptureID'] != s['captureID']:
                    fail('conflict', 'Replacement capture differs')
            elif r['captureID'] != s['captureID'] and not (r['kind'] == 'release' and r['captureID'] == s.get('attemptedCaptureID')):
                fail('expired', 'Capture differs')
            if r['kind'] in ('edit', 'revert'):
                if s['authority'] != 'active':
                    fail('outcomeUncertain', 'Inspection is revoked/quarantined; explicit new capture required')
                if self.now() >= s['expiresAt'] or time.clock_gettime(time.CLOCK_MONOTONIC) >= s.get('expiresMonotonic', 0):
                    s['authority'] = 'expired'; self.save()
                    fail('expired', 'Capture expired')
                if r['kind'] == 'edit':
                    n = s['nodes'].get(r['nodeToken'])
                    if n is None or any(n[k] != r[q] for k, q in (
                        ('parentToken', 'expectedParentToken'), ('windowToken', 'expectedWindowToken'), ('className', 'expectedClass'))):
                        fail('conflict', 'Token or expected graph differs from owned capture')
                elif r['undoToken'] not in s['undo']:
                    fail('undoConflict', 'Undo receipt is unavailable or superseded')
        else:
            if r['kind'] != 'capture' or r['targetEpoch'] is not None or r['sequence'] != 1:
                fail('expired', 'No durable epoch authority; only initial capture is admitted')
            s = self.state = self.new_epoch([])
        return self.reserve_new(s)

    def reserve_new(self, s):
        r = self.request
        if len(s['operations']) >= MAX_OPERATIONS:
            fail('capacityExceeded', 'Operation capacity exhausted')
        s.pop('releaseProof', None)
        if r['kind'] in ('capture', 'release'):
            s['authority'], s['nodes'], s['undo'] = 'revoked', {}, {}
        s['highWater'] = r['sequence']
        s['operations'][r['operationID']] = {'kind': r['kind'], 'digest': digest(r), 'sequence': r['sequence'], 'state': 'reserved'}
        self.save()  # MUST precede child creation/target dispatch.
        return None

    def wire(self, capture_id):
        r, s = self.request, self.state
        if r['kind'] == 'capture' and r['targetEpoch'] is None:
            capture_id = s['captureID']
        wire = {**r, 'targetEpoch': s['epoch'], 'requestDigest': digest(r),
                'newCaptureID': capture_id, 'expiresAt': self.now() + TTL,
                'replaceAttemptedCaptureID': s.get('attemptedCaptureID')}
        if r['kind'] == 'capture' and r['targetEpoch'] is None and s.get('transition'):
            wire['transition'] = s['transition']
        if r['kind'] == 'capture':
            # Durable before dispatch; a later explicit refresh may retire either the
            # old or attempted generation after a lost capture response. Never busy-reset.
            s['attemptedCaptureID'] = capture_id
            s['expiresMonotonic'] = time.clock_gettime(time.CLOCK_MONOTONIC) + TTL
            self.save()
        if r['kind'] == 'revert':
            wire['undoReceipt'] = s['undo'][r['undoToken']]
        if r['kind'] == 'release':
            wire['releaseCaptureIDs'] = [v for v in (s['captureID'], s.get('attemptedCaptureID')) if v is not None]
            wire['entryTransitionID'] = (s.get('transition') or {}).get('transitionID')
        return wire

    def revoke(self):
        self.state['authority'] = 'quarantined'
        self.state['undo'] = {}
        self.save()

    def bind_wire(self, wire):
        """Persist the final internal wire before creating any transport child."""
        operation = self.state['operations'][self.request['operationID']]
        if operation['state'] != 'reserved' or 'wireDigest' in operation:
            fail('ownershipFailed', 'Wire binding requires a fresh reservation')
        operation['wireDigest'] = digest(wire)
        self.save()

    def finish(self, result):
        r, s = self.request, self.state
        op = r['operationID']
        # Cleanup uncertainty invalidates authority but NEVER erases observed mutation evidence.
        if (result.get('status') == 'success' and r['kind'] == 'capture'):
            s['captureID'], s['expiresAt'] = result['captureID'], result['editing']['expiresAt']
            s['nodes'] = {n['editToken']: {k: n[k] for k in ('parentToken', 'windowToken', 'className')}
                          for n in result['editableNodes']}
            s['authority'] = 'active'
            s.pop('attemptedCaptureID', None)
        elif result.get('needsRefresh') or result.get('status') not in ('success', 'noChange'):
            s['authority'], s['undo'] = 'quarantined', {}
        if r['kind'] == 'capture' and s['captureID'] is None:
            # Retain the issued ID even after a lost response so explicit refresh can
            # name the attempted generation; target busy is still never reset.
            s['captureID'] = result.get('captureID')
        if r['kind'] in ('edit', 'revert') and result.get('mutationOutcome') == 'appliedObserved':
            node, prop = result.get('nodeToken'), result.get('property')
            s['undo'] = {key: u for key, u in s['undo'].items() if (u['nodeToken'], u['property']) != (node, prop)}
            if result.get('undoReceipt') and s['authority'] == 'active':
                s['undo'][result['undoToken']] = result['undoReceipt']
                while len(s['undo']) > MAX_RESULTS:
                    del s['undo'][next(iter(s['undo']))]
        if r['kind'] == 'release':
            s['authority'], s['nodes'], s['undo'] = 'revoked', {}, {}
            result['authorityRevoked'] = True
            cleanup = result.get('cleanup', {})
            proof = result.get('releaseProof')
            if (result.get('status') == 'success' and result.get('registryReleased') is True
                    and release_proof_valid(proof) and cleanup.get('detach') == 'success'
                    and cleanup.get('childrenReaped') is True and cleanup.get('recovery', {}).get('verified') is True
                    and not cleanup.get('closeError')
                    and not any(v['state'] == 'reserved' for k, v in s['operations'].items() if k != op)):
                s['authority'], s['releaseProof'] = 'released', proof
                s.pop('attemptedCaptureID', None)
        s['operations'][op]['state'] = 'finished'
        # Capture result can be large: persist only the receipt; replay requires refresh.
        fields = {'schemaVersion', 'validationOnly', 'status', 'operationID', 'requestDigest', 'ownerID', 'inspectionID', 'targetEpoch',
                  'captureID', 'target', 'reasonCode', 'phase', 'mutationOutcome', 'setterEntered', 'before',
                  'requested', 'observed', 'undoToken', 'needsRefresh', 'propertyRevision', 'nodeToken', 'property',
                  'postcondition', 'authorityRevoked', 'registryReleased', 'remainingOwnedEntries', 'residualState', 'releaseProof', 'evidenceDirectory'}
        stored = {k: v for k, v in result.items() if k in fields}
        cleanup = result.get('cleanup', {})
        recovery = cleanup.get('recovery', {})
        stored['cleanup'] = {'detach': str(cleanup.get('detach', 'unknown'))[:512],
                             'childrenReaped': cleanup.get('childrenReaped', False),
                             'recovery': {'verified': recovery.get('verified', False),
                                          'error': str(recovery.get('error', ''))[:512]},
                             'closeError': str(cleanup.get('closeError') or '')[:512]}
        if len(canonical(stored)) > 16384:
            fail('capacityExceeded', 'Minimal durable receipt exceeds 16 KiB')
        if r['kind'] == 'capture' and stored.get('status') == 'success':
            stored.update(status='resultUnavailable', reasonCode='capturePayloadNotCached', needsRefresh=True)
        s['results'][op] = stored
        while len(s['results']) > MAX_RESULTS:
            del s['results'][next(iter(s['results']))]
        self.save()


def expression(wire, answer):
    # Caller strings are data inside base64 JSON; no selector, address or executable interpolation.
    return (HERE / 'edit.expr').read_text().replace('__OPERATION__', (HERE / 'operation.inc').read_text()).replace('__WIRE__', base64.b64encode(canonical(wire)).decode()) \
        .replace('__ANSWER_PATH__', json.dumps(str(answer)))


SWIFTUI_STARTUP = (
    'closure #1 (Swift.UnsafeMutablePointer<Swift.Optional<Swift.UnsafeMutablePointer<Swift.Int8>>>) -> Swift.Never in SwiftUI.KitRendererCommon(Swift.AnyObject.Type) -> Swift.Never',
    'SwiftUI.runApp<τ_0_0 where τ_0_0: SwiftUI.App>(τ_0_0) -> Swift.Never',
    'static SwiftUI.App.main() -> ()',
)


def swiftui_idle_entry(frames, executable, runtime):
    """Measured standard startup only; symbol provenance is read without evaluation.

    Bounded support: a top-level nominal App with ASCII module/type identifiers.
    LLDB's demangled symbol binds the compiler-generated mangled suffix to the
    actual frame PC and executable, including Swift mangling substitutions.
    """
    if len(frames) != 16 or not runtime or not runtime.endswith('/RuntimeRoot'):
        return False
    framework = runtime + '/System/Library/'
    expected = [(n, '/usr/lib/system/libsystem_kernel.dylib') for n in
                ('mach_msg2_trap', 'mach_msg2_internal', 'mach_msg_overwrite', 'mach_msg')]
    expected += [(n, framework + 'Frameworks/CoreFoundation.framework/CoreFoundation') for n in
                 ('__CFRunLoopServiceMachPort', '__CFRunLoopRun', '_CFRunLoopRunSpecificWithOptions')]
    expected += [('GSEventRunModal', framework + 'PrivateFrameworks/GraphicsServices.framework/GraphicsServices'),
                 ('UIApplicationMain', framework + 'PrivateFrameworks/UIKitCore.framework/UIKitCore')]
    expected += [(n, framework + 'Frameworks/SwiftUI.framework/SwiftUI') for n in SWIFTUI_STARTUP]
    generated = frames[12]
    name = generated.get('function', '')
    if not re.fullmatch(r'static [A-Za-z_][A-Za-z_0-9]{0,127}\.[A-Za-z_][A-Za-z_0-9]{0,127}\.\$main\(\) -> \(\)', name):
        return False
    proof = generated.get('symbol', {})
    if (proof.get('name') != name or proof.get('module') != executable or
            not re.fullmatch(r'\$s[A-Za-z_0-9$]{1,512}[VOC]5\$mainyyFZ', proof.get('mangled', ''))):
        return False
    values = [proof.get(k) for k in ('start', 'pc', 'end')]
    if not all(type(v) is int and 0 < v < 2**64 - 1 for v in values):
        return False
    if not values[0] <= values[1] < values[2]:
        return False
    expected += [(name, executable), ('main', executable),
                 ('start_sim', runtime + '/usr/lib/dyld_sim'), ('start', '/usr/lib/dyld')]
    return [(f.get('function'), f.get('module')) for f in frames] == expected


def safe_entry(frames, executable, runtime=None):
    """Conservative *candidate*, not qualified for arbitrary apps. No target evaluation."""
    if not 6 <= len(frames) <= 64:
        return False
    if swiftui_idle_entry(frames, executable, runtime):
        return True
    names = [f.get('function', '') for f in frames]
    # Require the kernel wait -> CF run-loop -> UIKit app runner -> fixture main chain.
    if names[0] not in ('mach_msg2_trap', 'mach_msg_trap'):
        return False
    required = ('__CFRunLoopServiceMachPort', '__CFRunLoopRun', 'CFRunLoopRunSpecific', 'UIApplicationMain', 'main')
    indices = []
    aliases = {'CFRunLoopRunSpecific': ('CFRunLoopRunSpecific', '_CFRunLoopRunSpecificWithOptions')}
    for name in required:
        found = [i for i, n in enumerate(names) if n in aliases.get(name, (name,))]
        if len(found) != 1:
            return False
        indices.append(found[0])
    if indices != sorted(indices):
        return False
    # UIApplicationMain owns the observed idle run loop. Its callers are startup
    # frames, not callbacks executing above that loop. Accept only the measured
    # fixture wrapper pair, contiguous with the same executable's main; arbitrary
    # Swift mains or app frames elsewhere remain outside this fixture policy.
    app_runner, app_main = indices[-2:]
    startup = [(f.get('function', ''), f.get('module', '')) for f in frames[app_runner + 1:app_main + 1]]
    c_startup = [('main', executable)]
    swift_startup = [
        ('static HierarchyFixture.FixtureEntry.main() -> ()', executable),
        ('static HierarchyFixture.FixtureEntry.$main() -> ()', executable),
        ('main', executable)]
    if startup not in (c_startup, swift_startup):
        return False
    loader = [(f.get('function', ''), f.get('module', '')) for f in frames[app_main + 1:]]
    host_loader = [('start', '/usr/lib/dyld')]
    ui_path = frames[app_runner].get('module', '')
    ui_suffix = '/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore'
    runtime = ui_path[:-len(ui_suffix)] if ui_path.endswith(ui_suffix) else ''
    sim_loader = [('start_sim', runtime + '/usr/lib/dyld_sim'), *host_loader]
    measured_sim_loader = runtime.endswith('/RuntimeRoot') and loader == sim_loader
    if not (measured_sim_loader or startup == c_startup and loader == host_loader):
        return False
    allowed = {
        'libsystem_kernel.dylib': {'mach_msg2_trap', 'mach_msg_trap', 'mach_msg2_internal', 'mach_msg_overwrite', 'mach_msg'},
        'CoreFoundation': {'__CFRunLoopServiceMachPort', '__CFRunLoopRun', 'CFRunLoopRunSpecific', '_CFRunLoopRunSpecificWithOptions'},
        'GraphicsServices': {'GSEventRunModal'},
        'UIKitCore': {'UIApplicationMain', '-[UIApplication _run]'},
    }
    for f in frames[:app_runner + 1]:
        path, name = f.get('module', ''), f.get('function', '')
        if not (path.startswith('/usr/lib/') or path.startswith('/System/Library/')
                or '/RuntimeRoot/usr/lib/' in path or '/RuntimeRoot/System/Library/' in path):
            return False
        if name not in allowed.get(Path(path).name, set()):
            return False
    return True


def validate_payload(payload, wire):
    """Validate the actual target receipt before it may grant host authority."""
    try:
        return _validate_payload(payload, wire)
    except BackendError as error:
        if error.status == 'invalidRequest':
            fail('invalidResponse', str(error))
        raise
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        fail('invalidResponse', 'Malformed target receipt: ' + str(error)[:512])


def _validate_payload(payload, wire):
    if type(payload) is not dict:
        fail('invalidResponse', 'Target receipt is not an object')
    for key in ('operationID', 'requestDigest', 'ownerID', 'inspectionID', 'targetEpoch'):
        if payload.get(key) != wire[key]:
            fail('invalidResponse', 'Target receipt identity mismatch: ' + key)
    statuses = {'success', 'noChange', 'rejected', 'conflict', 'expired', 'busy', 'outcomeUncertain',
                'resultUnavailable', 'undoConflict', 'keyCollision', 'ownershipConflict', 'capacityExceeded', 'unsupported', 'failed'}
    if (payload.get('status') not in statuses or type(payload.get('reasonCode')) is not str
            or len(payload['reasonCode'].encode()) > 512):
        fail('invalidResponse', 'Invalid target status/reason')
    if type(payload.get('setterEntered')) is not bool or type(payload.get('needsRefresh')) is not bool:
        fail('invalidResponse', 'Target receipt flags are invalid')
    if payload.get('mutationOutcome') not in ('notEntered', 'appliedObserved', 'enteredUnverified', 'uncertain', 'notApplicable'):
        fail('invalidResponse', 'Target outcome is invalid')
    if wire['kind'] == 'release' and payload['status'] == 'success':
        proof = payload.get('releaseProof')
        if (not release_proof_valid(proof)
                or any(proof[k] != wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch', 'operationID', 'requestDigest', 'sequence', 'entryTransitionID'))
                or proof['captureID'] not in wire['releaseCaptureIDs']
                or payload.get('registryReleased') is not True or payload.get('authorityRevoked') is not True
                or type(payload.get('remainingOwnedEntries')) is not int or payload['remainingOwnedEntries'] != 0
                or payload.get('residualState') != 'tombstone'
                or payload['setterEntered'] or payload['mutationOutcome'] != 'notApplicable'):
            fail('invalidResponse', 'Release lacks an exact target retirement receipt')
    if payload['mutationOutcome'] == 'appliedObserved':
        prop = payload.get('property')
        if prop not in ('hidden', 'alpha') or scalar(prop, payload.get('requested')) != scalar(prop, payload.get('observed')):
            fail('invalidResponse', 'Applied receipt lacks exact typed readback')
        if payload.get('status') != 'success' or not payload['setterEntered']:
            fail('invalidResponse', 'Applied outcome lacks completed setter evidence')
        binding = wire.get('undoReceipt') if wire['kind'] == 'revert' else wire
        if (not isinstance(binding, dict) or payload.get('nodeToken') != binding.get('nodeToken')
                or prop != binding.get('property')
                or scalar(prop, payload['before']) != scalar(prop, binding['applied' if wire['kind'] == 'revert' else 'expectedValue'])
                or scalar(prop, payload['requested']) != scalar(prop, binding['before' if wire['kind'] == 'revert' else 'value'])):
            fail('invalidResponse', 'Applied receipt differs from the reserved operation')
        u = payload.get('undoReceipt')
        if u is not None:
            identifier(payload.get('undoToken'))
            required = {'nodeToken', 'property', 'before', 'applied', 'revision', 'expectedParentToken', 'expectedWindowToken', 'expectedClass'}
            if (wire['kind'] != 'edit' or type(u) is not dict or set(u) != required
                    or any(u[k] != wire[k] for k in ('nodeToken', 'property', 'expectedParentToken', 'expectedWindowToken', 'expectedClass'))
                    or u['revision'] != wire['sequence'] or type(u['revision']) is not int
                    or scalar(prop, u['before']) != scalar(prop, payload['before'])
                    or scalar(prop, u['applied']) != scalar(prop, payload['observed'])):
                fail('invalidResponse', 'Undo receipt does not bind the applied operation')
    if wire['kind'] == 'capture' and payload.get('status') == 'success':
        nodes = payload.get('editableNodes')
        editing = payload.get('editing')
        if (type(nodes) is not list or not 0 < len(nodes) <= MAX_NODES or type(editing) is not dict
                or payload.get('captureID') != wire['newCaptureID'] or editing.get('registryState') != 'active'
                or editing.get('expiresAt') != wire['expiresAt']
                or type(payload.get('captureTime')) is not str or not 1 <= len(payload['captureTime']) <= 64
                or any(editing.get(k) != wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch'))):
            fail('invalidResponse', 'Malformed owned editable capture')
        by_id = {}
        for n in nodes:
            if type(n) is not dict:
                fail('invalidResponse', 'Malformed editable node')
            identifier(n.get('editToken'))
            if (n['editToken'] in by_id or n.get('id') != n['editToken']
                    or type(n.get('className')) is not str or not 1 <= len(n['className'].encode()) <= 512
                    or type(n.get('siblingIndex')) is not int or not 0 <= n['siblingIndex'] <= MAX_NODES):
                fail('invalidResponse', 'Duplicate token or invalid class')
            by_id[n['editToken']] = n
            scalar('hidden', n.get('hidden')); scalar('alpha', n.get('alpha'))
        for n in nodes:
            if n.get('windowToken') not in by_id or (n.get('parentToken') is not None and n['parentToken'] not in by_id):
                fail('invalidResponse', 'Missing graph token')
            seen = set(); current = n
            while current.get('parentToken') is not None:
                token = current['parentToken']
                if token in seen or len(seen) >= 512:
                    fail('invalidResponse', 'Cyclic/deep editable graph')
                seen.add(token); current = by_id[token]
            if current['editToken'] != n['windowToken']:
                fail('invalidResponse', 'Window ancestry mismatch')
        if 'hierarchy' in payload:
            joins = payload.get('textureJoins')
            texture = payload.get('textureCapture')
            if (type(payload['hierarchy']) is not dict or type(joins) is not dict or len(joins) != len(nodes)
                    or type(texture) is not dict or texture.get('sameOperationIdentity') is not True):
                fail('invalidResponse', 'Texture result lacks same-operation identity')
            joined = set()
            for address, binding in joins.items():
                if (type(address) is not str or not address.startswith('0x') or len(address) > 32
                        or type(binding) is not dict or set(binding) != {'nodeToken', 'className', 'parentAddress'}
                        or binding['nodeToken'] not in by_id or binding['nodeToken'] in joined):
                    fail('invalidResponse', 'Malformed or ambiguous texture identity join')
                joined.add(binding['nodeToken'])
                node = by_id[binding['nodeToken']]
                parent = joins.get(binding['parentAddress']) if binding['parentAddress'] is not None else None
                if (binding['className'] != node['className']
                        or (parent.get('nodeToken') if isinstance(parent, dict) else None) != node['parentToken']):
                    fail('invalidResponse', 'Texture class/parent differs from registry capture')
    return payload
