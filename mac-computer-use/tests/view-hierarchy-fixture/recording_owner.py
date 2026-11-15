"""Session/observer bridge for one explicit owned-fixture recording action.

Worker owns fixture controls. Parent owns target cursor publication. UI writes
readiness/action evidence only. These files do not authenticate a conversation.
"""
import json
import errno
import os
from pathlib import Path
import time

import recording_session as fixture
import ui_capture_contract as a
import ui_recording_contract as recording


def read_optional(path):
    try: return a.read_json(path, [], limit=65536)
    except a.ContractError as error:
        if isinstance(error.__cause__, FileNotFoundError): return None
        raise


def boot(scope):
    device, pid, seconds, micros, path = scope['bootIdentity'].split(':', 4)
    return dict(deviceID=device, pid=int(pid), start=[int(seconds),int(micros)], path=path)


def same_native(first, second):
    return all(first.get(k) == second.get(k) for k in ('pid','start','parent','group','path'))


def native_absent(session, observation, pid, expected=None):
    """Two ESRCH reads plus kill0; zombie/denied/reused PID is never absence."""
    def status():
        observation.check()
        try: value = session.watchdog.process_status(pid)
        except session.watchdog.IdentityReadError as error:
            observation.check()
            return error.errno == errno.ESRCH and error.identity is None
        observation.check()
        if expected is not None:
            a.require(value['start'] == expected['start'], 'recording PID reused')
        return False
    if not status(): return False
    try: os.kill(pid, 0)
    except ProcessLookupError: observation.record(pid, 'kill0', -1, errno.ESRCH)
    except OSError as error:
        observation.record(pid, 'kill0', -1, error.errno); return False
    else:
        observation.record(pid, 'kill0', 0, 0); return False
    return status()


