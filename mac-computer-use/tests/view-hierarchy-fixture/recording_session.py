"""Owned fixture restart protocol. No launch, signal, debugger or claim writes.

The caller supplies native/boot/claim checks and the original host deadline.
Guest uptime is intentionally never compared with host CLOCK_MONOTONIC.
"""
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import plistlib
import stat
import time
import uuid

import ui_capture_contract as a


def private_write(path, value, *, replace=False, limit=65536):
    """Publish once without replacing a foreign control, using one owned inode."""
    path = a.absolute(path)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    name = '.recording-' + uuid.uuid4().hex
    try:
        info = os.fstat(parent)
        a.require(info.st_uid == os.getuid() and not info.st_mode & 0o022, 'control directory ownership')
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as stream:
            raw = a.canonical(value).encode()
            a.require(len(raw) <= limit, 'control exceeds bound')
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        if replace:
            os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        else:
            os.link(name, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
            os.unlink(name, dir_fd=parent)
        os.fsync(parent)
    finally:
        try: os.unlink(name, dir_fd=parent)
        except FileNotFoundError: pass
        os.close(parent)


def read_control(path):
    raw, pin = a.read_file(path, private=False, limit=8192)
    a.require(pin.metadata[3] == os.getuid() and stat.S_IMODE(pin.metadata[2]) == 0o600,
              'control is not owned mode 0600')
    def unique(items):
        result = {}
        for key, value in items:
            a.require(key not in result, 'duplicate control key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique,
        parse_constant=lambda _: (_ for _ in ()).throw(a.ContractError('nonfinite control'))), raw, pin


def remove_owned(path, pin):
    _, current = a.read_file(path, private=False, limit=8192)
    a.require(current == pin, 'control replaced; preserve it')
    # Same-UID cooperative ownership; unlink cannot be made lifetime-atomic.
    Path(path).unlink()


@dataclass(frozen=True)
class Installation:
    identity_json: str
    files: tuple
    directories: tuple

    @property
    def identity(self): return json.loads(self.identity_json)

    @classmethod
    @a.checked
    def read(cls, target, data, bundle):
        executable, data = a.absolute(target['path']), a.absolute(data)
        app = executable.parent
        prefix = '/data/Containers/Bundle/Application/'
        a.require(prefix in str(app), 'installed application container required')
        device = Path(str(app).split(prefix, 1)[0])
        a.require(device.name == target['deviceID'] and data.parent == device / 'data/Containers/Data/Application',
                  'installed app/data device differs')
        uuid.UUID(data.name)
        pins = []
        for path in (executable, app / 'Info.plist', data / '.com.apple.mobile_container_manager.metadata.plist'):
            _, pin = a.read_file(path, private=False, limit=a.IMAGE_LIMIT); pins.append(pin)
        plist = plistlib.loads(a.read_file(app / 'Info.plist', private=False)[0])
        metadata = plistlib.loads(a.read_file(data / '.com.apple.mobile_container_manager.metadata.plist', private=False)[0])
        a.require(plist['CFBundleIdentifier'] == metadata['MCMMetadataIdentifier'] == bundle and
                  plist['CFBundleExecutable'] == executable.name, 'installation/MCM bundle differs')
        directories = []
        for path in (app, data, data / 'Documents'):
            info = path.lstat()
            a.require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and path.resolve() == path,
                      'installation directory is not canonical/owned')
            directories.append((str(path), info.st_dev, info.st_ino))
        identity = dict(deviceID=target['deviceID'], bundleID=bundle, executableRealpath=str(executable),
                        dataRealpath=str(data), dataUUID=data.name,
                        installationDigest=a.digest((pins[0].sha256 + ':' + pins[1].sha256).encode()))
        result = cls(a.canonical(identity), tuple(pins), tuple(directories)); result.recheck(); return result

    def recheck(self):
        a.revalidate(self)
        for path, dev, ino in self.directories:
            now = Path(path).lstat()
            a.require(stat.S_ISDIR(now.st_mode) and (now.st_dev, now.st_ino) == (dev, ino), 'installation directory replaced')

    def wire(self):
        return dict(identity=self.identity, files=[dict(path=p.path, sha256=p.sha256, metadata=list(p.metadata)) for p in self.files],
                    directories=[list(v) for v in self.directories])


