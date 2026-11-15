"""Canonical mac-cu mixed Swift/Objective-C compilation (no launch or install)."""
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent / 'mac-cu-src'
# Declarations-only interfaces of private frameworks, emitted as .swiftmodule files before the main compile and
# never linked: the product links the real frameworks weakly and checks their ABI at run time. Dependencies first.
STUB_MODULES = ('CoreDeviceUtilities', 'CoreDevice')
STUB_FOLDER = 'CoreDeviceStubs'
PRIVATE_FRAMEWORKS = '/Library/Developer/PrivateFrameworks'


def native_inputs(source=SOURCE):
    """Inputs beyond Swift sources that must participate in frozen build evidence."""
    return [Path(source) / 'SimulatorAXAdapter.h',
            Path(source) / 'SimulatorAXAdapter.m',
            *[Path(source) / STUB_FOLDER / f'{name}.swift' for name in STUB_MODULES], Path(__file__).resolve()]


def emit_stub_modules(directory, *, source=SOURCE, **kwargs):
    """Emit the stub .swiftmodule files into directory; returns the first failed CompletedProcess or None.

    Library evolution keeps every stub type opaque, so the client reaches it only through the real framework's
    metadata. Compiler output follows the caller's subprocess options; the bodies' "never executed" warnings are
    silenced with -suppress-warnings.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name in STUB_MODULES:
        emitted = subprocess.run(['swiftc', '-emit-module', '-parse-as-library', '-enable-library-evolution',
                                  '-suppress-warnings', '-module-name', name, '-I', str(directory),
                                  str(Path(source) / STUB_FOLDER / f'{name}.swift'),
                                  '-emit-module-path', str(directory / f'{name}.swiftmodule')], **kwargs)
        if emitted.returncode:
            return emitted
    return None


def coredevice_flags(modules):
    """Search paths for the stub modules and weak links to the frameworks they stand for (absolute install names)."""
    return ['-I', str(modules), '-F', PRIVATE_FRAMEWORKS,
            '-Xlinker', '-weak_framework', '-Xlinker', 'CoreDevice',
            '-Xlinker', '-weak_framework', '-Xlinker', 'CoreDeviceUtilities',
            '-Xlinker', '-rpath', '-Xlinker', '/Library/Apple/System/Library/PrivateFrameworks',
            '-Xlinker', '-rpath', '-Xlinker', PRIVATE_FRAMEWORKS]


def run_swift(command, *, source=SOURCE, **kwargs):
    """Run a swiftc command with the adapter, forwarding subprocess.run options.

    Compiler failures retain the caller's check/capture/log semantics. Objects live
    only through the link, outside the app bundle and distribution source tree.
    The caller supplies its original Swift flags, sources and output path.
    """
    command = list(map(str, command))
    source = Path(source).resolve()
    header = ['-import-objc-header', str(source / 'SimulatorAXAdapter.h')]
    with tempfile.TemporaryDirectory(prefix='mac-cu-native-build-') as directory:
        modules = Path(directory) / 'modules'
        failed = emit_stub_modules(modules, source=source, **kwargs)
        if failed is not None:
            return failed
        coredevice = coredevice_flags(modules)
        if '-typecheck' in command:
            return subprocess.run([*command, *header, *coredevice], **kwargs)
        obj = str(Path(directory) / 'SimulatorAXAdapter.o')
        flags = []
        for index, flag in enumerate(command):
            if flag in ('-target', '-sdk'):
                flags.extend([ '-isysroot' if flag == '-sdk' else flag, command[index + 1]])
            elif flag in ('-g', '-O', '-Onone'):
                flags.append('-O0' if flag == '-Onone' else flag)
        compiled = subprocess.run(['clang', '-fobjc-arc', '-fobjc-exceptions',
                                   '-fobjc-arc-exceptions', '-fblocks', '-Wall', '-Wextra', '-Werror', *flags,
                                   '-c', str(source / 'SimulatorAXAdapter.m'), '-o', obj], **kwargs)
        if compiled.returncode:
            return compiled
        linked = subprocess.run([*command, *header, *coredevice, obj], **kwargs)
        # Preserve successful clang diagnostics for capture_output callers too.
        for name in ('stdout', 'stderr'):
            before, after = getattr(compiled, name), getattr(linked, name)
            if before is not None and after is not None:
                setattr(linked, name, before + after)
        return linked


if __name__ == '__main__':
    # native_build.py --emit-stub-modules DIR: only the stub modules, for checks that compile selected sources
    # (add the flags printed on stdout). Otherwise: swiftc arguments for the whole product.
    if sys.argv[1:2] == ['--emit-stub-modules'] and len(sys.argv) == 3:
        failed = emit_stub_modules(Path(sys.argv[2]).resolve())
        if failed is None:
            print(' '.join(coredevice_flags(Path(sys.argv[2]).resolve())))
        raise SystemExit(failed.returncode if failed is not None else 0)
    raise SystemExit(run_swift(['swiftc', *sys.argv[1:]]).returncode)


def build_view_capture_resources(destination):
    """Canonical resource packaging: compile the resident from source, then sign it.

    No target app is touched. Both setup and isolated preparations use this entry.
    The generated image/provenance live only in the requested build directory.
    """
    import hashlib
    import json
    import re
    import shutil
    root = Path(__file__).resolve().parent / 'view-capture'
    destination = Path(destination)
    shutil.copytree(root, destination, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    def output(args):
        return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=15).strip()
    developer = Path(output(['/usr/bin/xcode-select', '-p'])).resolve()
    sdk = Path(output(['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])).resolve()
    clang = Path(output(['/usr/bin/xcrun', '--find', 'clang++'])).resolve()
    image = destination / 'mac-cu-resident-v2.dylib'
    swift = Path(output(['/usr/bin/xcrun', '--find', 'swiftc']))
    bridge = destination / 'SwiftUIBridge.o'
    resident = destination / 'resident.o'
    common = ['-target', 'arm64-apple-ios17.0-simulator', '-sdk', str(sdk), '-parse-as-library']
    swift_command = [str(swift), *common, '-module-name', 'MacCUResidentBridge', '-emit-object',
                     '-emit-objc-header-path', str(destination / 'SwiftUIBridge-Swift.h'),
                     str(root / 'SwiftUIBridge.swift'), '-o', str(bridge)]
    subprocess.run(swift_command, check=True, timeout=90)
    command = [str(clang), '-std=c++17', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', str(sdk),
               '-fno-objc-arc', '-fobjc-exceptions', '-fexceptions', '-fmodules', '-fcxx-modules', '-fblocks', '-Wall', '-Wextra', '-Werror',
               '-Wno-deprecated-declarations', '-I', str(destination), '-c', str(root / 'resident.mm'),
               '-o', str(resident)]
    subprocess.run(command, check=True, timeout=90)
    link_command = [str(swift), *common, '-emit-library', str(bridge), str(resident),
                    '-framework', 'UIKit', '-framework', 'SwiftUI', '-lc++',
                    '-Xlinker', '-install_name', '-Xlinker', '@rpath/mac-cu-resident-v2.dylib', '-o', str(image)]
    subprocess.run(link_command, check=True, timeout=90)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(image)], check=True, timeout=15)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(image)], check=True, timeout=15)
    uuid = re.search(r'UUID: ([A-F0-9-]{36})', output(['/usr/bin/xcrun', 'dwarfdump', '--uuid', str(image)]))[1]
    framework = developer.parent / 'SharedFrameworks/LLDB.framework'
    sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
    manifest = {'abi': 2, 'image': image.name, 'uuid': uuid, 'sha256': sha(image),
                'architecture': output(['/usr/bin/xcrun', 'lipo', '-archs', str(image)]),
                'xcodeVersion': output(['/usr/bin/xcodebuild', '-version']),
                'developer': str(developer), 'sdk': str(sdk), 'sdkSHA256': sha(sdk / 'SDKSettings.json'),
                'lldbSHA256': sha((framework / 'LLDB').resolve()),
                'debugserverSHA256': sha((framework / 'Resources/debugserver').resolve()),
                'swiftCompilerSHA256': sha(swift), 'swiftVersion': output([str(swift), '--version']),
                'swiftCommand': swift_command, 'linkCommand': link_command,
                'swiftInterfaceSHA256': sha(sdk / 'System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64-apple-ios-simulator.swiftinterface'),
                'compilerSHA256': sha(clang), 'command': command, 'signature': 'verified ad-hoc Simulator image',
                'sources': {p.name: sha(p) for p in root.iterdir() if p.is_file()}}
    if manifest['architecture'] != 'arm64':
        raise RuntimeError('Resident architecture mismatch')
    (destination / 'resident-build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    bridge.unlink(); resident.unlink()
    return manifest
