#!/usr/bin/env python3
"""Parse the complete canonical edit expression in selected LLDB; no process or JIT."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(mode=0o700, exist_ok=False)
resources = HERE.parents[1] / 'skills/mac-computer-use/scripts/view-capture'
spec = importlib.util.spec_from_file_location('edit_module_capture', resources / 'capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
_, python, sdk = capture.tools_for_xcode()
sys.path.insert(0, str(python))
import lldb

debugger = lldb.SBDebugger.Create()
debugger.SetAsync(False)
report = {'passed': False, 'allowJIT': False, 'attachOrServerStarted': False,
          'expressionBodiesExecuted': False, 'lldbVersion': lldb.SBDebugger.GetVersionString(),
          'pythonVersion': sys.version, 'checks': []}
try:
    target, report['compilerContext'] = capture.configure_target(
        debugger, lldb, str(args.fixture.resolve()), sdk, lambda: None)
    imported = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand('expression -j false -l objc++ -- @import ObjectiveC', imported)
    assert imported.Succeeded(), imported.GetError()
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetAllowJIT(False)
    options.SetAutoApplyFixIts(False)
    options.SetTimeoutInMicroSeconds(8000000)
    never_written = args.output / 'expression-body-must-not-run.json'
    expression = capture.edit_backend.expression({}, never_written)
    (args.output / 'expression.mm').write_text(expression)
    # Exercise the actual scalar predicate outside sizeof: an SDK inline wrapper
    # can type-check yet need a missing target symbol when LLDB does not inline it.
    finite = re.search(r'if \(!([a-z_]+isfinite|isfinite)\(alpha\)', expression).group(1)
    for name, source, expected in [
            ('MRC', '(unsigned long)__has_feature(objc_arc)', 0),
            ('debuggerOwnedExceptionTrap', '(unsigned long)(0\n#ifdef OBJC_ZEROCOST_EXCEPTIONS\n | 2\n#endif\n)', 0),
            ('canonicalEditableExpression', '(unsigned long)sizeof(' + expression + ')', 1),
            ('finiteValue', '(unsigned long)' + finite + '(0.5)', 1),
            ('infiniteValue', '(unsigned long)' + finite + '(__builtin_inf())', 0),
            ('nanValue', '(unsigned long)' + finite + '(__builtin_nan(""))', 0)]:
        assert not target.GetProcess().IsValid()
        value = target.EvaluateExpression(source, options)
        report['checks'].append({'name': name, 'error': str(value.GetError()),
                                 'value': value.GetValueAsUnsigned(), 'processValid': target.GetProcess().IsValid()})
        assert value.GetError().Success(), str(value.GetError())
        assert value.GetValueAsUnsigned() == expected
        assert not target.GetProcess().IsValid() and not never_written.exists()
    report['passed'] = True
finally:
    lldb.SBDebugger.Destroy(debugger)
    (args.output / 'module-check.json').write_text(json.dumps(report, indent=2))
print('PASS actual LLDB canonical editable-expression type check; no process/JIT/attach:', args.output)
