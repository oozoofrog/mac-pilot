"""Read-only, selected-Xcode process matching. Does not grant execution authority.

Callers validate origin argv/artifacts, native PID/start and parent edges first.
Configuration hashes are trusted preparation inputs, never learned by this module.
"""
from dataclasses import dataclass
from pathlib import Path
import hashlib
import plistlib

DEVELOPER = '/Applications/Xcode.app/Contents/Developer'
FRAMEWORK = '/Library/Developer/PrivateFrameworks'
WRAPPERS = {
    'simctl': ('/bin/bash', 'CoreSimulator', '1174.20', 'b02b1ec5bff9f119dbb1128d0715eabf6892d4765f4be8bb7ca92c1ad39a6a2e'),
    'devicectl': ('/bin/zsh', 'CoreDevice', '651.31', '3021ecd267547db17dd6146b2afa045024eb837a4e726eb9a86abe0d5eea2e20'),
}
SOURCE_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PINS = {'tests/simulator-inspector-product-live/live.swift': '639f70e43448281521d3f9e1ede8c5914bceb9d3ea0235fc733b20c3ba123b6c', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorWindow.swift': 'fa959987b6d436070c405ee7bdb83ed1e25c96295abe6db438a749f0fec2c5d9', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorObservation.swift': '9146dd258112eddec464ea8e7ad4fba688018f296b3004bd798ca3b2052d4259', 'skills/mac-computer-use/scripts/mac-cu-src/Simulator.swift': 'f5168b05fd5f03177c621bc0a73a86d87be48a3d73b850ccf736319e827700e3', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorInspectorIntegration.swift': 'f89c728159b0522402d875d23900efbc554490bccc911ba9d2b33842f5140af8', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorDisplayState.swift': '610d4904c05ca90eb53d9913a40b6342e8b48b384d56a464e38ca9f50a09d2d2', 'skills/mac-computer-use/scripts/mac-cu-src/Daemon.swift': 'd0191ac4d5cef6b5d29e63b294aa74787c7312fd86749c7ba0130a356b84e729', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorViews.swift': '995a6d136645af9a3ff237e91d3388fffcd6145eabf5fd901c15cdda1d77932a', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorInspectorWindow.swift': '6555617fb0473de530cf67a4a46d0b808b30749b4fabd08180aabe093a99fd58', 'skills/mac-computer-use/scripts/mac-cu-src/SimulatorInspectorModel.swift': 'b008ba4dff3ddaa7b89e08da137a2e07bf13e62ba95d15205abd99bae4227221'}
DISPLAY_LIMIT = 2  # One device lane + one synchronous handleQueue caller.

class Rejected(ValueError):
    """Stable reason string suitable for observer evidence."""


def require(ok, reason):
    if not ok:
        raise Rejected(reason)


def wrapper(tool):
    return DEVELOPER + '/usr/bin/' + tool


def resources(tool):
    return FRAMEWORK + '/' + WRAPPERS[tool][1] + '.framework/Versions/A/Resources'


def required_paths():
    paths = ['/usr/bin/xcrun', '/usr/bin/xcodebuild', wrapper('xcodebuild'),
             '/usr/bin/codesign', '/usr/bin/xcode-select', '/usr/libexec/PlistBuddy',
             '/usr/bin/sort', '/usr/bin/head', '/bin/bash', '/bin/zsh']
    for tool in WRAPPERS:
        paths += [wrapper(tool), resources(tool) + '/Info.plist', resources(tool) + '/bin/' + tool]
    paths += [str(SOURCE_ROOT / relative) for relative in SOURCE_PINS]
    return tuple(paths)


@dataclass(frozen=True)
class Configuration:
    developer: str
    hashes: tuple

    @classmethod
    def read(cls, developer, hashes):
        """Verify all supplied preparation pins against current files. No commands."""
        require(developer == DEVELOPER, 'unsupported-developer')
        require(set(hashes) == set(required_paths()), 'incomplete-configured-pins')
        for path, expected in hashes.items():
            try:
                actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            except OSError as exc:
                raise Rejected('configuration-read:' + path) from exc
            require(actual == expected, 'configuration-hash:' + path)
        for relative, digest in SOURCE_PINS.items():
            require(hashes[str(SOURCE_ROOT / relative)] == digest, 'unsupported-harness-source:' + relative)
        for tool, (_, _, version, digest) in WRAPPERS.items():
            require(hashes[wrapper(tool)] == digest, 'unsupported-wrapper:' + tool)
            try:
                value = plistlib.loads(Path(resources(tool) + '/Info.plist').read_bytes())
            except (OSError, ValueError, plistlib.InvalidFileException) as exc:
                raise Rejected('framework-plist:' + tool) from exc
            require(value.get('CFBundleVersion') == version, 'framework-version:' + tool)
        return cls(developer, tuple(sorted(hashes.items())))


