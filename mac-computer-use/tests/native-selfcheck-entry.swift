import Foundation

/// UI-only selfchecks have no production helper routes. Reject every non-root
/// argument and inherited root entry before creating NSApplication or a window.
func admitNativeSelfcheck() {
    guard Array(CommandLine.arguments.dropFirst()) == ["--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
    setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
}
