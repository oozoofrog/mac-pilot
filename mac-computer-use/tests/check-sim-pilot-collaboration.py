#!/usr/bin/env python3
"""sim-pilot's records of who uses a simulator, with two agent sessions that ask each other for a device.

The records go to a temporary folder (SIM_PILOT_STATE_DIR). A booted simulator of this Mac is named in them and is
not touched: nothing is booted, shut down or sent to it. Without a booted simulator only the device-free part runs.

usage: check-sim-pilot-collaboration.py <output folder>
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
tool = out / 'sim-pilot'
subprocess.run(['swiftc', '-O', str(root / 'simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift'), '-o', str(tool)], check=True)
state = out / 'state'
count = 0


def expect(condition, message):
    global count
    count += 1
    if not condition:
        sys.exit(f'FAIL: {message}')


# Each session's process: its records count while it runs.
sleepers = [subprocess.Popen(['/bin/sleep', '600']) for _ in range(2)]
project = out / 'Cards'
(project / '.git').mkdir(parents=True, exist_ok=True)


def environment(session):
    """Session 0 is Claude Code in the Cards project, session 1 is Codex in a folder without a repository."""
    env = {key: value for key, value in os.environ.items() if not key.startswith(('CLAUDE', 'CODEX', 'T3CODE'))}
    # Other tools of this Mac may use the device (a test run, the T3 Device panel): only the temporary records count here.
    env.update(SIM_PILOT_STATE_DIR=str(state), SIM_PILOT_BUDGET_FILE=str(out / 'budget.json'), SIM_PILOT_CHECK_RECORDS_ONLY='1',
               CLAUDE_PID=str(sleepers[session].pid))
    env.update({'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'session-claude', 'CLAUDE_PROJECT_DIR': str(project)} if session == 0
               else {'CODEX_THREAD_ID': 'session-codex'})
    return env


def run(session, *arguments, timeout=120):
    done = subprocess.run([str(tool), *arguments], env=environment(session), cwd=out, capture_output=True, text=True, timeout=timeout)
    try:
        data = json.loads(done.stdout)
    except ValueError:
        data = None
    return done.returncode, data, done.stdout, done.stderr


try:
    code, sessions, _, _ = run(0, 'sessions')
    expect(code == 0 and [(s['agent'], s['session'], s['project'], s['mine'], s['via'], s['devices']) for s in sessions]
           == [('Claude Code', 'session-claude', 'Cards', True, ['sim-pilot'], [])], f'the session that asks is recorded: {sessions}')
    code, sessions, _, _ = run(1, 'sessions')
    expect({s['session']: (s['agent'], s['project'], s['mine']) for s in sessions}
           == {'session-claude': ('Claude Code', 'Cards', False), 'session-codex': ('Codex', out.name, True)}, f'both sessions: {sessions}')
    code, requests, _, _ = run(0, 'requests')
    expect(code == 0 and requests == {'incoming': [], 'outgoing': []}, 'no requests yet')
    code, _, _, error = run(0, 'request', '--udid', '00000000-0000-0000-0000-000000000000')
    expect(code == 1 and '00000000' in error, 'a request needs a booted device')

    code, devices, _, _ = run(0, 'devices')
    expect(code == 0 and isinstance(devices, list), 'devices')
    if not devices:
        print(f'PASS {count} sim-pilot collaboration assertions; no simulator is booted, so the two-session part did not run')
        sys.exit(0)
    expect(all('claimed_by' not in device for device in devices), 'the temporary records start empty')
    udid, name = devices[0]['udid'], devices[0]['name']

    code, free, _, _ = run(1, 'request', '--udid', udid)
    expect(code == 0 and free == {'requested': False, 'reason': 'free', 'udid': udid, 'name': name}, f'a free device needs no request: {free}')
    code, _, text, _ = run(0, 'claim', '--udid', udid, '--note', '로그인 확인')
    expect(code == 0 and 'Claude Code · Cards' in text, f'claim: {text}')
    code, devices, _, _ = run(1, 'devices')
    row = next(device for device in devices if device['udid'] == udid)
    expect((row['claimed_by'], row['agent'], row['project'], row['session'], row['mine']) ==
           ('Claude Code · Cards · 로그인 확인', 'Claude Code', 'Cards', 'session-claude', False), f'the other session sees agent, project and note: {row}')
    code, mine, _, _ = run(0, 'request', '--udid', udid)
    expect(mine['reason'] == 'mine', 'no request for my own device')
    code, _, _, error = run(1, 'claim', '--udid', udid)
    expect(code == 1 and 'Claude Code · Cards · 로그인 확인' in error and 'sim-pilot request' in error, f'a claimed device is refused with the way to ask: {error}')
    code, owned, _, _ = run(1, 'acquire', '--udid', udid)
    expect(code == 4 and owned['acquired'] is False and owned['reason'] == 'owned'
           and {'kind': 'sim-pilot', 'by': 'Claude Code · Cards · 로그인 확인', 'pid': sleepers[0].pid} in owned['owners'], f'acquire without waiting: {owned}')
    code, requests, _, _ = run(0, 'requests')
    expect(requests['incoming'] == [], 'acquire without --wait leaves no request')
    code, budget, _, error = run(1, 'budget')
    owners = next(device for device in budget['devices'] if device['udid'] == udid)
    expect(owners['mine'] is False and [owner['kind'] for owner in owners['owners']] == ['sim-pilot'] and error == '', f'budget names the holder and stays quiet: {owners}')

    # Ask, refuse, ask again, hand over.
    code, asked, _, _ = run(1, 'request', '--udid', udid.lower(), '--note', '스크린샷 한 장')
    expect(code == 0 and asked['requested'] is True and asked['holder']['session'] == 'session-claude'
           and asked['holder']['label'] == 'Claude Code · Cards · 로그인 확인', f'request: {asked}')
    code, devices, _, error = run(0, 'devices')
    row = next(device for device in devices if device['udid'] == udid)
    expect(row['requested_by'] == [f'Codex · {out.name} · 스크린샷 한 장'] and f'release --udid {udid}' in error and '--to session-codex' in error,
           f'the holder is told on its next command: {row} {error}')
    code, requests, _, _ = run(0, 'requests')
    incoming = requests['incoming']
    expect(len(incoming) == 1 and incoming[0]['status'] == 'waiting' and incoming[0]['from']['agent'] == 'Codex' and requests['outgoing'] == [], f'incoming: {requests}')
    code, _, _, error = run(1, 'decline', '--udid', udid)
    expect(code == 1 and '다른 세션의 기기' in error, 'only the holder answers a request')
    code, _, text, _ = run(0, 'decline', '--udid', udid, '--note', '10분 뒤')
    expect(code == 0 and '1건' in text, f'decline: {text}')
    code, requests, _, _ = run(1, 'requests')
    expect([(r['status'], r['answer']) for r in requests['outgoing']] == [('declined', '10분 뒤')], f'the requester reads the answer: {requests}')
    code, refused, _, error = run(1, 'acquire', '--udid', udid, '--wait', '30')
    expect(code == 4 and refused['reason'] == 'declined' and refused['answer'] == '10분 뒤' and '10분 뒤' in error, f'a refused wait ends at once: {refused}')
    code, _, _, error = run(0, 'release', '--udid', udid, '--to', 'session-codex')
    expect(code == 1 and '요청이 없습니다' in error, 'a refused request cannot be handed to')
    run(1, 'request', '--udid', udid, '--note', '이제 필요')
    code, _, text, _ = run(0, 'release', '--udid', udid, '--to', 'session-co')
    expect(code == 0 and 'Codex' in text, f'hand over by a unique start of the session id: {text}')
    code, claims, _, _ = run(1, 'claims')
    expect([(c['udid'], c['by'], c['agent'], c['note'], c['mine']) for c in claims] == [(udid, 'session-codex', 'Codex', '이제 필요', True)],
           f'the device is the requester\'s, with its note: {claims}')
    code, requests, _, _ = run(1, 'requests')
    expect(requests == {'incoming': [], 'outgoing': []}, 'the request is over')
    code, _, _, error = run(0, 'release', '--udid', udid)
    expect(code == 1 and '다른 세션의 기록' in error, 'the former holder cannot release it')

    # Wait for a device until its holder releases it.
    waiter = subprocess.Popen([str(tool), 'acquire', '--udid', udid, '--wait', '40', '--note', '기다렸다 씀'], env=environment(0), cwd=out,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.time() + 20
    incoming = []
    while time.time() < deadline and not incoming:
        time.sleep(0.5)
        incoming = run(1, 'requests')[1]['incoming']
    expect([(r['from']['session'], r['note']) for r in incoming] == [('session-claude', '기다렸다 씀')], f'a waiting acquire leaves a request: {incoming}')
    code, sessions, _, _ = run(1, 'sessions')
    by = {s['session']: s for s in sessions}
    expect([d['udid'] for d in by['session-codex']['devices']] == [udid] and by['session-claude']['waitingFor'] == [udid], f'sessions show who holds and who waits: {sessions}')
    code, _, text, _ = run(1, 'release', '--udid', udid)
    expect(code == 0 and 'Claude Code · Cards' in text, f'release names the session that waited: {text}')
    stdout, _ = waiter.communicate(timeout=30)
    got = json.loads(stdout)
    expect(waiter.returncode == 0 and got['acquired'] is True and got['booted'] == 'already' and got['udid'] == udid, f'the waiting session gets the device: {got}')
    code, claims, _, _ = run(0, 'claims')
    expect([(c['by'], c['note'], c['mine']) for c in claims] == [('session-claude', '기다렸다 씀', True)], f'and holds it: {claims}')

    # A wait that ends takes its request with it.
    code, timed, _, _ = run(1, 'acquire', '--udid', udid, '--wait', '3')
    expect(code == 4 and timed['reason'] == 'owned' and run(0, 'requests')[1]['incoming'] == [], f'a wait that ends: {timed}')

    # A session that ends frees its device.
    sleepers[0].kill()
    sleepers[0].wait()
    code, claims, _, _ = run(1, 'claims')
    expect(claims == [] and [s['session'] for s in run(1, 'sessions')[1]] == ['session-codex'], f'the records of an ended session are dropped: {claims}')
    print(f'PASS {count} sim-pilot collaboration assertions; the records were in a temporary folder and no simulator was touched')
finally:
    for sleeper in sleepers:
        sleeper.kill()
