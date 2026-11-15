"""Read-only schema-2 UI process contract. No process launch or LLDB import.

See docs/design/swiftui-capture-artifact-contract.md for caller obligations.
"""
from dataclasses import dataclass
import hashlib
import importlib.util
import json
import math
import os
import plistlib
from pathlib import Path
import re
import stat
import struct
import uuid
from functools import wraps

JSON_LIMIT = 65536
IMAGE_LIMIT = 64 * 1024 * 1024
TOOL_LIMIT = 512 * 1024 * 1024

class ContractError(ValueError):
    pass

def checked(function):
    @wraps(function)
    def call(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except (KeyError, TypeError, IndexError, AttributeError, OSError, ValueError, RecursionError) as error:
            if isinstance(error, ContractError):
                raise
            raise ContractError(str(error)) from error
    return call

def require(ok, reason):
    if not ok:
        raise ContractError(reason)

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def absolute(path):
    raw = str(path)
    require(raw.startswith('/') and str(Path(raw)) == raw and
            all(p not in ('.', '..') for p in raw.split('/')), 'noncanonical absolute path')
    return Path(raw)

def identity(value):
    require(type(value) is dict and {'pid','start','parent','group','path'} <= value.keys(), 'incomplete process identity')
    for k in ('pid','parent','group'):
        require(type(value[k]) is int and 0 < value[k] <= 2147483647, 'invalid process identity')
    start = value['start']
    require(type(start) is list and len(start) == 2 and all(type(n) is int for n in start)
            and start[0] > 0 and 0 <= start[1] < 1000000, 'invalid process start')
    absolute(value['path'])
    return canonical({k:value[k] for k in ('pid','start','parent','group','path')})

def stamp(s):
    return (s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

@dataclass(frozen=True)
class FilePin:
    path: str
    metadata: tuple
    sha256: str
    limit: int
    private: bool


def read_file(path, *, limit=JSON_LIMIT, private=True):
    """Walk every ancestor with openat/O_NOFOLLOW; read one bounded regular inode."""
    path = absolute(path)
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    fd = None
    try:
        for part in path.parts[1:-1]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = nxt
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= limit,
                'not a bounded single-link regular file')
        if private:
            parent = os.fstat(directory)
            require(before.st_uid == parent.st_uid == os.getuid() and
                    not (before.st_mode & 0o077 or parent.st_mode & 0o077), 'artifact not private/current user')
        raw = bytearray()
        while len(raw) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        require(len(raw) == before.st_size and stamp(os.fstat(fd)) == stamp(before) and
                stamp(os.stat(path.name, dir_fd=directory, follow_symlinks=False)) == stamp(before), 'file changed during read')
        return bytes(raw), FilePin(str(path),stamp(before),digest(raw),limit,private)
    except (OSError, TypeError) as error:
        raise ContractError(str(error)) from error
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def read_json(path, pins, *, private=True, limit=JSON_LIMIT):
    raw, pin = read_file(path, private=private, limit=limit)
    pins.append(pin)
    try:
        def unique(items):
            result = {}
            for k,v in items:
                require(k not in result, 'duplicate JSON key')
                result[k] = v
            return result
        return json.loads(raw, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ContractError('nonfinite JSON')))
    except (ValueError, UnicodeError) as error:
        raise ContractError(str(error)) from error


def revalidate(binding):
    """Reject replaced/changed inputs. Caller must also enforce active membership/cutoff."""
    for pin in binding.files:
        _, current = read_file(pin.path, limit=pin.limit, private=pin.private)
        require(current == pin, 'stale binding: '+pin.path)

@dataclass(frozen=True)
class Prepared:
    capture_resource: str
    resident_resource: str
    python: str
    build_json: str
    selected_tools_json: str
    files: tuple


