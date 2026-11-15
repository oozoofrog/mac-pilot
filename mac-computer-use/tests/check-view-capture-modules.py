#!/usr/bin/env python3
"""Actual selected-LLDB type checking only. Never launches, attaches, connects or permits JIT."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
TESTS = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--resources', type=Path, default=TESTS.parent / 'skills/mac-computer-use/scripts/view-capture')
args = parser.parse_args()
args.output.mkdir(mode=0o700, exist_ok=False)
spec = importlib.util.spec_from_file_location('module_capture', args.resources / 'capture.py')
capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)
server, python, sdk = capture.tools_for_xcode()
sys.path.insert(0, str(python))
import lldb

debugger = lldb.SBDebugger.Create()
debugger.SetAsync(False)
report = {'pythonVersion': sys.version.split()[0], 'lldbVersion': lldb.SBDebugger.GetVersionString(), 'allowJIT': False, 'passed': False, 'attachOrServerStarted': False, 'expressionBodiesExecuted': False, 'checks': []}
try:
    old = debugger.CreateTarget('')
    report['oldDefaultContext'] = capture.compiler_context(debugger, old, '')
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetAllowJIT(False)
    options.SetPrefix((args.resources / 'imports.h').read_text())
    baseline, baseline_context = capture.configure_target(debugger, lldb, str(args.fixture.resolve()), sdk, lambda: None)
    report['prefixBaselineContext'] = baseline_context
    failed = baseline.EvaluateExpression('(unsigned long)sizeof((BOOL)[NSThread isMainThread])', options)
    report['oldPrefixError'] = str(failed.GetError())
    assert failed.GetError().Fail() and 'Foundation' in str(failed.GetError()) and not baseline.GetProcess().IsValid()

    target, context = capture.configure_target(debugger, lldb, str(args.fixture.resolve()), sdk, lambda: None)
    report['configuredContext'] = context
    assert [json.loads(v) if v.startswith(chr(34)) else v for v in context['sdkSetting']] == [str(sdk)]
    assert context['platform'] == 'ios-simulator' and context['triple'].endswith('-simulator')
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetAllowJIT(False)
    options.SetTimeoutInMicroSeconds(8000000)
    options.SetUnwindOnError(True)
    options.SetTrapExceptions(True)
    never_written = args.output / 'expression-body-must-not-run.json'
    expressions = [('mainThreadProof', '(BOOL)[NSThread isMainThread]', 1),
                   ('supportLibraryLoad', '(void *)dlopen("/usr/lib/libViewDebuggerSupport.dylib", 2)', 8),
                   ('UIKitTypes', '(CGRect){0, 0, 1, 1}', 32),
                   ('fullCollector', capture.collection_expression(never_written), 1)]
    for name, expression, expected in expressions:
        assert not target.GetProcess().IsValid()
        value = target.EvaluateExpression('(unsigned long)sizeof(' + expression + ')', options)
        report['checks'].append({'name': name, 'error': str(value.GetError()), 'size': value.GetValueAsUnsigned(),
                                 'processValid': target.GetProcess().IsValid()})
        assert value.GetError().Success(), str(value.GetError())
        assert value.GetValueAsUnsigned() == expected and not target.GetProcess().IsValid()
    assert not never_written.exists()
    report['passed'] = True
finally:
    lldb.SBDebugger.Destroy(debugger)
    (args.output / 'module-check.json').write_text(json.dumps(report, indent=2))
print('PASS actual LLDB Simulator target/module/type checks; no process/JIT/attach/server:', args.output)
