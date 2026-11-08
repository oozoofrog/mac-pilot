import Foundation

// No GUI, device or wall-clock latency assertions. Gates make old readbacks arrive last.
@main struct ObservationCheck {
    static func main() {
        func wait(_ gate: DispatchSemaphore) { precondition(gate.wait(timeout: .now() + 5) == .success, "deadlock deadline") }
        let input = DispatchQueue(label: "test.ordered.input")
        let delivery = DispatchQueue(label: "test.presentation")
        let lane = SimulatorObservationLane<Int>(delivery: delivery)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let lock = NSLock(); var values: [Int] = []; var order: [Int] = []
        lane.observe(read: { _ in started.signal(); wait(release); return 1 }, receive: { n in lock.withLock { values.append(n) } })
        wait(started)
        // A blocked observer cannot stop ordered transmission, release, or presentation.
        let sent = DispatchSemaphore(value: 0)
        input.async {
            var state = SimulatorRotationState()
            state.deliver(.landscapeRight, after: nil, presentsDevice: true) { lock.withLock { order.append(1) } }
            delivery.async { precondition(state.presentation == .landscapeRight); sent.signal() }
        }
        wait(sent)
        input.sync { lock.withLock { order.append(2) } }
        let old = lane.ticket
        lane.invalidate() // next request / failure / teardown / reconnect all revoke ownership
        precondition(!lane.isCurrent(old))
        for n in 2...20 { lane.observe(read: { _ in n }, receive: { n in lock.withLock { values.append(n) }; received.signal() }) }
        // A second device remains independent while the first device's old reader is blocked.
        let other = SimulatorObservationLane<Int>(delivery: delivery)
        let isolated = DispatchSemaphore(value: 0)
        other.observe(read: { _ in 42 }, receive: { n in precondition(n == 42); isolated.signal() })
        wait(isolated)
        release.signal(); wait(received); delivery.sync {}
        precondition(lock.withLock { values == [20] && order == [1,2] }, "late generation or unbounded refresh queue")
        // Cancellation is delivered to the reader and a late result cannot survive close/reopen.
        let entered = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        lane.observe(read: { task in entered.signal(); wait(finish); precondition(task.isCancelled); cancelled.signal(); return 99 }, receive: { _ in preconditionFailure("cancelled read published") })
        wait(entered); lane.invalidate(); finish.signal(); wait(cancelled); delivery.sync {}
        precondition(simulatorHingeAlreadySatisfied(target: 0, angle: 0.1, primary: true))
        precondition(simulatorHingeAlreadySatisfied(target: 180, angle: 179.8, primary: false))
        precondition(!simulatorHingeAlreadySatisfied(target: 0, angle: nil, primary: true))
        precondition(!simulatorHingeAlreadySatisfied(target: 0, angle: 0, primary: false))
        precondition(!simulatorHingeAlreadySatisfied(target: 180, angle: .nan, primary: false))
        print("PASS observation: blocked read permits ordered send/presentation, coalescing, stale/cancel suppression, device isolation, fresh no-op")
    }
}