@checked
def prepare(*, capture_resource, resident_resource, python, resource_hashes, build, selected_tools):
    """Consume externally verified pins; re-read exact resources/build without tools."""
    capture_resource, resident_resource = absolute(capture_resource), absolute(resident_resource)
    absolute(python)
    require({'capture.py','resident_transport.py','edit_backend.py','swiftui_product.py','swiftui_graph.py'} <= resource_hashes.keys(), 'missing entry resource pins')
    pins = []
    for name, expected in resource_hashes.items():
        require(Path(name).name == name and name not in ('.','..'), 'invalid resource name')
        raw, pin = read_file(capture_resource/name, limit=IMAGE_LIMIT, private=False)
        require(digest(raw) == expected, 'prepared resource hash mismatch')
        pins.append(pin)
    actual = read_json(resident_resource/'resident-build.json',pins,private=False)
    require(actual == build and actual['abi'] == 2 and actual['architecture'] == 'arm64' and
            actual['image'] == 'mac-cu-resident-v2.dylib', 'prepared build mismatch')
    uuid.UUID(actual['uuid'])
    for name, expected in {actual['image']:actual['sha256'], **actual['sources']}.items():
        require(Path(name).name == name and name not in ('.','..'), 'invalid build resource')
        raw, pin = read_file(resident_resource/name,limit=IMAGE_LIMIT,private=False)
        require(digest(raw) == expected, 'build resource hash mismatch')
        pins.append(pin)
    for key in ('developer','sdk'):
        absolute(actual[key])
    require(set(selected_tools) == {'server','python','sdk','lldb'}, 'selected tools fields')
    for value in selected_tools.values():
        absolute(value)
    require(selected_tools['sdk'] == build['sdk'], 'selected SDK mismatch')
    for path, expected in ((selected_tools['server'],build['debugserverSHA256']),
                           (selected_tools['lldb'],build['lldbSHA256']),
                           (str(Path(selected_tools['sdk'])/'SDKSettings.json'),build['sdkSHA256'])):
        raw, pin = read_file(path,limit=TOOL_LIMIT,private=False)
        require(digest(raw) == expected, 'selected tool hash mismatch')
        pins.append(pin)
    return Prepared(str(capture_resource),str(resident_resource),str(python),canonical(build),canonical(selected_tools),tuple(pins))


