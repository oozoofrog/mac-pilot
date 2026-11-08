#!/usr/bin/env python3
"""Build and supervise the isolated, UI-only LCD design preview."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
SOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
sys.path.insert(0, str(TESTS))
from native_check_support import check_routes, run_owned


def build():
    out = Path(tempfile.mkdtemp(prefix='mac-cu-lcd-preview-'))
    app = out / 'LCD Design Preview.app'
    contents = app / 'Contents'
    binary = contents / 'MacOS/LCDPreview'
    binary.parent.mkdir(parents=True)
    with (contents / 'Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'dev.macpilot.lcd-design-preview',
                       'CFBundleExecutable': 'LCDPreview', 'CFBundleName': 'LCD Design Preview',
                       'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                       'NSHighResolutionCapable': True}, stream)
    # This one production action reads the real pasteboard before invoking onRun.
    # Compile an isolated derivative with that method removed, and fail closed if it changes.
    chrome = (SOURCE / 'SimulatorDeviceChrome.swift').read_text()
    start = chrome.index('    @objc private func paste() {')
    end = chrome.index('    @objc private func applyLocation()', start)
    original = chrome[start:end]
    if 'NSPasteboard.general' not in original or original.count('@objc private func') != 1:
        raise RuntimeError('Inspect the changed clipboard route before building the preview.')
    chrome = chrome[:start] + '    @objc private func paste() { showFeedback("Mock preview: clipboard unavailable") }\n' + chrome[end:]
    if 'NSPasteboard' in chrome:
        raise RuntimeError('Unexpected clipboard access in reused chrome.')
    isolated = out / 'SimulatorDeviceChrome.swift'
    isolated.write_text(chrome)
    toolbox = (SOURCE / 'SimulatorToolbox.swift').read_text()
    clipboard = 'NSPasteboard.general.string(forType: .string) ?? ""'
    if toolbox.count(clipboard) != 1 or toolbox.count('NSPasteboard') != 1:
        raise RuntimeError('Inspect the changed toolbox clipboard route before building.')
    isolated_toolbox = out / 'SimulatorToolbox.swift'
    isolated_toolbox.write_text(toolbox.replace(clipboard, '""'))
    names = ['SimulatorRotation.swift','SimulatorHingeSlider.swift','SimulatorDeviceContainer.swift',
             'SimulatorLCDContent.swift','SimulatorGesturePad.swift','SimulatorToolbarDocking.swift']
    cmd = ['swiftc','-parse-as-library',*[str(SOURCE / n) for n in names],str(isolated),str(isolated_toolbox),
           str(TESTS / 'native-selfcheck-entry.swift'),str(HERE / 'MockState.swift'),str(HERE / 'FeedbackTarget.swift'),str(HERE / 'FeedbackStore.swift'),str(HERE / 'Feedback.swift'),str(HERE / 'Preview.swift'),'-o',str(binary)]
    subprocess.run(cmd, check=True)
    return app, binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only',action='store_true')
    parser.add_argument('--seconds',type=int,default=900,help='Finite watchdog lifetime, 30–3600 seconds (default 900).')
    args = parser.parse_args()
    if not 30 <= args.seconds <= 3600:
        parser.error('--seconds must be between 30 and 3600')
    if 'MAC_CU_NATIVE_CHECK_CHILD' in os.environ:
        raise SystemExit('Inherited native-check entry is forbidden.')
    lock_path = Path(tempfile.gettempdir()) / f'mac-cu-lcd-preview-{os.getuid()}.lock'
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('A preview launcher is already active; close it before launching another.')
        app, binary = build()
        print(f'Built: {app}',flush=True)
        env = dict(os.environ)
        env.pop('LCD_PREVIEW_VERIFY_OUTPUT', None)
        check_routes(binary,env,sys.stdout,production_helper=False)
        print('PASS preview dispatch; one executable instance budget',flush=True)
        if args.build_only:
            return
        print(f'Preview watchdog deadline: {args.seconds}s. Close either window to exit.',flush=True)
        try:
            result = run_owned(binary,['--native-check'],environment=env,log=sys.stdout,timeout=args.seconds,max_instances=1)
        except TimeoutError:
            print('Preview lifetime expired; owned process cleaned.',flush=True)
            return
        if result:
            raise SystemExit(result)

if __name__ == '__main__':
    main()
