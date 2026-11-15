"""Compile the verbatim UI publisher; execute only under the native parent watchdog."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import native_check_support as safety


class RecordingWriter:
    def __init__(self, output=None):
        self.output = output or Path(tempfile.mkdtemp(prefix='mac-cu-recording-writer-', dir='/private/tmp'))
        if output is not None:
            self.output.mkdir(mode=0o700)
        source = (HERE / 'live.swift').read_text()
        start = source.index('func inspectorPublishRecordingArtifact(')
        writer = source[start:source.index('func runInspectorProductLive()', start)]
        (self.output / 'writer.swift').write_text('import Foundation\nimport Darwin\n' + writer)
        # The test seam changes the real filesystem immediately before the real atomic rename.
        # Writer bytes remain verbatim; no production test hooks or timing sleeps.
        (self.output / 'main.swift').write_text(r'''
import Foundation
import Darwin
struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }
func fsync(_ fd: Int32) -> Int32 {
    if ProcessInfo.processInfo.environment["BRIDGE_RACE"] == "sync-error" { errno = EIO; return -1 }
    return Darwin.fsync(fd)
}
func renameatx_np(_ fromFD: Int32, _ from: UnsafePointer<CChar>, _ toFD: Int32, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
    let race = ProcessInfo.processInfo.environment["BRIDGE_RACE"]
    if race == "rename-error" { errno = EIO; return -1 }
    if race == "parent" {
        let path = ProcessInfo.processInfo.environment["BRIDGE_PARENT"]!
        precondition(Darwin.rename(path, path + "-retained") == 0)
        precondition(mkdir(path, 0o700) == 0)
    }
    if race == "destination" || race == "staging" || race == "staging-refuse" {
        let name = race == "destination" ? to : from
        if race != "destination" { precondition(unlinkat(fromFD, from, 0) == 0) }
        let fd = openat(toFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        precondition(fd >= 0)
        let marker = Data("{\"foreign\":true}".utf8)
        precondition(marker.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == marker.count)
        close(fd)
        if race == "staging-refuse" { errno = EIO; return -1 }
    }
    // The exact final inode must already be complete, private and single-linked before publication.
    var info = stat()
    precondition(fstatat(fromFD, from, &info, AT_SYMLINK_NOFOLLOW) == 0)
    precondition(info.st_mode & 0o777 == 0o600 && info.st_nlink == 1 && info.st_size > 0)
    return Darwin.renameatx_np(fromFD, from, toFD, to, flags)
}
guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"],
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
umask(mode_t(ProcessInfo.processInfo.environment["BRIDGE_UMASK"]!, radix: 8)!)
let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRIDGE_INPUT"]!)
let request = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
let out = URL(fileURLWithPath: request["output"] as! String)
do {
    for (name, value) in request["files"] as! [String: Any] {
        try inspectorPublishRecordingArtifact(out, name, value)
    }
    print("PASS verbatim UI publisher")
} catch {
    fputs("REFUSED UI publication: \(error)\n", stderr); exit(1)
}
''')
        actual = self.output / 'actual'; actual.mkdir()
        main = (self.output / 'main.swift').read_text()
        guard = main.index('guard CommandLine.arguments')
        (actual / 'main.swift').write_text(main[:main.index('func fsync(')] + main[guard:])
        self.binary = actual / 'writer'
        self.adverse_binary = self.output / 'writer'
        with (self.output / 'compile.log').open('w') as log:
            for binary, entry in ((self.binary, actual / 'main.swift'), (self.adverse_binary, self.output / 'main.swift')):
                subprocess.run(['xcrun', 'swiftc', str(self.output / 'writer.swift'), str(entry),
                                '-o', str(binary)], check=True, timeout=60, stdout=log, stderr=subprocess.STDOUT)
        with (self.output / 'routes.log').open('w') as log:
            for binary in (self.binary, self.adverse_binary):
                safety.check_routes(binary, dict(os.environ), log, production_helper=False)
        self.count = 0

    def publish(self, output, files, *, mask='022', race=''):
        self.count += 1
        request = self.output / f'input-{self.count}.json'
        request.write_text(json.dumps(dict(output=str(output), files=files)))
        with (self.output / f'run-{self.count}.log').open('w') as log:
            return safety.run_owned(self.adverse_binary if race else self.binary, ['--native-check'],
                environment=dict(os.environ, BRIDGE_INPUT=str(request), BRIDGE_UMASK=mask, BRIDGE_RACE=race, BRIDGE_PARENT=str(output)),
                log=log, timeout=5, max_instances=1)
