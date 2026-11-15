"""Private ABI-2 channel: copied request bytes and bounded, no-replace receipts."""
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import time
import uuid

WIRE = struct.Struct('<8s7Q37s37s37s1024s1024s37s65s')
NAMES = {'request.bin', 'cancel', 'accepted.json', 'entered.json', 'work-finished.json',
         'terminal.json', 'answer.json', 'reservation.json', 'authority.json'}

def monotonic():
    return time.clock_gettime(time.CLOCK_MONOTONIC)

def monotonic_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def scalar(value, low=0, high=2**63 - 1):
    require(type(value) is int and low <= value <= high, 'invalid bounded integer')
    return value

def text(value, cap):
    require(isinstance(value, str) and 0 < len(value.encode()) < cap and
            all(32 <= ord(c) <= 126 and c not in '\\"' for c in value), 'invalid bounded text')
    return value.encode().ljust(cap, b'\0')

def absolute(value, cap=1024):
    text(value, cap)
    path = Path(value)
    require(path.is_absolute() and not any(x in ('.', '..') for x in value.split('/'))
            and str(path) == value, 'noncanonical absolute path')
    return value

def encode(wire, image, image_uuid):
    target = wire['target']
    payload = json_bytes(wire)
    require(0 < len(payload) <= 65536, 'schema-2 payload exceeds native bound')
    values = [b'MCURP2\0\0', 2, target['pid'], *target['start'], wire['sequence'], int(time.time()*1000)+120000,
              len(payload), text(wire['ownerID'],37), text(wire['operationID'],37), text(target['deviceID'],37),
              text(target['path'],1024), text(image,1024), text(image_uuid,37), b'']
    digest = hashlib.sha256(WIRE.pack(*values)[:-65] + payload).hexdigest()
    values[-1] = text(digest,65)
    return WIRE.pack(*values) + payload, digest

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
    require(name in NAMES and type(data) is bytes and 0 < len(data) <= 16777216, 'fixed bounded file only')
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
    require(name in NAMES and 0 < limit <= 16777216, 'fixed bounded read only')
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


