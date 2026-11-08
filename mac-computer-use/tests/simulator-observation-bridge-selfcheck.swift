import Foundation
import XPC

private final class ObservationFixtureDevice: NSObject {
    let id = UUID()
    override func value(forKey key: String) -> Any? { key == "UDID" ? id as NSUUID : nil }
}

// Uses the real activeScreen -> observer bridge, with immutable display fixtures;
// no device lookup, XPC connection, daemon, AppKit application or simulator is opened.
func runSimulatorObservationBridgeCheck() -> Never {
    DispatchQueue.global().async {
        func wait(_ gate: DispatchSemaphore) { precondition(gate.wait(timeout: .now() + 5) == .success) }
        let device = ObservationFixtureDevice(), observed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let id = udid(of: device), lane = simulatorObserver(udid(of: device))
        let lock = NSLock(); var publishedOld = false
        lane.observe(read: { _ in observed.signal(); wait(release); return SimulatorObservedScreen(booted: true, screen: nil, angle: nil) }, receive: { _ in lock.withLock { publishedOld = true } })
        wait(observed)
        let ticket = lane.ticket
        let raw: [[String: Any]] = [["type": ["integrated": [:]], "active": true, "displayId": 1,
            "currentOrientation": "rot90", "bounds": [[0,0],[600,900]], "pointScale": 3, "primary": true]]
        let fresh = try! handleQueue.sync { try activeScreen(of: device, readback: raw) }
        precondition(fresh?.rotation == "rot90")
        precondition(!lane.isCurrent(ticket), "Synchronous external read must revoke older passive sample")
        let newRead = DispatchSemaphore(value: 0)
        lane.observe(read: { _ in SimulatorObservedScreen(booted: true, screen: fresh, angle: nil) }, receive: { value in precondition(value.screen?.rotation == "rot90"); newRead.signal() })
        release.signal(); wait(newRead)
        precondition(lock.withLock { !publishedOld }, "Old passive read overwrote the fresh synchronous screen")
        // Window teardown / reconnection revoke the exact production lanes for both kinds of read.
        let angle = simulatorAngleObserver(id), oldDisplay = lane.ticket, oldAngle = angle.ticket
        invalidateSimulatorObservation(id)
        precondition(!lane.isCurrent(oldDisplay) && !angle.isCurrent(oldAngle))
        let other = simulatorObserver(UUID().uuidString), otherTicket = other.ticket
        invalidateSimulatorObservation(id)
        precondition(other.isCurrent(otherTicket))
        // Inert, unresumed local XPC objects: no service lookup or message is sent.
        let oldLink = HIDLink(connection: xpc_connection_create(nil, nil), size: .zero, deviceID: id)
        let newLink = HIDLink(connection: xpc_connection_create(nil, nil), size: .zero, deviceID: id)
        handleQueue.sync { hidLinks[id] = newLink }
        let current = lane.ticket
        simulatorHIDConnectionFailed(oldLink, deviceID: id)
        handleQueue.sync {}
        precondition(oldLink.closed && !newLink.closed && lane.isCurrent(current), "Old connection failure cancelled the replacement")
        simulatorHIDConnectionFailed(newLink, deviceID: id)
        handleQueue.sync {}
        precondition(newLink.closed && !lane.isCurrent(current), "Current failed connection retained stale observations")
        print("PASS production connection ownership: replaced error ignored, current failure invalidates")
        print("PASS production observation bridge: synchronous read supersedes slow passive sample; teardown/reconnect revoke display and angle; other device remains current")
        exit(0)
    }
    dispatchMain()
}
