import Foundation

@main
struct SimulatorHostActionsSelfcheck {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Timed out waiting for callback")
    }
    static func main() throws {
        admitNativeSelfcheck()
        let standard: [[String:Any]] = [["displayId":1,"type":["integrated":[:]]]]
        precondition(simulatorRecordingDisplayID(activeID: nil,displays: standard) == "1")
        precondition(simulatorRecordingDisplayID(activeID: "2",displays: nil) == "2")
        precondition(simulatorRecordingDisplayID(activeID: nil,displays: standard + standard) == nil)
        precondition(simulatorRecordingDisplayID(activeID: nil,displays: nil) == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake-simctl")
        let script = """
        #!/bin/sh
        if [ "$2" = "ui" ]; then
            if [ "$#" = 4 ]; then echo dark; fi
            exit 0
        fi
        if [ "$2" = "location" ]; then exit 0; fi
        if [ "$2" = "io" ]; then
            case "$5" in
                --display=early) echo failed >&2; exit 1 ;;
                --display=slow) sleep 30 ;;
                *) printf 'movie fixture' > \"$6\"; echo 'Recording started' >&2; trap 'exit 0' INT; while :; do sleep 0.1; done ;;
            esac
        fi
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let actions = SimulatorHostActions(deviceID: "00000000-0000-0000-0000-000000000001", executable: fake, timeout: 2)
        var states: [(String, Bool)] = [], recordings: [(Bool, String)] = []
        actions.onState = { states.append(($0, $1)) }
        actions.onRecording = { recordings.append(($0, $1)) }
        actions.run(option: "location", value: "91,0")
        wait { states.contains { $0.1 } }
        states.removeAll()
        actions.run(option: "appearance", value: "dark")
        wait { states.contains { $0.0 == "appearance: dark" && !$0.1 } }
        states.removeAll()
        actions.run(option: "location", value: "1.5,-2.5")
        wait { states.contains { $0.0.contains("확인되지 않았습니다") } }
        actions.startRecording(to: dir.appendingPathComponent("early.mov"), display: "early")
        wait { recordings.count == 1 }
        precondition(recordings.allSatisfy { !$0.0 }, "Early exit reported a recording")
        recordings.removeAll()
        actions.startRecording(to: dir.appendingPathComponent("ok.mov"), display: "primary")
        wait { recordings.contains { $0.0 } }
        actions.stopRecording()
        wait { recordings.contains { !$0.0 && $0.1.contains("저장됨") } }
        actions.close()
        print("SimulatorHostActions headless checks passed")
    }
}
