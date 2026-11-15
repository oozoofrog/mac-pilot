"""Bounded UIKit capture. Supervisor owns/reaps both children; the target is never a child to kill.

The transport/state machine follows the owned fd:// prototype, without its fixture runner.
No LLDB commands or caller-supplied expressions are accepted. Live support is fixture-only
until UIKit collection, recovery and LCD coordinates have been verified together.
"""
import argparse
import base64
import ctypes
import json
import importlib.util
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

MAX_BYTES = 16 * 1024 * 1024
WORK_SECONDS = 45
# Worker: up to 2 expression timeout periods + detach/destruction grace. Supervisor
# then has 2*10s child waits + 5s recovery; Swift reserves an additional 15s.
CLEANUP_SECONDS = 100
WORKER_GRACE = 70
FIXTURE_BUNDLE = 'local.mac-pilot.hierarchy-fixture'
HERE = Path(__file__).resolve().parent
# The helper also runs under -I, which ignores PYTHONDONTWRITEBYTECODE. Never
# mutate signed app resources (or canonical source) when loading our local module.
sys.dont_write_bytecode = True
_edit_spec = importlib.util.spec_from_file_location('mac_cu_edit_backend', HERE / 'edit_backend.py')
edit_backend = importlib.util.module_from_spec(_edit_spec)
_edit_spec.loader.exec_module(edit_backend)
# This is a source-controlled qualification gate, not a request option. Enable only
# after the owned SDK-free app, safe-entry and recovery qualification has passed.
GENERAL_APP_CAPTURE_QUALIFIED = False


def monotonic():
    # Xcode Python 3.9's time.monotonic() has a process-relative epoch on macOS.
    return time.clock_gettime(time.CLOCK_MONOTONIC)


CaptureError = edit_backend.BackendError


def fail(status, message):
    raise CaptureError(status, message)


def read_json(path):
    with open(path, 'rb') as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        fail('invalidResponse', 'Capture exceeds the 16 MiB resource limit')
    return json.loads(data)


def write_json(path, value):
    temporary = Path(str(path) + '.new')
    with open(temporary, 'x', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, allow_nan=False)
    temporary.replace(path)


def request_contract(raw):
    if type(raw) is dict and type(raw.get('schemaVersion')) is int and raw['schemaVersion'] == 2:
        return edit_backend.contract(raw, request_contract)
    required = {'schemaVersion', 'target', 'query', 'validationOnly'}
    if not isinstance(raw, dict) or not required <= set(raw) or set(raw) - required - {'validationTextureProbe'}:
        fail('invalidRequest', 'Invalid capture request fields')
    target = raw['target']
    if raw['schemaVersion'] != 1 or type(raw['schemaVersion']) is not int:
        fail('invalidRequest', 'Unsupported request version')
    if not isinstance(target, dict) or set(target) != {'pid', 'start', 'path', 'deviceID'}:
        fail('invalidRequest', 'PID, process start, executable path and device identity are required')
    if type(target['pid']) is not int or not 1 <= target['pid'] <= 2147483647:
        fail('invalidRequest', 'Invalid PID')
    if (not isinstance(target['start'], list) or len(target['start']) != 2
            or any(type(n) is not int or n < 0 for n in target['start'])
            or target['start'][0] == 0 or target['start'][1] >= 1000000):
        fail('invalidRequest', 'Invalid process start identity')
    if not isinstance(target['path'], str) or not target['path'].startswith('/') or '\0' in target['path']:
        fail('invalidRequest', 'Invalid executable path')
    try:
        if str(uuid.UUID(target['deviceID'])).upper() != target['deviceID'].upper():
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        fail('invalidRequest', 'Invalid simulator device identity')
    if not isinstance(raw['query'], str) or len(raw['query'].encode()) > 1024 or '\0' in raw['query']:
        fail('invalidRequest', 'Query must be at most 1024 UTF-8 bytes')
    if type(raw['validationOnly']) is not bool:
        fail('invalidRequest', 'Invalid validation policy')
    if 'validationTextureProbe' in raw and (type(raw['validationTextureProbe']) is not bool or not raw['validationOnly']):
        fail('invalidRequest', 'Texture probe requires a boolean and fixture validation')
    return raw


class BSDInfo(ctypes.Structure):
    # Darwin proc_bsdinfo, PROC_PIDTBSDINFO=3; PROC_FLAG_TRACED=2.
    _fields_ = [(n, ctypes.c_uint32) for n in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(n, ctypes.c_uint32) for n in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('sec', ctypes.c_uint64), ('usec', ctypes.c_uint64)]


