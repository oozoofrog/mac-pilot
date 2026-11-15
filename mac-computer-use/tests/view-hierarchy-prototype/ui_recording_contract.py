"""Read-only production preparation binding and owner-held transition custody.

No launch or signal authority. ProcessObservation supplies native observations
under its unchanged three-second cutoff; session owns the cursor across reads.
"""
from dataclasses import dataclass
import importlib.util
import json
from pathlib import Path
import re
import sys
import uuid
import ui_capture_contract as a


@dataclass(frozen=True)
class Transition:
    old: str
    scope: str
    state: str = 'awaiting-original-exit'
    new: str = ''

    @classmethod
    @a.checked
    def begin(cls, *, original, scope, request, marker, release_verified, native_original):
        a.identity(native_original)
        a.require(set(original) == {'pid','start','path','deviceID'} and
                  all(native_original[k] == v for k,v in original.items()), 'original native lifetime differs')
        a.require(set(request) == {'explicitClick','target','scope'} and request['explicitClick'] is True and
                  request['target'] == original and request['scope'] == scope, 'explicit action differs')
        a.require(set(scope) == {'deviceID','bootIdentity','presentation','generation','runtime'} and
                  scope['deviceID'] == original['deviceID'] and type(scope['generation']) is int and
                  scope['generation'] >= 0 and all(isinstance(scope[k],str) and scope[k] for k in
                  ('deviceID','bootIdentity','presentation','runtime')), 'typed scope differs')
        a.require(marker == {'stage':'terminationDispatch','target':original} and release_verified is True,
                  'durable dispatch or independently verified release missing')
        return cls(a.canonical(original),a.canonical(scope))

    @a.checked
    def original_exited(self, read_exit, check):
        a.require(self.state == 'awaiting-original-exit', 'invalid transition state')
        check()
        # Native exit observation must bind the entire old lifetime. Missing or
        # unreadable status is not an exit receipt. No result.json input exists.
        old=json.loads(self.old)
        evidence=read_exit(old)
        a.require(evidence == {'target':old,'exited':True}, 'original exit is not independently verified')
        check()
        return Transition(self.old,self.scope,'awaiting-reconciliation')

    @a.checked
    def reconcile(self, *, candidate, read_native, read_scope, reconcile_containers, check):
        a.require(self.state == 'awaiting-reconciliation', 'original exit required')
        old=json.loads(self.old); scope=json.loads(self.scope)
        a.require(set(candidate)==set(old), 'new target shape differs')
        check(); before=read_native(candidate['pid']); a.identity(before)
        a.require(before.get('state') in (2,3) and before.get('traced') is False and
                  all(before.get(k)==v for k,v in candidate.items()), 'new native lifetime differs')
        a.require(candidate['path']==old['path'] and candidate['deviceID']==old['deviceID'] and
                  candidate['start']!=old['start'], 'new app/device/lifetime differs')
        a.require(read_scope()==scope, 'boot or presentation scope changed')
        a.require(reconcile_containers(candidate) is True, 'independent app/data reconciliation missing')
        after=read_native(candidate['pid'])
        a.require(after==before, 'new lifetime changed during reconciliation')
        check()
        return Transition(self.old,self.scope,'reconciled',a.canonical(candidate))

    def stop_unknown(self):
        return Transition(self.old,self.scope,'unknown')


def product(prepared):
    # These modules are pinned preparation inputs. Importing does not initialize
    # ProcessProbe, LLDB, a ledger lock, or any target state.
    resource = Path(prepared.capture_resource)
    def load(name, file):
        spec = importlib.util.spec_from_file_location(name, resource / file)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module
    # Bind dependencies to these prepared bytes even if the parent already
    # imported canonical source. Imports perform no ProcessProbe/ledger creation.
    saved = {name:sys.modules.get(name) for name in ('capture','edit_backend','resident_support')}
    try:
        capture = load('_recording_capture_schema', 'capture.py')
        sys.modules.update(capture=capture, edit_backend=capture.edit_backend)
        sys.modules['resident_support'] = load('_recording_resident_schema', 'resident_support.py')
        return load('_ui_recording_schema', 'recording_preparation.py')
    finally:
        for name, module in saved.items():
            if module is None: sys.modules.pop(name, None)
            else: sys.modules[name] = module


@dataclass(frozen=True)
class Release:
    state_json: str
    files: tuple


