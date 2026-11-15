"""Closed experiment channel. No production schema, target pointers or retries."""
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import time
import uuid

WIRE = struct.Struct('<8s7Q37s37s37s37s1024s1024s37s128s64s65s')
KEYS = {'experiment', 'operation', 'ownerID', 'operationID', 'sequence', 'target',
        'expiresUnixMS', 'nodeGeneration', 'hiddenCount', 'sceneID', 'parentName', 'image', 'imageUUID'}
NAMES = {'request.bin', 'cancel', 'accepted.json', 'entered.json', 'work-finished.json',
         'terminal.json', 'reservation.json', 'authority.json'}


def monotonic():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def monotonic_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def uid(value):
    require(isinstance(value, str) and len(value) == 36 and str(uuid.UUID(value)).upper() == value.upper(), 'invalid UUID')
    return value


def scalar(value, low=0, high=2**63 - 1):
    require(type(value) is int and low <= value <= high, 'invalid bounded integer')
    return value


def text(value, cap):
    require(isinstance(value, str) and 0 < len(value) < cap and
            all(32 <= ord(c) <= 126 and c not in '\\"' for c in value), 'invalid bounded text')
    return value.encode().ljust(cap, b'\0')


def absolute(value, cap=1024):
    text(value, cap)
    p = Path(value)
    require(p.is_absolute() and not any(x in ('.', '..') for x in value.split('/'))
            and str(p) == value, 'noncanonical absolute path')
    return value


def validate(r):
    require(type(r) is dict and set(r) == KEYS, 'closed experiment schema required')
    require(r['experiment'] == 'resident-lifetime-v1' and r['operation'] == 'setHiddenTrue'
            and type(r['sequence']) is int and r['sequence'] == 1, 'fixed operation/sequence only')
    for key in ('ownerID', 'operationID', 'nodeGeneration', 'imageUUID'):
        uid(r[key])
    t = r['target']
    require(type(t) is dict and set(t) == {'pid', 'start', 'path', 'deviceID'}, 'exact target identity required')
    scalar(t['pid'], 1, 2**31-1)
    require(type(t['start']) is list and len(t['start']) == 2, 'start tuple required')
    scalar(t['start'][0], 1); scalar(t['start'][1], 0, 999999)
    uid(t['deviceID']); absolute(t['path']); absolute(r['image'])
    scalar(r['hiddenCount'], 0, 1000); text(r['sceneID'], 128); text(r['parentName'], 64)
    require(r['parentName'] == 'fixture.root', 'fixed fixture parent only')
    now = int(time.time() * 1000)
    require(now <= scalar(r['expiresUnixMS']) <= now + 120000, 'expired or extended authority')
    return r


def encode(r):
    validate(r); t = r['target']
    values = [b'MCURL1\0\0', 1, t['pid'], *t['start'], 1, r['expiresUnixMS'], r['hiddenCount'],
              text(r['ownerID'], 37), text(r['operationID'], 37), text(t['deviceID'], 37),
              text(r['nodeGeneration'], 37), text(t['path'], 1024), text(r['image'], 1024),
              text(r['imageUUID'], 37), text(r['sceneID'], 128), text(r['parentName'], 64), b'']
    raw = WIRE.pack(*values)
    digest = hashlib.sha256(raw[:-65]).hexdigest()
    values[-1] = text(digest, 65)
    return WIRE.pack(*values), digest


def directory(path):
    path = Path(path); absolute(str(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nxt
        s = os.fstat(fd)
        require(s.st_uid == os.getuid() and stat.S_ISDIR(s.st_mode) and s.st_mode & 0o077 == 0,
                'channel directory must be owned/private')
        return fd
    except BaseException:
        os.close(fd); raise


def write(path, name, data):
    require(name in NAMES and type(data) is bytes and 0 < len(data) <= 4096, 'fixed bounded file only')
    root = directory(path)
    temporary = name + '.host-stage'
    fd = None
    created = False
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root)
        created = True
        require(os.write(fd, data) == len(data), 'short channel write'); os.fsync(fd)
        os.close(fd); fd = None
        os.link(temporary, name, src_dir_fd=root, dst_dir_fd=root, follow_symlinks=False)
        os.unlink(temporary, dir_fd=root)
        created = False
        os.fsync(root)
    finally:
        if fd is not None:
            os.close(fd)
        if created:
            os.unlink(temporary, dir_fd=root)
        os.close(root)


def read(path, name, limit=4096, private=True):
    require(name in NAMES and 0 < limit <= 4096, 'fixed bounded read only')
    root = directory(path)
    fd = None
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
        s = os.fstat(fd)
        require(s.st_uid == os.getuid() and stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and
                0 < s.st_size <= limit and (not private or s.st_mode & 0o077 == 0), 'unsafe channel file')
        raw = os.read(fd, limit + 1)
        require(len(raw) == s.st_size, 'channel size changed')
        return raw
    finally:
        if fd is not None:
            os.close(fd)
        os.close(root)


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


class Admission:
    """Durable one-lifetime tombstone. Even a lost submit reply never permits replay."""
    def __init__(self, folder):
        self.folder = Path(folder)
        self.request = self.digest = None
        self.revoked = False

    def reserve(self, request):
        raw, digest = encode(request)
        write(self.folder, 'reservation.json', json_bytes({'operationID': request['operationID'],
            'requestDigest': digest, 'ownerID': request['ownerID'], 'target': request['target'],
            'sequence': 1, 'state': 'pending/uncertain', 'replayAllowed': False}))
        self.request, self.digest = request, digest
        write(self.folder, 'request.bin', raw)
        return digest

    def cancel(self, reason, entry=None):
        require(self.digest is not None and not self.revoked, 'no current cancellable authority')
        record = {'authority': 'revoked', 'reason': reason, 'entry': entry,
                  'requestDigest': self.digest, 'monotonicNS': monotonic_ns(),
                  'nextOperationsAllowed': False}
        # Revocation is independent of marker transport and target completion.
        self.revoked = True
        write(self.folder, 'authority.json', json_bytes(record))
        write(self.folder, 'cancel', self.digest.encode())
        return record

    def observe(self, result):
        require(result['requestDigest'] == self.digest and result['operationID'] == self.request['operationID'],
                'receipt belongs to another operation')
        require(result['authorityRestored'] is False and result['admissionClosed'] is True, 'receipt reopened authority')
        return {'inspectionAuthority': 'revoked' if self.revoked else 'closed', 'targetResult': result}
