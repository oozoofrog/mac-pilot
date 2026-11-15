"""Read-only joins of existing durable ledger and transport receipts; no test hooks."""
import hashlib
import json
from pathlib import Path
import shutil

def ledger_path(target):
    key = hashlib.sha256(json.dumps(target, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return Path.home() / 'Library/Application Support/mac-cu/view-edit-ledger' / (key + '.json')

def released(state, target):
    if state.get('target') != target or state.get('authority') != 'released' or not state.get('releaseProof'):
        return False
    if not state.get('operations') or any(x.get('state') != 'finished' for x in state['operations'].values()):
        return False
    proof = state['releaseProof']
    result = state.get('results', {}).get(proof.get('operationID'), {})
    cleanup = result.get('cleanup', {})
    return (result.get('registryReleased') is True and result.get('status') == 'success'
            and result.get('validationOnly') is False and cleanup.get('detach') == 'success'
            and cleanup.get('childrenReaped') is True and cleanup.get('recovery', {}).get('verified') is True)

def collect(state, target, out):
    assert released(state, target), 'verified terminal release required before target cleanup'
    (out / 'durable-ledger.json').write_text(json.dumps(state, indent=2))
    operations = []
    receipts = {}
    states = [v for p in sorted(out.glob('*-ledger.json'))
              if (v := json.loads(p.read_text())).get('target') == target] + [state]
    for checkpoint in states:
        assert checkpoint['target'] == target
        for operation, receipt in checkpoint.get('results', {}).items():
            receipts[operation] = (checkpoint['operations'][operation], receipt)
    # Refresh can retire an epoch between UI checkpoints. Join its existing release
    # proof to the actual transport request/result, rather than inventing a count.
    roots = {Path(r['evidenceDirectory']).parent for _, r in receipts.values() if r.get('evidenceDirectory')}
    proofs = {p['operationID']: p for checkpoint in states for p in checkpoint.get('retired', [])}
    missing = set(proofs) - set(receipts)
    for root in roots:
        for folder in root.glob('mac-cu-views-*'):
            if not missing: break
            try:
                request = json.loads((folder / 'request.json').read_text())
            except (OSError, ValueError):
                continue
            operation = request.get('operationID')
            if operation not in missing or request.get('target') != target: continue
            proof = proofs[operation]
            digest = hashlib.sha256(json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
            assert digest == proof['requestDigest'] and request['kind'] == 'release'
            result = json.loads((folder / 'result.json').read_text())
            assert result['releaseProof'] == proof
            receipts[operation] = (dict(kind='release'), dict(result, evidenceDirectory=str(folder)))
            missing.remove(operation)
    assert not missing, 'retired release receipts missing: ' + str(missing)
    for operation, (entry, receipt) in receipts.items():
        folder = Path(receipt['evidenceDirectory'])
        request = json.loads((folder / 'request.json').read_text())
        result = json.loads((folder / 'result.json').read_text())
        digest = hashlib.sha256(json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
        assert result['requestDigest'] == receipt['requestDigest'] == digest
        assert all(result[k] == request[k] for k in ('target','ownerID','inspectionID'))
        assert request['targetEpoch'] is None or request['targetEpoch'] == result['targetEpoch']
        assert result['cleanup']['debuggerClosed'] is True and result['cleanup']['activeCall'] is None
        assert result['cleanup'].get('custodyRequired') is not True
        assert request['operationID'] == receipt['operationID'] == operation == result['operationID']
        assert request['target'] == target and request['validationOnly'] is False
        assert request['kind'] == entry['kind']
        assert result['target'] == target and result['validationOnly'] is False
        assert result['cleanup']['childrenReaped'] and result['cleanup']['recovery']['verified']
        assert result['cleanup']['detach'] == 'success'
        shutil.copytree(folder, out / ('operation-' + operation))
        operations.append(dict(operationID=operation, kind=request['kind'], status=result['status']))
    (out / 'joined-operations.json').write_text(json.dumps(operations, indent=2))
    return operations

def full_children_settled(state):
    from ui_capture_contract import read_json
    try:
        for operation, entry in state['operations'].items():
            stored = state['results'][operation]
            result = read_json(Path(stored['evidenceDirectory']) / 'result.json', [], limit=16*1024*1024)
            assert entry['state'] == 'finished' and result['operationID'] == operation
            assert result['requestDigest'] == stored['requestDigest'] == entry['digest']
            for key, state_key in [('target','target'),('ownerID','ownerID'),('inspectionID','inspectionID'),('targetEpoch','epoch')]:
                assert result[key] == stored[key] == state[state_key]
            cleanup = result['cleanup']
            assert result['validationOnly'] is False and cleanup['childrenReaped'] is True and cleanup['debuggerClosed'] is True
            assert 'activeCall' in cleanup and cleanup['activeCall'] is None and cleanup.get('custodyRequired') is not True
        return bool(state['operations'])
    except (KeyError, AssertionError, ValueError, OSError): return False

def collect_lifetimes(targets, out):
    """Never merge successor operations into the retired lifetime's ledger."""
    from ui_capture_contract import read_json
    records, operations = [], []
    for index, target in enumerate(targets):
        state = read_json(ledger_path(target), [], limit=32*1024*1024)
        assert released(state, target), 'each lifetime requires its own release'
        assert full_children_settled(state), 'each lifetime requires complete quiescence receipts'
        destination = out if len(targets) == 1 else out / ('lifetime-' + str(index))
        if destination != out: destination.mkdir(mode=0o700)
        # collect sees only immutable checkpoints for this exact target.
        for source in out.glob('*-ledger.json'):
            if destination != out and json.loads(source.read_text()).get('target') == target:
                shutil.copy2(source, destination / source.name)
        entries = collect(state, target, destination)
        records.append(dict(target=target, ledger=str(destination / 'durable-ledger.json'), operations=len(entries)))
        operations.extend(entries)
    (out / 'lifetime-history.json').write_text(json.dumps(records, indent=2))
    return operations
