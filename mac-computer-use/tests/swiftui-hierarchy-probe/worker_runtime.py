"""독립 debugger worker의 인터프리터와 선택한 Xcode 바인딩을 고정한다."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import sysconfig

HERE = Path(__file__).resolve().parent
SCHEMA = 1


def worker_env():
    return {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'PYTHON', 'MAC_CU_'))}


def identity():
    return dict(executable=str(Path(sys.executable).resolve()), version=sys.version,
                cacheTag=sys.implementation.cache_tag, soabi=sysconfig.get_config_var('SOABI'),
                machine=platform.machine(), prefix=sys.prefix, basePrefix=sys.base_prefix, execPrefix=sys.exec_prefix)


def file_pin(path):
    path = Path(path)
    return dict(path=str(path), resolved=str(path.resolve(strict=True)),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def context(bound_developer=None):
    developer = Path(bound_developer) if bound_developer else Path(
        subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True, timeout=3).strip())
    resources = developer.parent / 'SharedFrameworks/LLDB.framework/Resources'
    python = resources / 'Python'
    package = python / 'lldb'
    extensions = sorted(package.glob('_lldb*.so'))
    if not extensions or not (package / '__init__.py').is_file():
        raise RuntimeError('선택한 Xcode의 LLDB Python 모듈이 없습니다')
    paths = [Path(sys.executable), developer.parent / 'version.plist', resources.parent / 'LLDB',
             resources / 'debugserver', *sorted(package.rglob('*.py')), *extensions]
    return dict(developer=str(developer), developerResolved=str(developer.resolve(strict=True)),
                developerOverride=os.environ.get('DEVELOPER_DIR'), pythonPath=str(python),
                files=[file_pin(path) for path in paths])


def isolated_report(python_path):
    # LLDBEngine과 같은 -I 스크립트에서 같은 경로를 첫 항목에 삽입한다.
    if not sys.flags.isolated:
        raise RuntimeError('독립 -I 실행이 필요합니다')
    sys.path.insert(0, python_path)
    import lldb
    from lldb import _lldb
    expected = Path(python_path) / 'lldb'
    module = file_pin(lldb.__file__)
    extension = file_pin(_lldb.__file__)
    if Path(lldb.__file__).resolve() != (expected / '__init__.py').resolve():
        raise RuntimeError('다른 LLDB Python 패키지를 불러왔습니다')
    if Path(_lldb.__file__) not in expected.glob('_lldb*.so'):
        raise RuntimeError('다른 LLDB 확장을 불러왔습니다')
    # 디버거 생성 없이 실제 native binding을 호출한다.
    version = lldb.SBDebugger.GetVersionString()
    if not version or not hasattr(_lldb, 'SBDebugger_Create'):
        raise RuntimeError('LLDB native binding을 확인할 수 없습니다')
    return dict(identity=identity(), isolated=True, module=module, extension=extension, lldbVersion=version)


def prove():
    before = context()
    command = [sys.executable, '-I', str(HERE / 'debugger.py'), '--check-worker-runtime', before['pythonPath']]
    result = subprocess.run(command, env=worker_env(), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError('Standalone LLDB import failed with ' + str(sys.executable) +
                           '; explicitly invoke preparation and runner with a compatible Python. No fallback.\n' + result.stderr[-12000:])
    proof = dict(schema=SCHEMA, context=before, capability=json.loads(result.stdout))
    verify(proof)
    return proof


def verify(proof, bound_worker=False):
    if not isinstance(proof, dict) or proof.get('schema') != SCHEMA:
        raise RuntimeError('Missing standalone worker runtime proof; explicit compatible preparation required')
    capability = proof.get('capability', {})
    if capability.get('identity') != identity() or capability.get('isolated') is not True:
        raise RuntimeError('Worker interpreter changed or unverified; rerun explicit compatible preparation')
    # 자식 worker는 감독자가 검증한 고정 경로를 사용한다. 하위 도구를 생성하지 않는다.
    current = context(proof['context']['developer']) if bound_worker else context()
    if proof.get('context') != current:
        raise RuntimeError('Stale worker runtime proof: Xcode/LLDB/interpreter inputs changed')
    for key in ('module', 'extension'):
        pin = capability.get(key, {})
        if pin not in current['files']:
            raise RuntimeError('LLDB binding does not match selected Xcode: ' + key)
    if not capability.get('lldbVersion'):
        raise RuntimeError('Missing native LLDB binding capability')