@a.checked
def released_ledger(prepared, target, root, temporary):
    """Read actual Ledger.read validation, without its mutating constructor/lock.

Join every retained compact result to the full request/wire/result and native
transport cleanup. Compact cleanup alone is not quiescence evidence.
"""
    module = product(prepared)
    path = Path(root) / (module.edit_backend.digest(target) + '.json')
    pins = []
    value = a.read_json(path, pins, limit=32*1024*1024)
    a.require(a.canonical(value['target']) == a.canonical(target), 'released ledger target wire differs')
    reader = object.__new__(module.edit_backend.Ledger)
    reader.request, reader.path = {'target':target}, path
    a.require(reader.read() == value and value['authority'] == 'released', 'actual released ledger required')
    a.require(value['operations'] and set(value['operations']) == set(value['results']), 'full operation history required')
    for operation_id, operation in value['operations'].items():
        stored = value['results'][operation_id]
        folder = private_folder(Path(stored['evidenceDirectory']), temporary)
        request = a.read_json(folder / 'request.json', pins)
        wire = a.read_json(folder / 'wire.json', pins)
        result = a.read_json(folder / 'result.json', pins, limit=16*1024*1024)
        a.schema2(request, prepared)
        digest = a.digest(a.canonical(request).encode())
        a.require(operation['state'] == 'finished' and operation['kind'] == request['kind'] and
                  operation['sequence'] == request['sequence'] and operation['digest'] == digest and
                  operation.get('wireDigest') == a.digest(a.canonical(wire).encode()), 'released request/wire differs')
        for item in (stored, result, wire):
            a.require(item['operationID'] == operation_id and item['requestDigest'] == digest and
                      item['target'] == target and item['ownerID'] == value['ownerID'] and
                      item['inspectionID'] == value['inspectionID'] and item['targetEpoch'] == value['epoch'] and
                      item['validationOnly'] is False, 'released receipt ownership/epoch differs')
        a.require(request['target'] == target and request['operationID'] == operation_id and
                  request['ownerID'] == value['ownerID'] and request['inspectionID'] == value['inspectionID'] and
                  request['targetEpoch'] in (None, value['epoch']) and request['validationOnly'] is False,
                  'released request ownership differs')
        a.require(all(wire.get(k) == v for k,v in request.items() if k != 'targetEpoch') and
                  wire['requestDigest'] == digest, 'released final wire changed request')
        cleanup = result['cleanup']
        a.require(cleanup.get('detach') == 'success' and cleanup.get('childrenReaped') is True and
                  cleanup.get('debuggerClosed') is True and cleanup.get('activeCall') is None and
                  'activeCall' in cleanup and cleanup.get('custodyRequired') is not True and
                  cleanup.get('recovery',{}).get('verified') is True and not cleanup.get('closeError'),
                  'full receipt lacks native quiescence')
        if operation_id == value['releaseProof']['operationID']:
            a.require(result.get('releaseProof') == value['releaseProof'] and result.get('status') == 'success' and
                      result.get('registryReleased') is True and result.get('remainingOwnedEntries') == 0 and
                      result.get('residualState') == 'tombstone', 'full terminal release differs')
    release = Release(a.canonical(value), tuple(pins)); a.revalidate(release); return release


def private_folder(folder, temporary):
    folder = a.absolute(folder)
    a.require(folder.parent == a.absolute(temporary) and
              re.fullmatch(r'mac-cu-views-[0-9A-Fa-f-]{36}', folder.name) is not None, 'preparation folder scope')
    uuid.UUID(folder.name[len('mac-cu-views-'):])
    info = folder.lstat()
    import stat, os
    a.require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077
              and folder.resolve() == folder, 'preparation directory must be private/canonical')
    return folder


@dataclass(frozen=True)
class Preparation:
    prepared: a.Prepared
    request_json: str
    supervisor_json: str
    folder: str
    app: str
    data: str
    bundle: str
    marker: str
    release: Release
    files: tuple

    def admission_commands(self):
        # The actual resident_support.admit calls are the supervisor read-only
        # subset. No resident worker, injected image or debugger is started.
        proxy = a.CaptureBinding(self.prepared, self.folder, self.request_json, self.supervisor_json,
                                self.app, self.data, self.bundle, ())
        return proxy.commands('supervisor')[:-1]

    def launch(self):
        return ('/usr/bin/xcrun','simctl','launch',json.loads(self.request_json)['target']['deviceID'],self.bundle)

    def reconcile(self):
        return ('/usr/bin/xcrun','simctl','spawn',json.loads(self.request_json)['target']['deviceID'],'launchctl','list')

    def stage(self):
        path = Path(self.marker)
        try: value = a.read_json(path, [])
        except a.ContractError as error:
            if isinstance(error.__cause__, FileNotFoundError): return 'admission'
            raise
        target = json.loads(self.request_json)['target']
        a.require(value in (dict(stage='terminationDispatch',target=target),dict(stage='launchDispatch',target=target)),
                  'preparation intent marker differs')
        return value['stage']


