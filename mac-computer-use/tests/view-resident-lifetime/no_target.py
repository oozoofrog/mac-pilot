"""Imported only by selected LLDB --no-lldbinit; no process is created or attached."""
import importlib.util
import json
import os
from pathlib import Path
import sys


def __lldb_init_module(debugger, _):
    import lldb
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('resident_debugger_check', here / 'debugger.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    out = Path(os.environ['RESIDENT_PREPARE_OUTPUT'])
    report = {'passed': False, 'processCreated': False, 'guestLoaded': False}
    try:
        assert all(not debugger.GetTargetAtIndex(i).GetProcess().IsValid() for i in range(debugger.GetNumTargets()))
        image = out / 'resident-simulator.dylib'
        sdk = Path(os.environ['RESIDENT_SELECTED_SDK'])
        target, compiler = module.c.configure_target(debugger, lldb, str(image), sdk, lambda: None)
        assert not target.GetProcess().IsValid()
        required = [(lldb.SBProcess, 'LoadImage'), (lldb.SBProcess, 'Detach'),
                    (lldb.SBExpressionOptions, 'SetStopOthers'), (lldb.SBExpressionOptions, 'SetTrapExceptions'),
                    (lldb.SBExpressionOptions, 'SetUnwindOnError')]
        report['APIs'] = {cls.__name__ + '.' + name: getattr(cls, name).__doc__ for cls, name in required}
        invalid = lldb.SBProcess(); error = lldb.SBError()
        token = invalid.LoadImage(lldb.SBFileSpec(str(image)), error)
        assert error.Fail() and token == lldb.LLDB_INVALID_IMAGE_TOKEN
        report['invalidProcessLoadRefused'] = {'token': token, 'error': str(error)}
        symbol = target.FindFunctions('mac_cu_resident_submit')
        assert symbol.GetSize() == 1
        entry = symbol.GetContextAtIndex(0).GetSymbol()
        assert entry.GetName() == 'mac_cu_resident_submit' and entry.GetType() == lldb.eSymbolTypeCode
        address = entry.GetStartAddress().GetFileAddress()
        image_module = target.GetModuleAtIndex(0)
        text_section = image_module.FindSection('__TEXT').FindSubSection('__text')
        assert text_section.IsValid() and text_section.GetFileAddress() <= address < text_section.GetFileAddress() + text_section.GetByteSize()
        report['fileTextSection'] = {'address': text_section.GetFileAddress(), 'bytes': text_section.GetByteSize(),
                                    'mappedSectionBytes': sum(image_module.GetSectionAtIndex(i).GetByteSize()
                                                              for i in range(image_module.GetNumSections()))}
        source = '(unsigned long)sizeof(' + module.submission(address, Path('/private/tmp/resident-control')) + ')'
        options = lldb.SBExpressionOptions(); options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetAllowJIT(False); options.SetAutoApplyFixIts(False)
        options.SetStopOthers(True); options.SetTrapExceptions(False); options.SetUnwindOnError(False)
        result = target.EvaluateExpression(source, options)
        assert result.GetError().Success() and result.GetValueAsUnsigned() == 4, str(result.GetError())
        assert not target.GetProcess().IsValid()
        report.update(passed=True, compiler=compiler, parsedExpression=source,
                      moduleUUID=target.GetModuleAtIndex(0).GetUUIDString(), selectedLLDB=lldb.SBDebugger.GetVersionString(),
                      publicLoaderGuestCapability='unverified; invalid-process API binding and parse only')
    except BaseException as error:
        report['error'] = repr(error)
    (out / 'no-target.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
