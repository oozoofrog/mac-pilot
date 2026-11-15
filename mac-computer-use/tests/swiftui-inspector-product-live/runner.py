"""Explicit owned SwiftUI launch; shared product UI/session/watchdog unchanged."""
import importlib.util, json, sys
from pathlib import Path
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('inspector_runner',HERE.parent/'simulator-inspector-product-live/runner.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)

def main():
    # Explicit harness lane only; these flags never enter the product helper or fixture restart.
    recording = '--recording-transition' in sys.argv[1:]
    if recording: sys.argv.remove('--recording-transition')
    r.RECORDING_TRANSITION = recording
    args=sys.argv[1:]
    build=Path(args[1] if args[0] in ('--worker','--worker-guard') else args[args.index('--build')+1])
    r.s.verify_prepared(build)
    app=json.loads((build/'prepared.json').read_text())['ordinaryProductApp']
    assert app['entry']=='SwiftUI.App' and app['launchFlag']=='287'
    r.s.BUNDLE=app['bundleID'];r.s.APP_NAME='SwiftUIProbe.app';r.s.EXECUTABLE='SwiftUIProbe'
    original=r.s.fixture_launch_arguments
    if not recording:
        r.s.fixture_launch_arguments=lambda device,token: ['/usr/bin/env','SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287',*original(device,token)]
    r.__file__=str(Path(__file__).resolve())
    if recording:
        original_parent = r.s.parent
        def parent(*args, **kwargs):
            kwargs['worker_arguments'] = [*kwargs.get('worker_arguments',()), '--recording-transition']
            return original_parent(*args, **kwargs)
        r.s.parent = parent
    return r.main()
if __name__=='__main__':raise SystemExit(main())