class Worker:
    def __init__(self, session, out, target, data, claim, deadline, check):
        self.s, self.out, self.target, self.claim = session, Path(out), target, claim
        self.deadline, self.check = deadline, check
        self.installation = fixture.Installation.read(target, data, session.BUNDLE)
        self.binding = a.read_json(self.out / 'target-observation.json', [])
        self.arm, self.ready = None, None
        self.parent = session.watchdog.lifetime(session.watchdog.process_identity(os.getppid()))

    def fresh(self, old=True):
        self.check(); self.claim.check(); self.installation.recheck()
        a.require(self.s.monotonic() < self.deadline, 'original recording deadline exhausted')
        probe = self.s.capture.ProcessProbe()
        expected_boot = boot(self.ready['scope']) if self.ready else dict(deviceID=self.target['deviceID'],
            **{k:self.binding['originalParent'][k] for k in ('pid','start','path')})
        self.s.capture.verify_target(probe, expected_boot)
        if old: self.s.capture.verify_target(probe, self.target)

    def tick(self):
        """One nonblocking service step; never starts recording or invokes UI."""
        ready = read_optional(self.out / 'recording-ready.json')
        if ready is None: return
        if self.ready is None:
            a.require(set(ready) == {'target','scope','captureID','ownerID','inspectionID','epoch','selector','disclosure'} and
                      ready['target'] == self.target and ready['selector'] == 'prepareRecordingNow' and
                      ready['disclosure'] == '현재 실행 상태가 사라집니다. 기존 실행 인자와 환경 변수는 복원되지 않습니다.',
                      'production button readiness differs')
            self.ready = ready; self.fresh()
            self.arm = fixture.Arm(session=self.binding['owner'], target=self.target, installation=self.installation,
                deadline=self.deadline, check=lambda:self.fresh(), clock=self.s.monotonic)
            self.arm.arm()
        else: a.require(ready == self.ready, 'recording readiness changed')
        if self.arm.state == 'arming':
            oracle = a.read_json(Path(self.installation.identity['dataRealpath']) / 'Documents/edit-oracle.json', [], private=False)
            if self.arm.acknowledge(oracle):
                declaration = dict(version=1, binding=self.binding, ready=self.ready, parent=self.parent,
                    installation=self.installation.wire(), claim=self.claim.owner, claimPath=str(self.claim.path),
                    deadline=self.deadline, expires=self.arm.expires, restartID=self.arm.restart_id,
                    receipt=self.arm.receipt)
                fixture.private_write(self.out / 'recording-session.json', declaration)
        if self.arm.state == 'armed' and read_optional(self.out / 'recording-owner-ready.json') is not None:
            ack = read_optional(self.out / 'recording-owner-ready.json')
            a.require(ack == dict(restartID=self.arm.restart_id, parent=self.parent, revision=0), 'recording owner acknowledgement differs')
            self.arm.dispatch()
            fixture.private_write(self.out / 'recording-click-ready.json', dict(restartID=self.arm.restart_id,
                pendingSHA256=self.arm.pending_pin.sha256, revision=0))

    def cancel_before_dispatch(self):
        if self.arm is None or self.arm.state == 'cancelled': return True
        if self.arm.state == 'dispatchUnknown': return False
        oracle = a.read_json(Path(self.installation.identity['dataRealpath']) / 'Documents/edit-oracle.json', [], private=False)
        if self.arm.state == 'arming' and not self.arm.acknowledge(oracle): return False
        if self.arm.state == 'armed': self.arm.cancel(); return False
        return self.arm.state == 'cancelling' and self.arm.cancelled(oracle)

    def admitted(self):
        value = read_optional(self.out / 'recording-cursor.json')
        a.require(value is not None and value['parent'] == self.parent and value['original'] == self.binding and
                  value['revision'] == 1 and value['phase'] == 'admitted', 'successor not independently admitted')
        a.require(value['acceptedMonotonic'] < value['observationCutoff'] <= value['acceptedMonotonic'] + 3 and
                  value['acceptedMonotonic'] < self.deadline, 'successor acceptance cutoff differs')
        a.require(self.s.watchdog.lifetime(self.s.watchdog.process_identity(self.parent['pid'])) == self.parent,
                  'cursor publisher lifetime changed')
        self.fresh(old=False)
        binding = self.s.watchdog.validate_target_binding(value['binding'], value['binding']['target'],
                                                          self.binding['worker'], self.binding['owner'])
        self.s.capture.verify_target(self.s.capture.ProcessProbe(), binding['target'])
        return binding

    def cleanup_binding(self):
        # A UI-written target/result never replaces session cleanup identity.
        value = read_optional(self.out / 'recording-cursor.json')
        if value is not None:
            binding = self.admitted()
        else:
            a.require(self.arm is None or self.arm.state == 'cancelled', 'unknown launch/arm custody at cleanup')
            self.fresh()
            binding = self.binding
        self.installation.recheck(); self.claim.check()
        import ui_process_contract
        spec = self.s.UI_PROCESS_CONTRACT
        build = a.read_json(Path(spec['capture']).parent / 'resident-build.json', [], private=False)
        framework = Path(build['developer']).parent / 'SharedFrameworks/LLDB.framework'
        python = str((Path(build['developer']) / 'usr/bin/python3').resolve())
        contract = ui_process_contract.Contract(spec, (python,), str((framework/'Resources/debugserver').resolve()),
                                               binding['target'], binding, self.check)
        prepared = contract.prepared(python)
        root = Path.home() / 'Library/Application Support/mac-cu/view-edit-ledger'
        histories = [self.binding] + ([binding] if binding != self.binding else [])
        for history in histories:
            recording.released_ledger(prepared, history['target'], root, spec['temporary'])
        if binding == self.binding:
            marker = root / (a.digest(a.canonical(self.target).encode()) + '.recording')
            a.require(read_optional(marker) is None, 'dispatch intent prevents pre-dispatch cleanup')
        # UI/helper disappearance alone cannot authorize a target stop.
        observation = self.s.watchdog.ProcessObservation(self.s.monotonic, self.deadline, self.check)
        rows = self.s.watchdog.rows(timeout=max(.001, observation.cutoff-self.s.monotonic()))
        observation.check()
        members = self.s.watchdog.session_members(rows, self.binding['worker']['pid'])
        a.require(not members, 'UI/transport/launch child remains at cleanup')
        a.require(not any(r[3] == spec['binary'] for r in rows), 'UI executable remains outside worker family')
        if value is not None:
            custody = value['custody']
            keys = [(v['pid'],v['start']) for v in (custody['helper'],custody['ui'])]
            keys += [v for v in (custody['launch'],custody['reconciliation']) if v is not None]
            for pid, start in keys:
                a.require(native_absent(self.s, observation, pid, dict(start=list(start))) and
                          not any(r[0] == pid for r in rows), 'retained native custody remains at cleanup')
        a.require([r[0] for r in rows if r[3] == binding['target']['path']] == [binding['target']['pid']],
                  'cleanup target inventory ambiguous')
        if binding != self.binding:
            a.require(self.s.residual(self.s.capture.ProcessProbe(), self.target)['state'] == 'gone',
                      'old lifetime is not independently gone at cleanup')
        self.fresh(old=binding == self.binding)
        self.s.capture.verify_target(self.s.capture.ProcessProbe(), binding['target'])
        observation.check()
        return binding


