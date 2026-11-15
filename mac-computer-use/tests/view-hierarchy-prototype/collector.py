"""LLDB script for an owned fixture only. Not a production capture API."""
import json
import os
import subprocess
import lldb

pid = int(os.environ['MAC_CU_FIXTURE_PID'])
probe_path = os.environ['MAC_CU_FIXTURE_PATH']
expected = os.environ['MAC_CU_FIXTURE_ID']
owner = int(os.environ['MAC_CU_FIXTURE_OWNER'])
mode = os.environ['MAC_CU_FIXTURE_MODE']
result_path = os.environ['MAC_CU_FIXTURE_RESULT']
record = {'mode': mode, 'pid': pid, 'attached': False, 'detach': 'not attempted'}
process = None

def probe():
    output = subprocess.check_output([probe_path, 'probe', str(pid)], text=True, timeout=3).split()
    return {'pid': int(output[0]), 'start': output[1] + ':' + output[2],
            'state': int(output[3]), 'traced': int(output[4]), 'parent': int(output[5])}

try:
    before = probe()
    record['before'] = before
    # Status 4 is SSTOP; 5 is SZOMB. Fail closed for creation/unknown states.
    if before['start'] != expected or before['parent'] != owner or before['state'] not in (2, 3) or before['traced']:
        record['outcome'] = 'preflight rejected'
    else:
        debugger.SetAsync(False)
        target = debugger.CreateTarget('')
        error = lldb.SBError()
        process = target.AttachToProcessWithID(debugger.GetListener(), pid, error)
        if error.Fail() or not process.IsValid():
            record['outcome'] = 'attach failed'
            record['error'] = str(error)
        else:
            record['attached'] = True
            attached = probe()
            record['afterAttach'] = attached
            if attached['start'] != before['start'] or attached['pid'] != pid:
                record['outcome'] = 'identity mismatch'
            else:
                with open(os.environ['MAC_CU_EXPRESSION_READY'], 'w') as marker:
                    marker.write('about to evaluate')
                options = lldb.SBExpressionOptions()
                options.SetLanguage(lldb.eLanguageTypeC)
                options.SetTimeoutInMicroSeconds(500000 if mode == 'timeout' else 30000000)
                options.SetUnwindOnError(True)
                expressions = {'success': '1 + 1', 'error': 'mac_cu_missing_symbol',
                               'timeout': '(unsigned int)sleep(30)', 'cancel': '(unsigned int)sleep(30)',
                               'exit': '(void)exit(0)'}
                value = process.GetSelectedThread().GetFrameAtIndex(0).EvaluateExpression(expressions[mode], options)
                record['expressionError'] = str(value.GetError())
                record['expressionSucceeded'] = value.GetError().Success()
                record['outcome'] = 'expression returned'
except BaseException as error:
    record['outcome'] = 'interrupted or failed'
    record['error'] = repr(error)
finally:
    if record['attached'] and process and process.IsValid():
        try:
            if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
                detached = process.Detach(False)
                record['detach'] = 'success' if detached.Success() else str(detached)
            else:
                record['detach'] = 'already exited or detached'
        except BaseException as error:
            record['detach'] = repr(error)
    try:
        record['after'] = probe()
    except Exception as error:
        record['after'] = {'unavailable': str(error)}
    with open(result_path, 'w') as result:
        json.dump(record, result, indent=2)