@dataclass(frozen=True)
class Identity:
    pid: int
    start: tuple
    parent: int
    group: int
    path: str

    @property
    def key(self):
        return self.pid, self.start

    def validate(self):
        require(type(self.pid) is int and self.pid > 0 and type(self.parent) is int and self.parent > 0
                and type(self.group) is int and self.group > 0 and isinstance(self.start, tuple)
                and len(self.start) == 2 and all(type(n) is int and n >= 0 for n in self.start)
                and self.path.startswith('/'), 'incomplete-native-identity')


@dataclass(frozen=True)
class Origin:
    identity: Identity
    parent: Identity
    argv: tuple
    provenance: str  # Opaque artifact/origin validator receipt; not a boolean authorization.
    lane: str  # capture or display; optional source lane labels confer no extra budget.
    edges_verified: bool


@dataclass(frozen=True)
class Observation:
    identity: Identity
    argv: tuple
    ancestors: tuple  # Observation objects, immediate parent first, ending at origin.
    edges_verified: bool


@dataclass(frozen=True)
class Match:
    role: str
    forward_chain: tuple
    child_limits: tuple
    provenance: str
    origin_key: tuple
    phase: int
    native_key: tuple


def origin_tool(origin):
    a = origin.argv
    require(isinstance(a, tuple) and all(isinstance(v, str) and '\0' not in v for v in a), 'invalid-origin-argv')
    require(origin.provenance and origin.edges_verified, 'unvalidated-origin')
    origin.identity.validate(); origin.parent.validate()
    require(origin.identity.parent == origin.parent.pid, 'origin-parent')
    require(origin.lane in ('capture', 'recording', 'display', 'display-passive', 'display-synchronous'), 'unknown-origin-lane')
    if a == ('/usr/bin/xcodebuild', '-version'): return 'xcodebuild'
    if a == ('/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'): return 'sdk'
    if a == ('/usr/bin/xcode-select', '-p'): return 'xcode-select'
    if len(a) == 4 and a[:3] == ('/usr/bin/codesign', '--verify', '--strict') and a[-1].startswith('/'):
        return 'codesign'
    if len(a) == 6 and a[:5] == ('/usr/bin/codesign', '-d', '--xml', '--entitlements', '-') and a[-1].startswith('/'):
        return 'codesign'
    if a[:2] == ('/usr/bin/xcrun', 'simctl'):
        if origin.lane == 'recording':
            if len(a) == 5 and a[2] == 'launch' and a[3] and a[4]: return 'simctl'
            if len(a) == 6 and a[2] == 'spawn' and a[3] and a[4:] == ('launchctl','list'): return 'simctl'
        if a[2:] in (('list', 'devices', '--json'), ('list', 'runtimes', '--json')): return 'simctl'
        if len(a) == 6 and a[2] == 'get_app_container' and a[3] and a[4] and a[5] in ('app', 'data'): return 'simctl'
    if len(a) == 10 and a[:5] == ('/usr/bin/xcrun', 'devicectl', 'device', 'info', 'displays') and a[5] == '--device' and a[6] and a[7:9] == ('--quiet', '--json-output') and a[9].startswith('/'):
        require(origin.lane in ('display', 'display-passive', 'display-synchronous'), 'display-lane')
        return 'devicectl'
    raise Rejected('unsupported-origin-argv')


def root_states(tool, argv):
    if tool in WRAPPERS:
        shell = WRAPPERS[tool][0]; script = wrapper(tool); native = resources(tool) + '/bin/' + tool
        tail = argv[2:]
        return ((argv[0], argv), (shell, (shell, script) + tail), (native, (native,) + tail))
    if tool == 'xcodebuild':
        return (('/usr/bin/xcodebuild', argv), (wrapper(tool), (wrapper(tool), '-version')))
    return ((argv[0], argv),)