class ProcessProbe:
    def __init__(self):
        self.libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libc.sysctl.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]

    def status(self, pid):
        info = BSDInfo()
        if self.libc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info) or info.pid != pid:
            fail('identityUnknown', 'Cannot read process state/start identity')
        return {'pid': pid, 'start': [int(info.sec), int(info.usec)], 'state': int(info.status),
                'traced': bool(info.flags & 2), 'parent': int(info.ppid)}

    def identity(self, pid, device=False):
        before = self.status(pid)
        path = ctypes.create_string_buffer(4096)
        if self.libc.proc_pidpath(pid, path, len(path)) <= 0:
            fail('identityUnknown', 'Cannot read executable identity')
        result = {**before, 'path': os.path.realpath(os.fsdecode(path.value))}
        if device:
            # KERN_PROCARGS2 gives argc, executable, argv and environment. Fail closed
            # when Simulator identity is absent or inaccessible; path guesses are insufficient.
            mib = (ctypes.c_int * 3)(1, 49, pid)
            data = ctypes.create_string_buffer(1024 * 1024)
            size = ctypes.c_size_t(len(data))
            if self.libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0):
                fail('identityUnknown', 'Cannot read Simulator process environment')
            argc = int.from_bytes(data.raw[:4], sys.byteorder, signed=True)
            if not 0 < argc < 65536:
                fail('identityUnknown', 'Invalid process argument identity')
            buf = data.raw[:size.value]
            pos = buf.find(b'\0', 4) + 1
            if pos <= 4:
                fail('identityUnknown', 'Missing process executable')
            while pos < len(buf) and buf[pos] == 0:
                pos += 1
            for _ in range(argc):
                end = buf.find(b'\0', pos)
                if end < 0:
                    fail('identityUnknown', 'Incomplete process arguments')
                pos = end + 1
            values = [v.split(b'=', 1)[1] for v in buf[pos:].split(b'\0') if v.startswith(b'SIMULATOR_UDID=')]
            if len(values) != 1:
                fail('identityUnknown', 'Simulator UDID is unknown or ambiguous')
            result['deviceID'] = values[0].decode('ascii').upper()
        latest = self.status(pid)
        if latest['start'] != before['start']:
            fail('identityChanged', 'Process lifetime changed while reading identity')
        return {**result, **latest}


def same_target(actual, expected):
    return all(actual.get(k) == expected[k] for k in ('pid', 'start', 'path', 'deviceID'))


def verify_target(probe, target, running=True):
    actual = probe.identity(target['pid'], device=True)
    expected = {**target, 'path': os.path.realpath(target['path']), 'deviceID': target['deviceID'].upper()}
    if not same_target(actual, expected):
        fail('identityChanged', 'Target PID/start/path/device changed')
    if running and (actual['state'] not in (2, 3) or actual['traced']):
        fail('targetUnavailable', 'Target must already be running and untraced; paused/other-debugger targets are refused')
    return actual


def admit_debuggable_app(target, run=subprocess.run):
    """Check an already-running app's bundle and signed debug entitlement; never launch it."""
    executable = Path(os.path.realpath(target['path']))
    app = executable.parent
    try:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if (app.suffix != '.app' or info.get('CFBundleExecutable') != executable.name
                or not isinstance(info.get('CFBundleIdentifier'), str) or not info['CFBundleIdentifier']):
            fail('unsupported', 'Target is not a recognized app executable')
        result = run(['/usr/bin/codesign', '-d', '--entitlements', '-', str(executable)],
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     timeout=3, check=False)
        if result.returncode != 0 or len(result.stdout) > 65536:
            fail('unsupported', 'Signed debug entitlement could not be established')
        entitlements = plistlib.loads(result.stdout)
        if not isinstance(entitlements, dict) or entitlements.get('get-task-allow') is not True:
            fail('unsupported', 'Target does not declare get-task-allow')
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
        fail('unsupported', 'App identity or signed debug entitlement could not be established')
    return {'bundleID': info['CFBundleIdentifier'], 'executable': str(executable)}


def validation_policy(request):
    if not request['validationOnly']:
        if request.get('schemaVersion') != 2:
            fail('unavailable', 'General-app capture requires schema 2 resident backend')
        # Internal selected-toolchain/runtime/signature policy, never a caller qualification flag.
        sys.path.insert(0, str(HERE))
        import resident_support
        try:
            resident_support.admit(request)
        except Exception as error:
            fail('unsupported', str(error))
        return
    executable = Path(request['target']['path'])
    try:
        info = plistlib.loads((executable.parent / 'Info.plist').read_bytes())
    except (OSError, ValueError):
        fail('unsupported', 'Only the isolated UIKit hierarchy fixture is admitted')
    if (info.get('CFBundleIdentifier') != FIXTURE_BUNDLE or executable.name != 'HierarchyFixture'
            or info.get('CFBundleExecutable') != executable.name or executable.parent.suffix != '.app'):
        fail('unsupported', 'Only the isolated UIKit hierarchy fixture is admitted')


def tools_for_xcode():
    developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True, timeout=3).strip())
    framework = developer.parent / 'SharedFrameworks/LLDB.framework/Resources'
    server = (framework / 'debugserver').resolve()
    python = framework / 'Python'
    if not server.is_file() or not (python / 'lldb/__init__.py').is_file():
        fail('unsupported', 'Selected Xcode has no bundled debugserver/Python LLDB')
    sdk = Path(subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
        env={**os.environ, 'DEVELOPER_DIR': str(developer)}, text=True, timeout=3).strip()).resolve()
    validate_simulator_sdk(sdk)
    return server, python, sdk