def schema2(request, prepared):
    # Canonical validation is pure and does not initialize ProcessProbe or LLDB.
    spec = importlib.util.spec_from_file_location('_ui_capture_schema',Path(prepared.capture_resource)/'capture.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        require(type(request) is dict and request.get('schemaVersion') == 2, 'schema 2 required')
        require(module.request_contract(request) == request, 'request must already be canonical')
    except Exception as error:
        raise ContractError('invalid schema-2 request: '+str(error)) from error

@dataclass(frozen=True)
class CaptureBinding:
    prepared: Prepared
    folder: str
    request_json: str
    supervisor_json: str
    app: str
    data: str
    bundle: str
    files: tuple

    def commands(self, role):
        build = json.loads(self.prepared.build_json)
        target = json.loads(self.request_json)['target']
        key = digest(canonical(target).encode())
        image = str(Path(self.data)/'Library/Caches/org.oozoofrog.mac-cu-resident'/key/build['image'])
        canonical_image = str(Path(self.prepared.resident_resource)/build['image'])
        sign = lambda p: ('/usr/bin/codesign','--verify','--strict',p)
        if role == 'resident-worker':
            return (sign(canonical_image),sign(image))
        require(role == 'supervisor', 'unknown role')
        return (sign(canonical_image),('/usr/bin/xcode-select','-p'),
                ('/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'),
                ('/usr/bin/xcodebuild','-version'),
                ('/usr/bin/xcrun','simctl','list','devices','--json'),
                ('/usr/bin/xcrun','simctl','list','runtimes','--json'),
                ('/usr/bin/xcrun','simctl','get_app_container',target['deviceID'],self.bundle,'app'),
                sign(self.app),('/usr/bin/codesign','-d','--xml','--entitlements','-',target['path']),
                ('/usr/bin/xcrun','simctl','get_app_container',target['deviceID'],self.bundle,'data'),sign(image))


@checked
def bind_capture(argv, *, prepared, target, expected_request, owned_app, owned_data, bundle_id,
                 ui_temporary_root, supervisor):
    revalidate(prepared)
    require(len(argv) == 5 and tuple(argv[:4]) == (prepared.python,'-I',str(Path(prepared.capture_resource)/'capture.py'),'--capture'), 'capture argv mismatch')
    path = absolute(argv[4]); folder = path.parent
    require(path.name == 'request.json' and folder.parent == absolute(ui_temporary_root) and
            re.fullmatch(r'mac-cu-views-[0-9A-Fa-f-]{36}',folder.name) is not None, 'request folder scope')
    folder_id = folder.name[len('mac-cu-views-'):]
    require(str(uuid.UUID(folder_id)).lower() == folder_id.lower(), 'noncanonical request folder UUID')
    pins = list(prepared.files)
    request = read_json(path,pins)
    schema2(request,prepared)
    require(request == expected_request and request['target'] == target, 'request/target operation mismatch')
    app, data = absolute(owned_app), absolute(owned_data)
    require(Path(target['path']).parent == app and app.suffix == '.app' and
            '/Containers/Bundle/Application/' in str(app) and '/Containers/Data/Application/' in str(data), 'owned container scope')
    raw, app_pin = read_file(app/'Info.plist',private=False)
    pins.append(app_pin)
    try:
        info = plistlib.loads(raw)
    except Exception as error:
        raise ContractError('invalid app Info.plist') from error
    require(info.get('CFBundleIdentifier') == bundle_id and
            info.get('CFBundleExecutable') == Path(target['path']).name, 'bundle/executable mismatch')
    require(type(bundle_id) is str and 0 < len(bundle_id) < 512 and not bundle_id.startswith('com.apple.'), 'bundle scope')
    return CaptureBinding(prepared,str(folder),canonical(request),identity(supervisor),str(app),str(data),bundle_id,tuple(pins))

@dataclass(frozen=True)
class WorkerBinding:
    capture: CaptureBinding
    channel: str
    fd: int
    expected_server_json: str
    wire_json: str
    files: tuple

    def commands(self, role='resident-worker'):
        return self.capture.commands(role)


@checked
def bind_worker(argv, *, capture, observed_supervisor, observed_parent, expected_server,
                current_request, expected_wire, now):
    """now is caller's current CLOCK_MONOTONIC; all identities must be native-verified."""
    revalidate(capture)
    require(identity(observed_supervisor) == capture.supervisor_json and
            identity(observed_parent) == capture.supervisor_json, 'supervisor/parent identity changed')
    request = json.loads(capture.request_json)
    require(current_request == request, 'inactive/reused operation binding')
    prefix = (capture.prepared.python,'-I',str(Path(capture.prepared.capture_resource)/'resident_transport.py'),'--worker')
    require(len(argv) == 6 and tuple(argv[:4]) == prefix, 'worker argv mismatch')
    require(type(argv[5]) is str and re.fullmatch(r'[1-9][0-9]{0,9}',argv[5]) is not None and int(argv[5]) <= 2147483647, 'invalid worker FD')
    build = json.loads(capture.prepared.build_json)
    root = Path(capture.data)/'Library/Caches/org.oozoofrog.mac-cu-resident'/digest(canonical(request['target']).encode())
    channel = root/request['operationID']; image = root/build['image']
    require(argv[4] == str(channel), 'worker channel scope')
    pins = list(capture.files); folder = Path(capture.folder)
    admission = read_json(folder/'admission.json',pins)
    require(admission['build'] == build and admission['bundleID'] == capture.bundle and admission['data'] == capture.data and
            admission['signedDebugEntitlement'] == 'com.apple.security.get-task-allow' and admission['targetResigned'] is False,
            'admission join mismatch')
    raw, pin = read_file(request['target']['path'],limit=IMAGE_LIMIT,private=False); pins.append(pin)
    require(digest(raw) == admission['executableSHA256'], 'target executable hash mismatch')
    runtime = admission['runtime']
    require(runtime.get('isAvailable') is True and type(runtime.get('identifier')) is str and
            runtime.get('version') == '27.2' and runtime.get('buildversion') == '24B114', 'unsupported runtime admission')
    wire = read_json(folder/'wire.json',pins)
    require(wire == expected_wire, 'caller wire binding mismatch')
    require(all(wire.get(k) == v for k,v in request.items() if k != 'targetEpoch'), 'wire operation mismatch')
    if request['targetEpoch'] is not None:
        require(wire.get('targetEpoch') == request['targetEpoch'], 'wire epoch mismatch')
    elif wire.get('targetEpoch') is not None:
        uuid.UUID(wire['targetEpoch'])
    if 'requestDigest' in wire:
        require(wire['requestDigest'] == digest(canonical(request).encode()), 'wire request digest mismatch')
    uuid.UUID(wire['newCaptureID'])
    record = read_json(folder/'channel.json',pins)
    require(record['path'] == str(channel) and record['image'] == str(image), 'channel join mismatch')
    staged = read_json(root/'pin.json',pins)
    require(staged == dict(target=request['target'],abi=2,sha256=build['sha256'],uuid=build['uuid'],path=str(image)), 'resident pin mismatch')
    raw, pin = read_file(image,limit=IMAGE_LIMIT); pins.append(pin)
    require(digest(raw) == build['sha256'], 'staged image hash mismatch')
    config = read_json(channel/'worker.json',pins)
    tools = json.loads(capture.prepared.selected_tools_json)
    server_json = identity(expected_server)
    require(expected_server['path'] == tools['server'] and expected_server['parent'] == observed_supervisor['pid'], 'server identity scope')
    # Production server record has no group field. Caller verifies it independently.
    require(type(config['server']) is dict and all(config['server'].get(k) == expected_server[k]
            for k in ('pid','start','parent','path')), 'server identity mismatch')
    require(config['request'] == request and config['admission'] == admission and config['supervisor'] == observed_supervisor['pid'] and
            config['image'] == str(image) and config['imageUUID'] == build['uuid'] and config['evidenceDirectory'] == str(channel) and
            config['sdkPath'] == build['sdk'] and config['pythonPath'] == tools['python'], 'worker config join mismatch')
    require(type(config['token']) is str and re.fullmatch('[0-9a-f]{32}',config['token']) is not None, 'invalid worker token')
    require(type(now) in (int,float) and math.isfinite(now) and type(config['deadline']) in (int,float) and
            math.isfinite(config['deadline']) and now < config['deadline'], 'expired worker binding')
    # Verify actual ABI-2 bytes without regenerating the time-dependent expiration.
    raw, pin = read_file(channel/'request.bin',limit=JSON_LIMIT+4096); pins.append(pin)
    fmt = struct.Struct('<8s7Q37s37s37s1024s1024s37s65s')
    require(len(raw) >= fmt.size, 'short native wire')
    fields = fmt.unpack(raw[:fmt.size]); payload = raw[fmt.size:]
    text = lambda b: b.rstrip(b'\0').decode('ascii')
    require(fields[:6] == (b'MCURP2\0\0',2,request['target']['pid'],*request['target']['start'],request['sequence']) and
            fields[7] == len(payload) and payload == canonical(wire).encode() and
            [text(v) for v in fields[8:14]] == [request['ownerID'],request['operationID'],request['target']['deviceID'],request['target']['path'],str(image),build['uuid']] and
            text(fields[14]) == record['transportDigest'] == digest(raw[:fmt.size-65]+payload), 'native wire/digest mismatch')
    binding = WorkerBinding(capture,str(channel),int(argv[5]),server_json,canonical(wire),tuple(pins))
    revalidate(binding)
    return binding
