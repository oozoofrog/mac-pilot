"""Offline audit of one preserved fixture cancellation; never starts a target or debugger."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from remote_run import confirmed_fixture_cancel

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New audit file outside the evidence directory')
    args = parser.parse_args()
    source, destination = args.input.resolve(), args.output.resolve()
    if source == destination or source in destination.parents:
        raise ValueError('audit output must not modify the preserved evidence directory')
    names = ('cancel.evidence.json', 'cancel.json', 'cancel.log', 'cancel.fixture-spinning', 'cancel.cancel-request', 'watchdog.json')
    raw = {name: (source / name).read_bytes() for name in names}
    evidence = json.loads(raw['cancel.evidence.json'])
    collector = json.loads(raw['cancel.json'])
    watchdog = json.loads(raw['watchdog.json'])
    request = json.loads(raw['cancel.cancel-request'])
    marker = raw['cancel.fixture-spinning'] == b'spinning\n' and evidence.get('fixtureSpinEntered') is True
    cancelled = confirmed_fixture_cancel(collector, evidence.get('fixtureAfter', {}), marker,
                                          raw['cancel.log'].decode('utf-8', errors='replace'), evidence.get('cancelRequest', {}))
    before = evidence.get('fixtureBefore', {})
    identity_matches = all(key in before and before[key] == collector.get('before', {}).get(key)
                           for key in ('pid', 'start', 'parent', 'path'))
    request_matches = request == collector.get('cancelControl', {}).get('request')
    cleanups = evidence.get('collectorCleanup', {}), evidence.get('serverCleanup', {}), evidence.get('fixtureCleanup', {})
    cleanup_recorded = (all(item.get('status') == 'exited' for item in cleanups)
                        and cleanups[0].get('returncode') == 0 and cleanups[1].get('returncode') == 0
                        and cleanups[2].get('returncode') == -15 and watchdog.get('cleanupErrors') == [])
    original_failure = evidence.get('case') == 'failed' and watchdog.get('reason') == "RuntimeError('worker failed: 1')"
    verdict = (cancelled and identity_matches and request_matches and cleanup_recorded and original_failure
               and evidence.get('collector') == collector)
    report = {'audit': 'confirmed fixture cancellation evidence' if verdict else 'not confirmed',
              'originalRunnerCase': evidence.get('case'), 'originalWatchdogReason': watchdog.get('reason'),
              'originalFailurePreserved': original_failure, 'fixtureCancellationAndRecovery': cancelled,
              'fixtureIdentityMatches': identity_matches, 'requestMatches': request_matches,
              'recordedChildCleanup': cleanup_recorded,
              'processGroup': 'not independently established by this offline audit',
              'inputSHA256': {name: hashlib.sha256(data).hexdigest() for name, data in raw.items()}}
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    print(json.dumps(report, indent=2))
    return 0 if verdict else 1

if __name__ == '__main__':
    raise SystemExit(main())