def validate_simulator_sdk(sdk):
    try:
        metadata = (json.loads((sdk / 'SDKSettings.json').read_text()) if (sdk / 'SDKSettings.json').is_file()
                    else plistlib.loads((sdk / 'SDKSettings.plist').read_bytes()))
        if (not metadata.get('CanonicalName', '').startswith('iphonesimulator')
                or metadata.get('DefaultProperties', {}).get('PLATFORM_NAME') != 'iphonesimulator'
                or not all((sdk / ('System/Library/Frameworks/' + name + '.framework/Modules/module.modulemap')).is_file()
                           for name in ('Foundation', 'UIKit'))):
            raise ValueError('not an iOS Simulator SDK with Foundation/UIKit modules')
    except (OSError, ValueError) as error:
        fail('unsupported', 'Selected Simulator SDK is unavailable: ' + str(error))
    return metadata['CanonicalName']


def compiler_context(debugger, target, sdk):
    values = debugger.GetInternalVariableValue('target.sdk-path', debugger.GetInstanceName())
    paths = debugger.GetInternalVariableValue('target.clang-module-search-paths', debugger.GetInstanceName())
    return {'sdkPath': str(sdk), 'sdkSetting': [values.GetStringAtIndex(i) for i in range(values.GetSize())],
            'moduleSearchPaths': [paths.GetStringAtIndex(i) for i in range(paths.GetSize())],
            'triple': target.GetTriple(), 'platform': target.GetPlatform().GetName(),
            'executable': os.path.realpath(str(target.GetExecutable())) if str(target.GetExecutable()) else None}


def configure_target(debugger, lldb, executable, sdk, control):
    sdk = Path(sdk).resolve()
    name = validate_simulator_sdk(sdk)
    control()
    error = lldb.SBError()
    target = debugger.CreateTarget(executable, None, 'ios-simulator', False, error)
    if error.Fail() or not target.IsValid() or target.GetProcess().IsValid():
        fail('unsupported', 'Cannot create a process-free Simulator target: ' + str(error))
    if '-ios' not in target.GetTriple() or not target.GetTriple().endswith('-simulator'):
        fail('unsupported', 'Capture executable is not an iOS Simulator target')
    debugger.SetSelectedTarget(target)
    target.GetPlatform().SetSDKRoot(str(sdk))
    error = debugger.SetInternalVariable('target.sdk-path', str(sdk), debugger.GetInstanceName())
    if error.Fail():
        fail('unsupported', 'Cannot set target Simulator SDK: ' + str(error))
    return target, import_target_modules(debugger, lldb, target, sdk, control)


def import_target_modules(debugger, lldb, target, sdk, control):
    if target.GetPlatform().GetName() != 'ios-simulator' or not target.GetTriple().endswith('-simulator'):
        fail('unsupported', 'Target lost its iOS Simulator compiler platform')
    debugger.SetSelectedTarget(target)
    target.GetPlatform().SetSDKRoot(str(sdk))
    error = debugger.SetInternalVariable('target.sdk-path', str(sdk), debugger.GetInstanceName())
    if error.Fail():
        fail('unsupported', 'Cannot retain target Simulator SDK: ' + str(error))
    # These fixed module declarations use the target loader, not the separate wrapper prefix parser.
    for module in ('Foundation', 'UIKit', 'Darwin'):
        control()
        result = lldb.SBCommandReturnObject()
        debugger.GetCommandInterpreter().HandleCommand('expression -j false -l objc++ -- @import ' + module, result)
        if not result.Succeeded():
            fail('expressionError', 'Target module import failed: ' + module + ': ' + (result.GetError() or ''))
    context = compiler_context(debugger, target, sdk)
    context.update(sdkName=validate_simulator_sdk(Path(sdk)), modules=['Foundation', 'UIKit', 'Darwin'])
    return context


def stop_child(child):
    """Signal only an unreaped direct Popen child; never target, PGID or descendants."""
    if child is None:
        return None
    if child.poll() is None:
        child.terminate()
        try:
            return child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
    return child.wait(timeout=5)


def recovered(probe, target, seconds=5):
    deadline = time.monotonic() + seconds
    last = None
    while True:
        try:
            last = verify_target(probe, target)
            return {'verified': True, 'target': last}
        except Exception as error:
            last = str(error)
        if time.monotonic() >= deadline:
            return {'verified': False, 'error': last}
        time.sleep(.05)


