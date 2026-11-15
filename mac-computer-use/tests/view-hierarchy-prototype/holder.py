"""A separate debugger owning only the runner's disposable fixture."""
import os
import time
import lldb
import subprocess

values = subprocess.check_output([os.environ['MAC_CU_FIXTURE_PATH'], 'probe', os.environ['MAC_CU_FIXTURE_PID']], text=True, timeout=3).split()
if values[1] + ':' + values[2] != os.environ['MAC_CU_FIXTURE_ID'] or int(values[5]) != int(os.environ['MAC_CU_FIXTURE_OWNER']):
    raise RuntimeError('fixture identity or owner changed')
target = debugger.CreateTarget('')
error = lldb.SBError()
process = target.AttachToProcessWithID(debugger.GetListener(), int(os.environ['MAC_CU_FIXTURE_PID']), error)
try:
    with open(os.environ['MAC_CU_HOLDER_READY'], 'w') as ready:
        ready.write('error: ' + str(error) if error.Fail() else 'attached')
    deadline = time.monotonic() + 25
    while not os.path.exists(os.environ['MAC_CU_HOLDER_RELEASE']) and time.monotonic() < deadline:
        time.sleep(.1)
finally:
    if process.IsValid() and process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
        process.Detach(False)