def match(config, origin, observed, previous=None):
    """Match one full row; previous is the last Match for this same PID/start.

    Caller must retain previous matches through partial observations, and verify
    native parent/start edges. A mixed exec read must be retried, never admitted.
    """
    require(isinstance(config, Configuration) and config.developer == DEVELOPER and
            set(dict(config.hashes)) == set(required_paths()), 'invalid-configuration')
    tool = origin_tool(origin)
    require(tool == 'devicectl' or origin.lane in ('capture','recording'), 'wrong-origin-lane')
    observed.identity.validate()
    require(observed.edges_verified, 'unverified-parent-edges')
    require(observed.identity.group == origin.identity.group, 'wrong-group')
    require(isinstance(observed.argv, tuple), 'invalid-observed-argv')
    states = root_states(tool, origin.argv)
    limits = (('origin', 1), ('shell-child', 2 if tool == 'simctl' else 1),
              ('plist', 1), ('sort', 1 if tool == 'simctl' else 0),
              ('head', 1 if tool == 'simctl' else 0), ('total', 5 if tool == 'simctl' else 3)) if tool in WRAPPERS else (('origin', 1), ('total', 1))
    if observed.identity.key == origin.identity.key:
        require(not observed.ancestors and observed.identity.parent == origin.parent.pid, 'wrong-origin-parent')
        state = (observed.identity.path, observed.argv)
        require(state in states, 'unsupported-root-exec-or-argv')
        phase = states.index(state); role = 'origin'
        chain = states[phase:]
    else:
        require(tool in WRAPPERS, 'unexpected-tool-child')
        ancestors = observed.ancestors
        require(1 <= len(ancestors) <= 2, 'wrapper-depth')
        require(ancestors[-1].identity.key == origin.identity.key, 'wrong-origin-ancestor')
        child = observed
        for index, parent in enumerate(ancestors):
            parent.identity.validate()
            require(parent.ancestors == ancestors[index + 1:], 'inconsistent-ancestor-context')
            require(parent.edges_verified and parent.identity.group == origin.identity.group and child.identity.parent == parent.identity.pid, 'wrong-parent-or-group')
            require(parent.identity.key != child.identity.key, 'cyclic-ancestry')
            require((parent.identity.path, parent.argv) == states[1], 'parent-not-wrapper-shell')
            child = parent
        require(ancestors[-1].identity.parent == origin.parent.pid, 'wrong-origin-parent')
        script_state = states[1]
        state = (observed.identity.path, observed.argv)
        if state == script_state:
            require(tool == 'simctl' or len(ancestors) == 1, 'devicectl-shell-depth')
            role = 'shell-child'; phase = 0
            # Alternatives are terminal helpers, never the final native tool.
            chain = (script_state, ('/usr/libexec/PlistBuddy',
                     ('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', resources(tool) + '/Info.plist')))
            if tool == 'simctl':
                chain += (('/usr/bin/sort', ('sort', '--version-sort')),
                          ('/usr/bin/head', ('head', '-n1')))
        elif state == ('/usr/libexec/PlistBuddy', ('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', resources(tool) + '/Info.plist')):
            role = 'plist'; phase = 1; chain = (state,)
        elif tool == 'simctl' and state == ('/usr/bin/sort', ('sort', '--version-sort')):
            role = 'sort'; phase = 1; chain = (state,)
        elif tool == 'simctl' and state == ('/usr/bin/head', ('head', '-n1')):
            role = 'head'; phase = 1; chain = (state,)
        else:
            raise Rejected('unknown-wrapper-child-or-argv')
    if previous:
        require(previous.native_key == observed.identity.key, 'changed-native-identity')
        require(previous.origin_key == origin.identity.key and previous.provenance == origin.provenance, 'changed-origin')
        require((role == previous.role and phase >= previous.phase) or
                (previous.role == 'shell-child' and role in ('plist', 'sort', 'head')), 'reverse-or-unrelated-exec')
    return Match(role, chain, limits, origin.provenance, origin.identity.key, phase, observed.identity.key)


def validate_snapshot(config, origins, rows):
    """Origins include live/reserved invocations even when their root row is absent.

    rows: (Origin, Observation, prior Match or None). Complete owned inventory is
    caller responsibility; absence never releases an origin or its reservations.
    Counts aggregate native aliases and partial root observations by PID/start.
    """
    require(len({o.identity.key for o in origins}) == len(origins), 'duplicate-origin')
    displays = [o for o in origins if origin_tool(o) == 'devicectl']
    # The pinned source bounds concurrent callers. Native argv does not identify
    # which Swift queue submitted a particular invocation; do not invent that join.
    require(len(displays) <= DISPLAY_LIMIT, 'display-concurrency')
    registered = {o.identity.key: o for o in origins}
    counts = {k: {'origin': 1, 'total': 1} for k in registered}
    seen = set(); results = []
    for origin, row, prior in rows:
        require(registered.get(origin.identity.key) == origin, 'unregistered-origin')
        require(row.identity.key not in seen, 'duplicate-native-identity')
        seen.add(row.identity.key)
        result = match(config, origin, row, prior); results.append(result)
        bucket = counts[origin.identity.key]
        if result.role != 'origin':
            bucket[result.role] = bucket.get(result.role, 0) + 1
            bucket['total'] += 1
        for role, limit in result.child_limits:
            require(bucket.get(role, 0) <= limit, 'too-many-' + role)
    return tuple(results)