@a.checked
def bind_preparation(argv, *, prepared, original, expected_scope, supervisor, ledger_root,
                     temporary, app, data, bundle):
    a.revalidate(prepared)
    a.require('recording_preparation.py' in {Path(p.path).name for p in prepared.files}, 'preparation resource not pinned')
    a.require(tuple(argv[:4]) == (prepared.python,'-I',str(Path(prepared.capture_resource)/'capture.py'),'--prepare-recording')
              and len(argv) == 5, 'preparation argv differs')
    path = a.absolute(argv[-1]); folder = private_folder(path.parent, temporary)
    a.require(path.name == 'recording-request.json', 'preparation request filename differs')
    pins = list(prepared.files)
    request = a.read_json(path, pins, limit=16384)
    product(prepared).validate_request(request)
    a.require(request['target'] == original and request['scope'] == expected_scope, 'preparation target/scope differs')
    release = released_ledger(prepared, original, ledger_root, temporary)
    pins.extend(release.files)
    state = json.loads(release.state_json)
    captures = [v for key,v in state['results'].items() if state['operations'][key]['kind'] == 'capture'
                and v.get('captureID') == state['captureID']]
    a.require(len(captures) == 1, 'initial capture receipt absent/ambiguous')
    full = a.read_json(Path(captures[0]['evidenceDirectory']) / 'result.json', pins, limit=16*1024*1024)
    a.require({k:full['inspectionScope'][k] for k in expected_scope} == expected_scope,
              'released capture/native preparation scope differs')
    build = json.loads(prepared.build_json)
    setting = Path(build['developer']).parent / 'PlugIns/DebuggerUI.framework/Versions/A/Resources/DebuggerUI.xcplugindata'
    _, pin = a.read_file(setting, private=False, limit=a.IMAGE_LIMIT); pins.append(pin)
    product(prepared).validate_setting(dict(build=build))
    marker = str(Path(ledger_root) / (a.digest(a.canonical(original).encode()) + '.recording'))
    return Preparation(prepared, a.canonical(request), a.identity(supervisor), str(folder), app, data, bundle,
                       marker, release, tuple(pins))


