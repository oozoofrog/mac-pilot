import Foundation
import Darwin

guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"],
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    do {
        let value = try simulatorViewCaptureTarget(pid: 123, deviceID: "abcdefab-1234-4567-89ab-abcdefabcdef")
        guard interpreterCalls == 0 else {
            fputs("FAIL identity read launched interpreter route\n", stderr); exit(1)
        }
        guard nativeCalls == 1, value.pid == 123, value.start == [41, 42], value.path == "/native/target",
              value.deviceID == "ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF" else {
            fputs("FAIL native identity was not forwarded intact\n", stderr); exit(1)
        }
        print("PASS canonical identity caller uses one native read and zero interpreter calls")
        done.signal()
    } catch { fputs("FAIL identity caller: \(error)\n", stderr); exit(1) }
}
guard done.wait(timeout: .now() + 5) == .success else { exit(1) }