def supervise(request, folder, probe, cancelled, popen=subprocess.Popen, discover=tools_for_xcode, ledger_root=None):
    """Schema 2 admission owns a durable reservation and target lock across cleanup."""
    if type(request) is not dict or (request.get('schemaVersion') != 2 and 'kind' not in request):
        return _supervise(request, folder, probe, cancelled, popen, discover)
    ledger = None
    value = None
    dispatch_boundary_entered = False
    try:
        request = request_contract(request)
        validation_policy(request)
        ledger = edit_backend.Ledger(request, ledger_root)
        cached = ledger.reserve()
        if cached is not None:
            return cached
        wire = ledger.wire(str(uuid.uuid4()).upper())
        if request['kind'] == 'capture':
            # Internal fixed DebugHierarchy request; the caller cannot provide this data.
            wire['textureRequestBase64'] = base64.b64encode(json.dumps(hierarchy_request(True)).encode()).decode('ascii')
        ledger.bind_wire(wire)
        dispatch_boundary_entered = True
        value = _supervise(request, folder, probe, cancelled, popen, discover, wire, ledger.revoke)
        value.update(ownerID=request['ownerID'], inspectionID=request['inspectionID'], targetEpoch=wire['targetEpoch'])
        if request['kind'] == 'capture' and value.get('status') == 'success' and 'inspectionScope' in request:
            try:
                value['swiftUI'] = edit_backend.swiftui_product().normalize(value, request['inspectionScope'])
                value.pop('swiftUIRaw', None)
            except (ValueError, TypeError, KeyError) as error:
                value.update(status='invalidResponse', message=str(error), needsRefresh=True)
        ledger.finish(value)
        return value
    except CaptureError as error:
        if value is not None:
            value.update(status='cleanupFailed', needsRefresh=True, ledgerError=str(error))
            value.pop('editing', None)
            value.pop('editableNodes', None)
            return value
        # Admission failures never dispatch. Malformed IDs are not trusted as receipt identity.
        value = {'schemaVersion': 2, 'status': error.status, 'reasonCode': str(error),
                 'mutationOutcome': 'notEntered', 'setterEntered': False, 'needsRefresh': True,
                 'before': None, 'requested': None, 'observed': None, 'undoToken': None, 'cleanup': {},
                 'neverDispatched': not dispatch_boundary_entered}
        if dispatch_boundary_entered:
            value.update(status='cleanupFailed', mutationOutcome='uncertain', reasonCode='transportEscapedWithoutReceipt')
        if isinstance(request, dict):
            value['operationID'] = request.get('operationID')
        if error.status in ('outcomeUncertain', 'resultUnavailable'):
            value['mutationOutcome'] = 'uncertain'
        return value
    except Exception as error:
        if value is not None:
            value.update(status='cleanupFailed', needsRefresh=True, ledgerError=str(error))
            value.pop('editing', None)
            value.pop('editableNodes', None)
            return value
        return {'schemaVersion': 2, 'status': 'cleanupFailed' if dispatch_boundary_entered else 'ownershipFailed', 'operationID': request.get('operationID'),
                'neverDispatched': not dispatch_boundary_entered,
                'mutationOutcome': 'uncertain' if dispatch_boundary_entered else 'notEntered', 'setterEntered': False, 'needsRefresh': True,
                'before': None, 'requested': None, 'observed': None, 'undoToken': None,
                'reasonCode': 'durableReservationFailed', 'message': str(error), 'cleanup': {}}
    finally:
        if ledger is not None:
            ledger.close()


def _supervise(request, folder, probe, cancelled, popen=subprocess.Popen, discover=tools_for_xcode, edit_wire=None, revoke=lambda: None):
    """Single-use supervisor. Schema 2 uses the pinned compiled resident transport."""
    if edit_wire is not None:
        sys.path.insert(0, str(HERE))
        import resident_transport
        return resident_transport.supervise(request, edit_wire, folder, probe, cancelled, revoke)
    return _supervise_debugger(request, folder, probe, cancelled, popen, discover)