class TargetCursor:
    """One owner-controlled revision; UI results are candidates, never authority.

Retained by session across observations. All mutable facts remain intent until
ProcessObservation supplies the native evidence; no boolean release input.
"""
    def __init__(self, binding, scope, check, publish):
        self.original = json.loads(a.canonical(binding))
        self.binding = self.original
        self.scope, self.check, self.publish = scope, check, publish
        self.phase, self.revision, self.preparation = 'original', 0, None
        self.marker_stage = 'admission'
        self.helper, self.ui = None, None
        self.launch_key, self.reconcile_key = None, None
        self.launch_settled = False
        self.result = None
        self.candidate = None
        self.histories = [binding]
        self.uncertain = False
        self.helper_settled = False
        self.published = False
        self.pending_publication = None

    def bind(self, preparation, ui):
        self.check()
        a.require(self.phase in ('original','preparing','gap','candidate'), 'second transition refused')
        a.require(json.loads(preparation.request_json)['target'] == self.original['target'] and
                  json.loads(preparation.request_json)['scope'] == self.scope, 'cursor preparation differs')
        helper = json.loads(preparation.supervisor_json)
        a.require(helper['parent'] == ui['pid'] and helper['group'] == helper['pid'] and
                  ui['parent'] == self.original['worker']['pid'] and ui['group'] == self.original['worker']['pid'],
                  'preparation owner chain differs')
        if self.preparation:
            a.require((preparation.folder,preparation.request_json,preparation.release) ==
                      (self.preparation.folder,self.preparation.request_json,self.preparation.release) and
                      all(helper[k] == self.helper[k] for k in ('pid','start','parent','group')) and
                      a.identity(ui) == a.identity(self.ui), 'preparation helper/owner changed')
            a.revalidate(self.preparation)
            if helper['path'] != self.helper['path']:
                a.require(self.helper['path'] == '/usr/bin/xcrun' and helper['path'] == preparation.prepared.python,
                          'preparation helper exec reversed/differed')
            self.helper = helper
        else:
            a.require(self.phase == 'original', 'helper cannot acquire an exited lifetime')
            self.preparation, self.helper, self.ui = preparation, helper, dict(ui)
            self.phase = 'preparing'
        self.marker()

    def marker(self):
        self.check(); a.revalidate(self.preparation)
        stage = self.preparation.stage()
        stages = ('admission','terminationDispatch','launchDispatch')
        a.require(stages.index(stage) >= stages.index(self.marker_stage), 'recording marker regressed/disappeared')
        self.marker_stage = stage
        return stage

    def exited(self):
        a.require(self.phase == 'preparing' and self.marker() in ('terminationDispatch','launchDispatch'),
                  'independent exit without bound dispatch intent')
        self.phase = 'gap'

    def commands(self):
        stage = self.marker()
        if stage == 'admission': return self.preparation.admission_commands()
        if stage == 'launchDispatch' and self.phase in ('gap','candidate'):
            if not self.launch_settled: return (self.preparation.launch(),)
            if self.launch_key is not None: return (self.preparation.reconcile(),)
        return ()

    def tool(self, command, info):
        self.check()
        key = (info['pid'], tuple(info['start']))
        if command == self.preparation.launch():
            a.require(self.phase in ('gap','candidate') and self.marker() == 'launchDispatch' and
                      not self.launch_settled and self.reconcile_key is None and self.launch_key in (None,key),
                      'launch requires exited gap; duplicate/settled launch refused')
            self.launch_key = key
        elif command == self.preparation.reconcile():
            a.require(self.launch_key is not None and self.launch_settled and self.reconcile_key in (None,key),
                      'reconciliation before launch child settled')
            self.reconcile_key = key; self.uncertain = True
        else:
            a.require(command in self.preparation.admission_commands() and self.marker() == 'admission',
                      'preparation command outside admission phase')

    def tool_settled(self, key):
        if key == self.launch_key: self.launch_settled = True

    def read_result(self):
        if self.preparation is None or not self.helper_settled: return None
        path = Path(self.preparation.folder) / 'result.json'
        try: result = a.read_json(path, [], limit=16384)
        except a.ContractError as error:
            if isinstance(error.__cause__, FileNotFoundError): return None
            raise
        if self.result is not None: a.require(result == self.result, 'preparation result changed')
        self.result = result
        if result.get('status') != 'success': self.uncertain = True
        return result

    def admit(self, binding, startup):
        self.check()
        new, old = binding['target'], self.original['target']
        a.require(self.phase in ('gap','candidate') and self.launch_key is not None and self.launch_settled,
                  'successor lacks settled native launch')
        a.require(new['pid'] != old['pid'] and new['start'] != old['start'] and
                  new['path'] == old['path'] and new['deviceID'] == old['deviceID'], 'same PID/reused or foreign successor')
        a.require(binding['owner'] == self.original['owner'] and binding['worker'] == self.original['worker'] and
                  binding['originalParent'] == self.original['originalParent'], 'successor owner/parent differs')
        a.require(self.candidate in (None,binding), 'candidate lifetime changed')
        self.candidate = binding; self.phase = 'candidate'
        result = self.read_result()
        if result is None: return False
        a.require(set(result) <= {'status','stage','target','observedTarget','message','reconciliation'} and
                  result.get('stage') in ('notDispatched','terminationDispatch','terminated','launchDispatch','newLifetimeBound') and
                  result.get('status') in ('success','failed','outcomeUncertain'), 'preparation result schema differs')
        returned = result.get('target', result.get('observedTarget'))
        a.require(returned is None or a.canonical(returned) == a.canonical(new), 'result/native successor differs')
        if result.get('status') == 'success' and result.get('stage') == 'newLifetimeBound' and startup is None:
            return False  # Native candidate may precede the fixture's first oracle publication.
        success = (result.get('status') == 'success' and result.get('stage') == 'newLifetimeBound'
                   and result.get('target') == new and startup is not None)
        self.uncertain |= not success
        phase = 'custodyOnly' if self.uncertain else 'admitted'
        self.pending_publication = dict(version=1, revision=1, phase=phase, original=self.original,
                          binding=binding, startup=startup, preparationFolder=self.preparation.folder,
                          release=json.loads(self.preparation.release.state_json), result=result)
        return not self.uncertain

    def commit(self, accepted, cutoff):
        """Only the observer's final complete-family acceptance can call this."""
        a.require(not self.published and self.revision == 0 and self.phase == 'candidate' and self.pending_publication is not None,
                  'recording publication lacks complete acceptance')
        value = dict(self.pending_publication, acceptedMonotonic=accepted, observationCutoff=cutoff)
        self.binding = value['binding']; self.histories.append(self.binding); self.revision = 1
        self.phase = value['phase']
        try: self.publish(value)
        except BaseException:
            # Native candidate custody survives a publication failure. No retry
            # or fallback to the original cleanup PID is permitted.
            self.uncertain = True; self.phase = 'custodyOnly'
            raise
        self.published = True; self.pending_publication = None
