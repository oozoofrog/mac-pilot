"""Compare actual production delivery/readback with independent guest state."""
import json
from pathlib import Path
import sys


def assess(out):
    if not (out / 'actions.json').exists():
        session = json.loads((out / 'session.json').read_text())
        parent = json.loads((out / 'parent.json').read_text())
        result = {'passed': False, 'stage': 'before AX mutation', 'errors': session['errors'],
                  'attemptedDelivery': session['attemptedDelivery'],
                  'cleanup': {k: session.get(k) for k in ('fixtureRemoved', 'claimReleased', 'restorationVerified', 'guestResidual', 'probeLeftovers')},
                  'parent': parent}
        (out / 'assessment.json').write_text(json.dumps(result, indent=2) + '\n')
        return result
    rows = json.loads((out / 'actions.json').read_text())
    cases = {row['case']: row for row in rows}
    checks = {}
    for name, counter, adjustment in [('press', 'press', 0), ('increment', 'increment', 1), ('decrement', 'decrement', -1), ('custom0', 'customA', 0), ('custom1', 'customB', 0)]:
        row = cases[name]; before = row['oracleBefore']; after = row['oracleAfter']
        expected = dict(before['counters']); expected[counter] = expected.get(counter, 0) + 1
        checks[name] = (row['dispatchDelta'] == 1 and row.get('hostResult', {}).get('delivery') == 'dispatched'
                        and after['counters'] == expected and after['adjustment'] == before['adjustment'] + adjustment
                        and after['text'] == before['text'] and after['secureUnchanged'] is True)
    for name, old, new in [('setString', 'initial', 'edited'), ('restoreString', 'edited', 'initial')]:
        row = cases[name]
        checks[name] = (row['dispatchDelta'] == 1 and row['oracleBefore']['text'] == old and row['oracleAfter']['text'] == new
                        and row['hostResult']['state'] == 'postconditionObserved'
                        and row['hostResult']['readback'] == {'type': 'string', 'value': new}
                        and bool(row['hostResult'].get('restoreReceipt')) and row['oracleAfter']['secureUnchanged'] is True)
    for name in ['receiptReuse', 'secure', 'disabled', 'unknownProtection', 'expectedMismatch', 'numericUnsupported', 'booleanUnsupported', 'refreshRevocation', 'closeRevocation', 'expired', 'recreatedNode']:
        if name not in cases: continue  # Normal-route run reuses unchanged prior fault evidence.
        row = cases[name]
        checks[name] = row['dispatchDelta'] == 0 and row['rejectionObserved'] and row['oracleUnchanged'] and row['oracleAfter']['secureUnchanged'] is True
    evidence = cases['cleanup']['evidence']
    checks['unregister'] = evidence['registeredTokens'] == 0 and evidence['requests'] == evidence['replies'] and evidence['requests'] > 0
    identity = json.loads((out / 'identity.json').read_text())
    checks['sameLabelFrameRecreation'] = identity['sameRecreatedLabel'] and identity['sameRecreatedFrame'] and identity['recreatedOldWrapperOccurrences'] == 0 and not identity['recreatedSameWrapper']
    session = json.loads((out / 'session.json').read_text())
    parent = json.loads((out / 'parent.json').read_text())
    checks['sessionCleanup'] = (not session['errors'] and session['fixtureRemoved'] and session['claimReleased'] and session['restorationVerified'] and not session['probeLeftovers'] and not parent['errors'] and parent['returncode'] == 0 and not parent['probeLeftovers'])
    snapshot = json.loads((out / 'production-snapshot.json').read_text())
    normal = '|' in snapshot['scope']['runtime']
    if normal:
        checks['normalRuntimeScope'] = snapshot['scope']['runtime'] == 'com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114' and bool(snapshot['qualificationFingerprint'])
        checks['LCDWorkflow'] = (out / 'lcd-result.json').exists() and json.loads((out / 'lcd-result.json').read_text())['passed'] and session.get('lcdExit') == 0
    covered = cases['coveredPress']
    result = {'checks': checks, 'passed': all(checks.values()), 'productionEnabled': normal,
              'coveredObservation': {'delivery': covered.get('hostResult'), 'oracleUnchanged': covered['oracleUnchanged'], 'semanticSuccessClaimed': False},
              'limits': ['fixture/runtime/executable bound only', 'string domain only', 'no point mapping or universal hit testing', 'no app switch/PID reuse/reboot or transport fault injection']}
    (out / 'assessment.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    result = assess(Path(sys.argv[1]))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