def _supervise_debugger(request, folder, probe, cancelled, popen=subprocess.Popen, discover=tools_for_xcode, edit_wire=None, revoke=lambda: None):
    # Schema 1 transport; legacy fake-engine tests also exercise ledger failure semantics here.
    request = request_contract(request)
    validation_policy(request)
    result = {'schemaVersion': 1, 'captureID': str(uuid.uuid4()), 'status': 'failed',
              'verified': False, 'overlayEnabled': False, 'target': request['target'],
              'captureTime': None, 'hierarchy': None, 'geometry': None, 'cleanup': {},
              'limitations': ['Preflight and attach are not atomic; another debugger can race this session.',
                              'Debugger evaluation runs target code; detach cannot roll back its side effects.',
                              'UIKit and coordinate collection have not been live-validated.']}
    if edit_wire is not None:
        result.update(edit_backend.receipt(request, 'failed', 'notDispatched'))
        result['captureID'] = edit_wire['newCaptureID'] if request['kind'] == 'capture' else request['captureID']
        result['evidenceDirectory'] = str(folder)
    server = worker = left = right = None
    start = monotonic()
    deadline = start + WORK_SECONDS
    cancel_file = folder / 'cancel'
    try:
        verify_target(probe, request['target'])
        if cancelled() or cancel_file.exists():
            fail('cancelled', 'Capture cancelled before starting children')
        server_path, python_path, sdk_path = discover()
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'PYTHON', 'MAC_CU_'))}
        server = popen([str(server_path), '--fd', str(right.fileno())], pass_fds=(right.fileno(),),
                       env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        right.close()
        info = probe.identity(server.pid)
        if server.poll() is not None or info['parent'] != os.getpid() or info['path'] != str(server_path):
            fail('ownershipFailed', 'Exact direct debugserver child identity could not be established')
        config = {'request': request, 'server': info, 'supervisor': os.getpid(),
                  'pythonPath': str(python_path), 'sdkPath': str(sdk_path), 'deadline': deadline, 'captureID': result['captureID'],
                  'clock': 'CLOCK_MONOTONIC', 'sentMonotonic': monotonic(), 'evidenceDirectory': str(folder)}
        if edit_wire is not None:
            config['editWire'] = edit_wire
        result['clockTransmission'] = {'clock': config['clock'], 'deadlineMonotonic': deadline,
                                       'sentMonotonic': config['sentMonotonic'],
                                       'remainingAtSendSeconds': deadline-config['sentMonotonic']}
        write_json(folder / 'worker.json', config)
        worker = popen([sys.executable, '-I', str(HERE / 'capture.py'), '--worker', str(folder), str(left.fileno())],
                       pass_fds=(left.fileno(),), env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        left.close()
        reason = None
        while worker.poll() is None:
            if cancelled() or cancel_file.exists() or monotonic() >= deadline:
                reason = 'cancelled' if cancelled() or cancel_file.exists() else 'timeout'
                cancel_file.touch(mode=0o600, exist_ok=True)
                try:
                    worker.wait(timeout=WORKER_GRACE)
                except subprocess.TimeoutExpired:
                    result['cleanup']['workerDeadlineExceeded'] = True
                break
            time.sleep(.025)
        if (folder / 'engine.json').is_file():
            worker_result = read_json(folder / 'engine.json')
            worker_cleanup = worker_result.pop('cleanup', {})
            result.update(worker_result)
            result['cleanup'].update(worker_cleanup)
        else:
            result.update(status='failed', message='Capture worker ended without a result')
        if reason:
            result['interruptionReason'] = reason
            # A cancellation must not hide the worker's independent detach/close failure.
            if result['status'] != 'cleanupFailed':
                result.update(status=reason, message='Capture ' + reason)
    except CaptureError as error:
        result.update(status=error.status, message=str(error))
    except Exception as error:
        result.update(status='failed', message=str(error))
    finally:
        for sock in (left, right):
            if sock is not None:
                sock.close()
        for label, child in (('worker', worker), ('debugserver', server)):
            try:
                result['cleanup'][label + 'Exit'] = stop_child(child)
            except Exception as error:
                result['cleanup'][label + 'Error'] = str(error)
        result['cleanup']['recovery'] = recovered(probe, request['target'])
        result['elapsedSeconds'] = monotonic() - start
        result['cleanup']['childrenReaped'] = all(c is None or c.returncode is not None for c in (worker, server))
        if (not result['cleanup']['recovery']['verified'] or not result['cleanup']['childrenReaped']
                or result['cleanup'].get('workerDeadlineExceeded')
                or (worker is not None and not (folder / 'engine.json').is_file())):
            result.update(status='cleanupFailed', message='Same-target recovery or owned child reaping is unverified')
        if result['status'] in ('success', 'noChange') and result.get('detach') != 'success':
            result.update(status='cleanupFailed', message='Successful debugger detach was not established')
        if result['status'] != 'success':
            result['hierarchy'] = result['geometry'] = None
        if edit_wire is not None:
            if worker is not None and not (folder / 'engine.json').is_file():
                result.update(mutationOutcome='uncertain', needsRefresh=True, reasonCode='workerResultLost')
            if result['status'] not in ('success', 'noChange'):
                result['needsRefresh'] = True
                result.pop('editing', None)
                result.pop('editableNodes', None)
            result['cleanup'].update(detach=result.get('detach', 'not attempted'))
    return result


def hierarchy_request(texture_probe=False):
    request = {'DBGHierarchyRequestIdentifier': str(uuid.uuid4()), 'DBGHierarchyRequestInitiatorVersionKey': 4,
            'DBGHierarchyRequestPriority': 0, 'DBGHierarchyRequestTransportCompression': False,
            'DBGHierarchyObjectDiscovery': 1, 'DBGHierarchyRequestActions': [{
                'actionClass': 'DebugHierarchyPropertyAction', 'visibility': 1, 'propertyNamesAreExclusive': False,
                'propertyNames': ['frame', 'bounds', 'center', 'transform', 'clipsToBounds', 'hidden', 'alpha',
                                  'accessibilityIdentifier', 'accessibilityLabel', 'text', 'firstItem', 'firstAttribute',
                                  'relation', 'secondItem', 'secondAttribute', 'multiplier', 'constant', 'priority',
                                  'active', 'identifier']}]}
    if texture_probe:
        request['DBGHierarchyRequestActions'][0]['propertyNames'].append('snapshotImage')
    return request


def collection_expression(answer, texture_probe=False, request_path=None):
    wire = json.dumps(hierarchy_request(texture_probe)).encode()
    if texture_probe and request_path is not None:
        with open(request_path, 'xb') as stream:
            os.chmod(request_path, 0o600)
            stream.write(wire)
    encoded = base64.b64encode(wire).decode('ascii')
    source = (HERE / 'collect.expr').read_text()
    if texture_probe:
        # Retain the exact target response bytes, subject to the existing resource cap.
        marker = '    NSDictionary *hierarchy = raw ?'
        assert source.count(marker) == 1
        raw_path = json.dumps(str(answer.parent / 'hierarchy-response.json'))
        source = source.replace(marker, '    if (raw && [raw length] <= 16777216) [raw writeToFile:@' + raw_path + ' atomically:YES];\n' + marker)
    return (source.replace('__REQUEST_BASE64__', encoded)
            .replace('__TEXTURE_PREFLIGHT__', 'YES' if texture_probe else 'NO')
            .replace('__ANSWER_PATH__', json.dumps(str(answer))))


class LLDBEngine:
    def __init__(self, config, fd, probe, control):
        sys.path.insert(0, config['pythonPath'])
        import lldb
        self.lldb, self.config, self.fd, self.probe, self.control = lldb, config, fd, probe, control
        self.debugger = lldb.SBDebugger.Create()
        self.debugger.SetAsync(False)
        self.process = None
        self.frame = None
        self.attach_requested = False
        self.interrupt_thread = None

    def check_server(self):
        expected = self.config['server']
        current = self.probe.identity(expected['pid'])
        if (any(current[k] != expected[k] for k in ('pid', 'start', 'path', 'parent'))
                or current['parent'] != self.config['supervisor'] or os.getppid() != self.config['supervisor']):
            fail('ownershipFailed', 'Direct supervisor/debugserver identity changed')

    def wait_state(self, wanted):
        lldb = self.lldb
        until = min(self.config['deadline'], monotonic() + 12)
        while monotonic() < until:
            self.control()
            state = self.process.GetState()
            if state == wanted:
                return
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
                fail('failed', 'Debugger ended in state ' + str(state))
            event = lldb.SBEvent()
            if self.listener.WaitForEvent(1, event) and lldb.SBProcess.EventIsProcessEvent(event):
                state = lldb.SBProcess.GetStateFromEvent(event)
                if state == wanted:
                    return
                if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed, lldb.eStateUnloaded):
                    fail('failed', 'Debugger event ended in state ' + str(state))
        fail('timeout', 'Debugger state transition timed out')

    def connect(self):
        self.check_server()
        sock = socket.socket(fileno=self.fd)
        if sock.family != socket.AF_UNIX or sock.type & socket.SOCK_STREAM != socket.SOCK_STREAM:
            fail('ownershipFailed', 'Expected private AF_UNIX stream transport')
        sock.detach()  # fd:// borrows the descriptor.
        self.listener = self.lldb.SBListener('mac-cu UIKit capture')
        self.target, self.compiler_context = configure_target(self.debugger, self.lldb,
            self.config['request']['target']['path'], self.config['sdkPath'], self.control)
        target = self.target
        error = self.lldb.SBError()
        self.process = target.ConnectRemote(self.listener, 'fd://' + str(self.fd), 'gdb-remote', error)
        if error.Fail() or not self.process.IsValid():
            fail('failed', 'Private debugserver connection failed: ' + str(error))
        self.wait_state(self.lldb.eStateConnected)

    def attach(self, target):
        self.check_server()
        error = self.lldb.SBError()
        self.attach_requested = True
        if not self.process.RemoteAttachToProcessWithID(target['pid'], error) or error.Fail():
            fail('failed', 'Remote attach failed: ' + str(error))
        self.wait_state(self.lldb.eStateStopped)
        if self.process.GetProcessID() != target['pid']:
            fail('identityChanged', 'Debugger returned a different target PID')
        current = verify_target(self.probe, target, running=False)
        if current['state'] != 4 or not current['traced']:
            fail('targetUnavailable', 'Expected stopped, traced target after owned attach')

    def select_main(self):
        candidates = [self.process.GetThreadAtIndex(i) for i in range(self.process.GetNumThreads())
                      if self.process.GetThreadAtIndex(i).GetQueueName() == 'com.apple.main-thread']
        if len(candidates) != 1:
            fail('unsupported', 'Cannot uniquely identify the main dispatch queue thread')
        self.process.SetSelectedThread(candidates[0])
        self.frame = candidates[0].GetFrameAtIndex(0)
        if not self.frame.IsValid():
            fail('unsupported', 'Selected main thread has no valid frame')
        thread = candidates[0]
        frames = []
        for index in range(min(thread.GetNumFrames(), 65)):
            frame = thread.GetFrameAtIndex(index)
            module = frame.GetModule().GetFileSpec()
            path = os.path.join(module.GetDirectory() or '', module.GetFilename() or '')
            frames.append({'index': index, 'function': (frame.GetFunctionName() or '')[:1024], 'module': path[:4096]})
        self.entry_metadata = {'id': int(thread.GetThreadID()), 'queue': thread.GetQueueName(), 'frames': frames,
                               'candidateIdle': edit_backend.safe_entry(frames, self.config['request']['target']['path']),
                               'qualifiedForGeneralApps': False}
        # Record rejection evidence BEFORE any target expression, including BOOL proof.
        write_json(Path(self.config['evidenceDirectory']) / 'main-thread-entry.json', self.entry_metadata)
        if self.config['request']['schemaVersion'] == 2 and not self.entry_metadata['candidateIdle']:
            fail('unsafeEntry', 'Main thread does not match the conservative fixture idle-stack candidate')
        # Attach may recreate the scratch AST; import into this selected target/frame before proving main-thread execution.
        self.compiler_context = import_target_modules(self.debugger, self.lldb, self.process.GetTarget(),
            self.config['sdkPath'], self.control)
        if self.evaluate('(BOOL)[NSThread isMainThread]').GetValueAsUnsigned() != 1:
            fail('unsupported', 'Selected thread did not confirm NSThread.isMainThread')
        if self.config['request']['schemaVersion'] == 2:
            features = self.evaluate('(unsigned long)(__has_feature(objc_arc)\n'
                                     '#ifdef OBJC_ZEROCOST_EXCEPTIONS\n | 2\n#endif\n)').GetValueAsUnsigned()
            if features & 1:
                fail('unsupported', 'Editable expression requires MRC ownership')
            self.compiler_context.update(editExpressionOwnership='MRC', editExceptionHandling=
                'targetCatchAndLLDBTrap' if features & 2 else 'lldbTrapAndHostUncertainty')
        return {**self.entry_metadata, 'isMainThread': True}

    def evaluate(self, source):
        self.control()
        options = self.lldb.SBExpressionOptions()
        options.SetLanguage(self.lldb.eLanguageTypeObjC_plus_plus)
        if self.config['request']['schemaVersion'] == 2:
            options.SetAutoApplyFixIts(False)
        options.SetTimeoutInMicroSeconds(max(1, int(min(8, self.config['deadline'] - monotonic()) * 1000000)))
        options.SetOneThreadTimeoutInMicroSeconds(500000)
        options.SetTryAllThreads(False)
        options.SetUnwindOnError(True)
        options.SetTrapExceptions(True)
        options.SetIgnoreBreakpoints(True)
        active = threading.Event()
        active.set()

        def interrupt():
            while active.is_set():
                time.sleep(.02)
                try:
                    self.control()
                except CaptureError:
                    if active.is_set():
                        try:
                            self.check_server()
                            verify_target(self.probe, self.config['request']['target'], running=False)
                            self.process.SendAsyncInterrupt()
                        except Exception:
                            pass  # Supervisor deadline remains the outer bound.
                    return
        watcher = threading.Thread(target=interrupt, daemon=True)
        self.interrupt_thread = watcher
        watcher.start()
        try:
            value = self.frame.EvaluateExpression(source, options)
        finally:
            active.clear()
            watcher.join(timeout=2)
        if watcher.is_alive():
            fail('failed', 'Expression interrupt control did not finish')
        self.control()
        error = value.GetError()
        if error.Fail():
            status = ('timeout' if error.GetType() == self.lldb.eErrorTypeExpression
                      and error.GetError() == self.lldb.eExpressionTimedOut else 'expressionError')
            fail(status, str(error))
        return value

    def collect(self, answer):
        if self.evaluate('(void *)dlopen("/usr/lib/libViewDebuggerSupport.dylib", 2)').GetValueAsUnsigned() == 0:
            fail('unsupported', 'Runtime ViewDebuggerSupport could not be loaded')
        texture_probe = self.config['request'].get('validationTextureProbe', False)
        if self.evaluate(collection_expression(answer, texture_probe, answer.parent / 'hierarchy-request.json')).GetValueAsUnsigned() != 1:
            fail('unsupported', 'Runtime DBGTargetHub did not produce a hierarchy response')
        payload = read_json(answer)
        if (not isinstance(payload, dict) or not isinstance(payload.get('hierarchy'), dict)
                or not isinstance(payload['hierarchy'].get('topLevelGroups'), dict)
                or not isinstance(payload.get('geometry'), dict) or not isinstance(payload.get('captureTime'), str)):
            fail('invalidResponse', 'Malformed runtime capture envelope')
        if texture_probe:
            raw = read_json(answer.parent / 'hierarchy-response.json')
            if raw != payload['hierarchy']:
                fail('invalidResponse', 'Raw hierarchy response differs from capture envelope')
        return payload

    def edit_operation(self, answer):
        fail('unsupported', 'Schema 2 requires the compiled resident transport')

    def detach(self):
        if self.interrupt_thread and self.interrupt_thread.is_alive():
            return 'not attempted: expression interrupt control is still active'
        if not self.attach_requested or self.process is None or not self.process.IsValid():
            return 'not attached'
        state = self.process.GetState()
        if state == self.lldb.eStateExited:
            return 'target exited'
        if state == self.lldb.eStateDetached:
            return 'already detached'
        # Also request detach after an attach error: it might have reached the server.
        error = self.process.Detach(False)
        return 'success' if error.Success() else str(error)

    def close(self):
        if self.interrupt_thread and self.interrupt_thread.is_alive():
            fail('cleanupFailed', 'Cannot destroy debugger concurrently with interrupt control')
        self.lldb.SBDebugger.Destroy(self.debugger)
        os.close(self.fd)


def run_engine(config, folder, engine_factory, probe):
    request = request_contract(config['request'])
    received = monotonic()
    result = {'status': 'failed', 'detach': 'not attempted', 'hierarchy': None, 'geometry': None,
              'connected': False, 'attachRequested': False,
              'deadlineReceipt': {'clock': 'CLOCK_MONOTONIC', 'deadlineMonotonic': config['deadline'],
                                  'receivedMonotonic': received, 'remainingAtReceiptSeconds': config['deadline']-received}}
    engine = None
    attach_requested = False
    editable = request['schemaVersion'] == 2
    dispatch_started = False
    payload_received = False
    config['evidenceDirectory'] = str(folder)
    if editable:
        result.update(edit_backend.receipt(request, 'failed', 'notDispatched'))

    def control():
        if (folder / 'cancel').exists():
            fail('cancelled', 'Capture cancelled')
        if monotonic() >= config['deadline']:
            fail('timeout', 'Capture deadline exceeded')
    try:
        validation_policy(request)
        if editable and (not isinstance(config.get('editWire'), dict)
                         or config['editWire'].get('requestDigest') != edit_backend.digest(request)):
            fail('ownershipFailed', 'Missing supervisor-owned edit reservation')
        control()
        result['targetBefore' if editable else 'before'] = verify_target(probe, request['target'])
        engine = engine_factory(control)
        engine.connect()
        result['connected'] = True
        result['compilerContextBeforeAttach'] = getattr(engine, 'compiler_context', None)
        control()
        # This recheck narrows the race, but does not make external attach atomic.
        result['beforeAttach'] = verify_target(probe, request['target'])
        attach_requested = True
        result['attachRequested'] = True
        engine.attach(request['target'])
        result['afterAttach'] = verify_target(probe, request['target'], running=False)
        if isinstance(engine, LLDBEngine):
            result['compilerContextAfterAttach'] = compiler_context(engine.debugger, engine.process.GetTarget(), config['sdkPath'])
        result['mainThread'] = engine.select_main()
        result['compilerContextAfterMainProof'] = getattr(engine, 'compiler_context', None)
        if editable:
            dispatch_started = True
            write_json(folder / 'dispatch.json', {'operationID': request['operationID'],
                       'requestDigest': config['editWire']['requestDigest'], 'phase': 'dispatching'})
            payload = engine.edit_operation(folder / 'answer.json')
            edit_backend.validate_payload(payload, config['editWire'])
            result.update(payload)
            payload_received = True
        else:
            payload = engine.collect(folder / 'answer.json')
            result.update(payload, status='success')
        # Preserve a returned mutation receipt even if cancellation arrives now.
        control()
    except CaptureError as error:
        result.update(status=error.status, message=str(error))
    except Exception as error:
        result.update(status='failed', message=str(error))
    finally:
        if editable and dispatch_started and not payload_received:
            result.update(mutationOutcome='uncertain', needsRefresh=True, phase='dispatchResultLost', reasonCode='resultLost')
        if engine and hasattr(engine, 'entry_metadata'):
            result['mainThreadEntry'] = engine.entry_metadata
        if engine:
            try:
                result['detach'] = engine.detach()
            except Exception as error:
                result['detach'] = str(error)
            try:
                engine.close()
            except Exception as error:
                result['closeError'] = str(error)
        result['recovery'] = recovered(probe, request['target'])
        if engine and ((attach_requested and (result['detach'] != 'success' or not result['recovery']['verified']))
                       or 'closeError' in result):
            result.update(status='cleanupFailed', message='Debugger detach/recovery did not complete cleanly')
        if result['status'] != 'success':
            result['hierarchy'] = result['geometry'] = None
        if editable and result['status'] not in ('success', 'noChange'):
            result['needsRefresh'] = True
            result.pop('editing', None)
            result.pop('editableNodes', None)
        if editable:
            result['cleanup'] = {'detach': result['detach'], 'recovery': result['recovery'],
                                 'closeError': result.get('closeError')}
    return result


def private_folder(path):
    folder = Path(path).resolve()
    stat = folder.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077 or not folder.is_dir():
        fail('invalidRequest', 'Capture directory must be private to the current user (0700)')
    return folder


def main():
    if os.environ.get('MAC_CU_NATIVE_CHECK_CHILD'):
        sys.exit(64)
    parser = argparse.ArgumentParser(allow_abbrev=False)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--identity', nargs=2, metavar=('PID', 'DEVICE'))
    group.add_argument('--capture', metavar='REQUEST')
    group.add_argument('--prepare-recording', metavar='REQUEST')
    group.add_argument('--worker', nargs=2, metavar=('FOLDER', 'FD'))
    args = parser.parse_args()
    probe = ProcessProbe()
    if args.identity:
        pid = int(args.identity[0])
        device = str(uuid.UUID(args.identity[1])).upper()
        value = probe.identity(pid, device=True)
        if value['deviceID'] != device or value['state'] not in (2, 3) or value['traced']:
            fail('targetUnavailable', 'Target device/state does not match')
        print(json.dumps({'status': 'success', 'target': {k: value[k] for k in ('pid', 'start', 'path', 'deviceID')}}))
    elif args.prepare_recording:
        sys.path.insert(0, str(HERE))
        import recording_preparation
        path = Path(args.prepare_recording).resolve()
        print(json.dumps(recording_preparation.run(read_json(path), private_folder(path.parent), probe)))
    elif args.capture:
        request_path = Path(args.capture).resolve()
        folder = private_folder(request_path.parent)
        interrupted = threading.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: interrupted.set())
        value = supervise(read_json(request_path), folder, probe, interrupted.is_set)
        print(json.dumps(value, allow_nan=False))
    else:
        folder = private_folder(args.worker[0])
        config = read_json(folder / 'worker.json')
        if config['supervisor'] != os.getppid():
            fail('ownershipFailed', 'Worker requires its owning supervisor')
        fd = int(args.worker[1])
        result = run_engine(config, folder, lambda control: LLDBEngine(config, fd, probe, control), probe)
        write_json(folder / 'engine.json', result)


if __name__ == '__main__':
    try:
        main()
    except (CaptureError, ValueError, OSError) as error:
        print(json.dumps({'schemaVersion': 1, 'status': getattr(error, 'status', 'invalidRequest'),
                          'message': str(error), 'verified': False, 'overlayEnabled': False}))
        sys.exit(1)