class Arm:
    def __init__(self, *, session, target, installation, deadline, check, clock=time.monotonic, wall=time.time):
        self.session, self.target, self.installation = session, dict(target), installation
        self.deadline, self.check, self.clock, self.wall = deadline, check, clock, wall
        self.restart_id = str(uuid.uuid4()).upper()
        self.control = Path(installation.identity['dataRealpath']) / 'Documents/restart-control.json'
        self.entry = self.control.parent.parent / '.recording-entry-v1'
        self.state, self.pending_pin, self.control_pin = 'new', None, None
        self.receipt = None

    def fresh(self):
        self.check(); self.installation.recheck()
        a.require(math.isfinite(self.clock()) and self.clock() < self.deadline, 'original arm deadline exhausted')

    def arm(self):
        a.require(self.state == 'new', 'restart cannot be refreshed/rearmed')
        self.state = 'refused'  # Even a failed admission cannot refresh this restart ID/deadline.
        self.fresh()
        self.host_issued = self.clock()
        self.expires = min(self.deadline, self.host_issued + 60)
        self.issued = self.wall()
        for name in ('arm.claim','restart.pending.json','restart.spent','restart.consumed.json'):
            try: (self.entry / name).lstat()
            except FileNotFoundError: continue
            raise a.ContractError('fixture restart budget already used')
        old = dict(pid=self.target['pid'], startSeconds=self.target['start'][0], startMicroseconds=self.target['start'][1])
        self.old = old
        capsule = a.read_json(self.entry / 'bootstrap.json', [], limit=8192)
        a.require(capsule == dict(version=1, session=self.session, identity=self.installation.identity, oldTarget=old),
                  'fixture bootstrap differs from host identity')
        value = dict(version=1, action='armRestart', restartID=self.restart_id, session=self.session,
                     pid=self.target['pid'], issuedUnixSeconds=self.issued,
                     remainingSeconds=self.expires-self.host_issued, identity=self.installation.identity, oldTarget=old)
        self.state = 'arming'  # A failed write is not permission to rearm.
        private_write(self.control, value, limit=8192)
        _, _, self.control_pin = read_control(self.control)
        self.fresh()

    def acknowledge(self, oracle):
        a.require(self.state == 'arming', 'unexpected arm acknowledgement')
        self.fresh()
        receipt = oracle.get('restartReceipt')
        if receipt in (None, {}): return False  # Fixture has not serviced this control yet.
        a.require(set(receipt) == {'version','status','restartID','pendingSHA256','pending'} and
                  type(receipt['version']) is int and receipt['version'] == 1 and receipt['status'] == 'armed' and receipt['restartID'] == self.restart_id,
                  'arm receipt differs')
        pending, raw, pin = read_control(self.entry / 'restart.pending.json')
        a.require(set(pending) == {'version','restartID','session','oldTarget','identity','issuedUnixSeconds',
                                  'expiresUnixSeconds','issuedUptime','expiresUptime'}, 'pending fields differ')
        a.require(a.canonical(pending) == a.canonical(receipt['pending']) and a.digest(raw) == receipt['pendingSHA256'], 'exact pending bytes/hash differ')
        expected = dict(version=1, restartID=self.restart_id, session=self.session, oldTarget=self.old, identity=self.installation.identity)
        a.require(a.canonical({k:pending[k] for k in expected}) == a.canonical(expected), 'pending identity differs')
        times = [pending[k] for k in ('issuedUnixSeconds','expiresUnixSeconds','issuedUptime','expiresUptime')]
        a.require(all(type(v) in (int,float) and math.isfinite(v) for v in times), 'pending clocks invalid')
        issued, expires, uptime, until = times
        a.require(self.issued <= issued <= self.wall() < expires <= self.issued + self.expires-self.host_issued and
                  0 < until-uptime <= 60 and abs((expires-issued)-(until-uptime)) < .01 and self.clock() < self.expires,
                  'pending duration or wall deadline differs')
        self.pending_pin, self.receipt, self.state = pin, receipt, 'armed'
        remove_owned(self.control, self.control_pin); self.control_pin = None
        return True

    def dispatch(self):
        a.require(self.state == 'armed', 'arm receipt required before dispatch')
        self.fresh()
        a.require(self.clock() < self.expires, 'arm expired; no refresh')
        _, current = a.read_file(self.pending_pin.path, private=False, limit=8192)
        a.require(current == self.pending_pin, 'armed pending changed before dispatch')
        self.state = 'dispatchUnknown'  # Intent, never a syscall receipt.

    def cancel(self):
        a.require(self.state == 'armed', 'cancel only before dispatch')
        self.fresh()
        value = dict(version=1, action='cancelRestart', restartID=self.restart_id, session=self.session,
                     pid=self.target['pid'], issuedUnixSeconds=self.wall(), pendingSHA256=self.pending_pin.sha256)
        self.state = 'cancelling'
        private_write(self.control, value, limit=8192); _, _, self.control_pin = read_control(self.control)

    def cancelled(self, oracle):
        a.require(self.state in ('cancelling','cancelled'), 'unexpected cancellation receipt')
        if self.state == 'cancelled': return True  # No redundant control reads after success.
        self.fresh()
        receipt = oracle.get('restartReceipt')
        if receipt == self.receipt: return False
        a.require(a.canonical(receipt) == a.canonical(dict(version=1, status='cancelled', restartID=self.restart_id,
                                  pendingSHA256=self.pending_pin.sha256)), 'cancel receipt differs')
        remove_owned(self.control, self.control_pin); self.control_pin = None; self.state = 'cancelled'
        return True