class Owner:
    """Persistent parent state; installed into every bounded ProcessObservation."""
    def __init__(self, session, out, declaration, binding, check, clock=time.monotonic):
        self.s, self.out, self.declaration, self.clock = session, Path(out), declaration, clock
        self.input_check = check
        a.require(declaration['version'] == 1 and declaration['binding'] == binding, 'recording declaration binding differs')
        self.ready = declaration['ready']
        self.installation = fixture.Installation.read(binding['target'], declaration['installation']['identity']['dataRealpath'],
                                                      declaration['installation']['identity']['bundleID'])
        a.require(self.installation.wire() == declaration['installation'], 'recording installation pins differ')
        self.parent = declaration['parent']
        a.require(self.parent == session.watchdog.lifetime(session.watchdog.process_identity(os.getpid())),
                  'recording parent identity differs')
        self.cursor = recording.TargetCursor(binding, self.ready['scope'], self.check, self.publish)
        self.check()
        a.require(boot(self.ready['scope']) == dict(deviceID=binding['target']['deviceID'],
                  **{k:binding['originalParent'][k] for k in ('pid','start','path')}), 'boot and original native parent differ')
        pending = a.read_json(Path(self.installation.identity['dataRealpath']) / '.recording-entry-v1/restart.pending.json', [], limit=8192)
        raw, _ = a.read_file(Path(self.installation.identity['dataRealpath']) / '.recording-entry-v1/restart.pending.json', limit=8192)
        receipt = declaration['receipt']
        a.require(receipt['status'] == 'armed' and receipt['restartID'] == declaration['restartID'] and
                  receipt['pending'] == pending and receipt['pendingSHA256'] == a.digest(raw), 'owner arm readback differs')
        fixture.private_write(self.out / 'recording-owner-ready.json', dict(restartID=declaration['restartID'], parent=self.parent, revision=0))

    def check(self):
        self.input_check()
        a.require(self.clock() < self.declaration['deadline'], 'original host recording deadline exhausted')
        self.installation.recheck()
        a.require(read_optional(self.out / 'recording-session.json') == self.declaration, 'recording declaration changed')
        a.require(read_optional(self.out / 'recording-ready.json') == self.ready, 'recording readiness changed')
        claims = a.read_json(self.declaration['claimPath'], [], private=False)
        selected = [v for k,v in claims.items() if k.upper() == self.cursor.original['target']['deviceID']]
        a.require(selected == [self.declaration['claim']], 'exact held claim changed')
        w = self.s.watchdog
        a.require(w.lifetime(w.process_identity(self.parent['pid'])) == self.parent and
                  w.lifetime(w.process_identity(self.cursor.original['worker']['pid'])) == self.cursor.original['worker'],
                  'recording owner lifetime changed')
        self.s.capture.verify_target(self.s.capture.ProcessProbe(), boot(self.cursor.scope))

    def publish(self, value):
        key = a.digest(a.canonical(value['binding']['target']).encode())
        ledger = str(Path(self.cursor.preparation.marker).parent / (key + '.json'))
        c = self.cursor
        custody = dict(helper=c.helper, ui=c.ui, launch=c.launch_key, reconciliation=c.reconcile_key)
        fixture.private_write(self.out / 'recording-cursor.json', dict(value, parent=self.parent, ledger=ledger, custody=custody))

    def commit(self, observation):
        c = self.cursor
        if c.pending_publication is None or c.published or c.revision != 0: return
        self.check(); observation.check()
        accepted = observation.clock()
        a.require(accepted < observation.cutoff, 'recording publication crossed observation cutoff')
        # All native/semantic/global checks have accepted before bounded file
        # publication. No further native reads are accepted after this point.
        c.commit(accepted, observation.cutoff)
        if c.phase == 'admitted':
            observation.target, observation.target_binding = c.binding['target'], c.binding
            if observation.ui_process:
                observation.ui_process.target, observation.ui_process.target_binding = c.binding['target'], c.binding
        observation.events.append(dict(status='verifiedRecordingAdmission', phase=c.phase,
            acceptedMonotonic=accepted, cutoff=observation.cutoff, signalAuthority=False))

    def action(self):
        value = read_optional(self.out / 'recording-action.json')
        a.require(value is not None and value['restartID'] == self.declaration['restartID'] and
                  value['selector'] == 'prepareRecordingNow' and value['method'] == 'NSButton.performClick' and
                  value['target'] == self.cursor.original['target'] and value['enabled'] is True and
                  value['visible'] is True and value['controllerTarget'] is True and
                  value['physicalClick'] is False, 'actual action provenance absent/different')
        return value

    def verify_release_join(self):
        state = json.loads(self.cursor.preparation.release.state_json)
        a.require(all(state[k] == self.ready[v] for k,v in
                  (('ownerID','ownerID'),('inspectionID','inspectionID'),('epoch','epoch'),('captureID','captureID'))),
                  'released ledger does not join initial UI capture')
        self.action()

    def absent(self, observation, pid, expected=None):
        return native_absent(self.s, observation, pid, expected)

    def settle(self, observation, snapshot):
        c = self.cursor
        if c.preparation is None: return
        self.verify_release_join(); c.marker()
        for expected in (c.helper, c.ui):
            if not self.absent(observation, expected['pid'], expected):
                actual = observation.read_bound_identity(expected['pid'])
                a.require(same_native(actual,expected), 'recording helper/UI native lifetime or parent changed')
        if c.launch_key is not None and not c.launch_settled:
            pid, start = c.launch_key
            if self.absent(observation, pid, {'start':list(start)}):
                a.require(not any(r[0] == pid for r in snapshot), 'launch absent/native snapshot disagrees')
                c.tool_settled(c.launch_key)
        if not c.helper_settled and self.absent(observation, c.helper['pid'], c.helper):
            a.require(not any(r[0] == c.helper['pid'] for r in snapshot), 'helper absent/native snapshot disagrees')
            c.helper_settled = True
        if c.helper_settled: c.read_result()

    def resolve(self, observation, snapshot, group):
        """Called inside the observer's existing cutoff; no wait or dispatch."""
        c, w = self.cursor, self.s.watchdog
        self.check(); observation.check()
        if c.phase in ('original','admitted'):
            return None
        self.verify_release_join(); c.marker()
        old = c.original['target']
        if c.phase == 'preparing':
            if c.marker_stage == 'admission': return None
            if not self.absent(observation, old['pid'], old):
                try:
                    state = w.process_status(old['pid'])
                    if state['state'] == 5: return False
                except w.IdentityReadError: return False
                return None
            # An independently observed empty interval is required. Do not infer
            # an exited gap merely from a successor row or preparation result.
            if any(r[0] == old['pid'] for r in snapshot): return False
            a.require(not any(r[3] == old['path'] for r in snapshot), 'successor appeared before exited gap proof')
            c.exited()
            observation.events.append(dict(status='verifiedRecordingGap', target=old, signalAuthority=False))
        a.require(self.absent(observation, old['pid'], old), 'old lifetime no longer absent')
        self.settle(observation, snapshot)
        rows = [r for r in snapshot if r[3] == old['path']]
        a.require(len(rows) <= 1, 'ambiguous extra successor instance')
        if rows:
            a.require(c.launch_key is not None and c.marker_stage == 'launchDispatch', 'candidate before bound launch')
            row = rows[0]
            a.require(row[0] != old['pid'], 'same PID successor refused')
            first = observation.read_bound_identity(row[0])
            actual = observation.target_reader(row[0], device=True)
            new = {k:actual[k] for k in old}
            a.require(new['path'] == old['path'] and new['deviceID'] == old['deviceID'] and
                      all(first[k] == new[k] for k in ('pid','start','path')) and
                      new['start'] != old['start'] and actual.get('traced') is False and
                      actual.get('state') in (2,3) and actual.get('parent') == first['parent'], 'successor native/device differs')
            parent = observation.read_bound_identity(first['parent'])
            worker = observation.read_bound_identity(group)
            a.require(w.lifetime(parent) == c.original['originalParent'] and
                      w.lifetime(worker) == c.original['worker'] and row[1:3] == (first['parent'],first['group']),
                      'successor native owner/parent/group differs')
            self.installation.recheck()
            module = recording.product(c.preparation.prepared)
            a.require(module.recording_enabled(self.s.capture.ProcessProbe(), new['pid']), 'successor env287 missing')
            again = observation.target_reader(row[0], device=True)
            a.require(all(again.get(k) == actual.get(k) for k in ('pid','start','path','deviceID','parent','traced')) and
                      again.get('state') in (2,3) and same_native(first,observation.read_bound_identity(row[0])) and
                      w.lifetime(parent) == w.lifetime(observation.read_bound_identity(parent['pid'])) and
                      w.lifetime(worker) == w.lifetime(observation.read_bound_identity(group)), 'successor changed during native read')
            binding = dict(c.original, target=new, group=first['group'])
            a.require(c.candidate in (None,binding), 'successor candidate changed')
            c.candidate = binding; c.phase = 'candidate' if c.revision == 0 else c.phase
            # Candidate is custody even before result/consumption publication.
            # A successful capture lane also requires the exact consumed capsule.
            try: startup = self.startup_receipt(new)
            except a.ContractError as error:
                if not isinstance(error.__cause__, FileNotFoundError): raise
                startup = None
            if c.launch_settled and c.helper_settled and not c.published and c.revision == 0:
                c.uncertain |= self.clock() >= self.declaration['expires']
                if self.absent(observation, c.ui['pid'], c.ui): c.uncertain = True
                else:
                    a.require(same_native(c.ui, observation.read_bound_identity(c.ui['pid'])), 'UI owner lifetime changed')
                c.admit(binding, startup)
            if c.phase == 'admitted':
                observation.target, observation.target_binding = new, binding
                if observation.ui_process:
                    observation.ui_process.target, observation.ui_process.target_binding = new, binding
            observation.events.append(dict(status='verifiedRecordingCandidate', binding=binding,
                captureEligible=c.phase == 'admitted', signalAuthority=False))
        observation.check()
        observation.target_valid = True  # Custody-role proof; capture gate is cursor.phase.
        return True

    def startup_receipt(self, target):
        directory = Path(self.installation.identity['dataRealpath'])
        pending = self.declaration['receipt']['pending']
        consumed, raw, _ = fixture.read_control(directory / '.recording-entry-v1/restart.consumed.json')
        a.require(consumed == pending and a.digest(raw) == self.declaration['receipt']['pendingSHA256'],
                  'consumed pending bytes differ')
        # Spent is a durable existence fence; neither cleanup nor admission deletes it.
        a.read_file(directory / '.recording-entry-v1/restart.spent', limit=8192)
        oracle = a.read_json(directory / 'Documents/edit-oracle.json', [], private=False)
        startup = {k:oracle[k] for k in ('startupMode','restartID','oldTarget','currentPID')}
        if startup == dict(startupMode='initial', restartID=None, oldTarget=pending['oldTarget'],
                           currentPID=self.cursor.original['target']['pid']):
            return None  # Retained old oracle is evidence, not successor acceptance.
        a.require(startup == dict(startupMode='recordingRestart', restartID=self.declaration['restartID'],
                                  oldTarget=pending['oldTarget'], currentPID=target['pid']) and
                  oracle.get('graphOracleCalls') == 0, 'successor fixture startup differs')
        return startup

    def cleanup_binding(self):
        a.require(self.cursor.phase == 'admitted', 'unknown launch custody cannot retire original target')
        self.check()
        return self.cursor.binding
