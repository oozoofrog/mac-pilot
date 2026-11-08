import Foundation

/// One bounded read at a time per device, independently of the ordered input lane.
/// Replacing a generation cancels its process and discards its result, even if a reader
/// cannot be interrupted immediately. Repeated refreshes coalesce into one latest job.
final class SimulatorObservationLane<Value> {
    struct Ticket: Equatable { let generation: UInt64 }
    private struct Job {
        let ticket: Ticket
        let deadline: TimeInterval
        let read: (SimulatorPreparationTask) -> Value?
        let receive: (Value) -> Void
    }
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var running = false
    private var pending: Job?
    private var task: SimulatorPreparationTask?
    private var wake: DispatchWorkItem?
    private let delivery: DispatchQueue
    init(delivery: DispatchQueue = .main) { self.delivery = delivery }
    var ticket: Ticket { lock.withLock { Ticket(generation: generation) } }
    func isCurrent(_ ticket: Ticket) -> Bool { lock.withLock { ticket.generation == generation } }
    @discardableResult func invalidate() -> Ticket {
        lock.withLock {
            generation &+= 1
            pending = nil; wake?.cancel(); wake = nil
            task?.cancel()
            return Ticket(generation: generation)
        }
    }
    func observe(for seconds: TimeInterval = 0, read: @escaping (SimulatorPreparationTask) -> Value?, receive: @escaping (Value) -> Void) {
        lock.withLock {
            pending = Job(ticket: ticket, deadline: ProcessInfo.processInfo.systemUptime + seconds, read: read, receive: receive)
            wake?.cancel(); wake = nil
            launch()
        }
    }
    private func launch() {
        guard !running, let job = pending else { return }
        pending = nil; running = true
        let reader = SimulatorPreparationTask(); task = reader
        DispatchQueue.global(qos: .utility).async { [self] in
            let value = reader.isCancelled ? nil : job.read(reader)
            lock.withLock {
                running = false; task = nil
                if isCurrent(job.ticket), !reader.isCancelled {
                    if let value {
                        delivery.async { [self] in
                            // Invalidation and delivery are atomic; a close/reopen cannot adopt old readback.
                            lock.withLock { if isCurrent(job.ticket) { job.receive(value) } }
                        }
                    }
                    if pending == nil, ProcessInfo.processInfo.systemUptime < job.deadline {
                        let next = DispatchWorkItem { [self] in
                            lock.withLock {
                                guard isCurrent(job.ticket) else { return }
                                wake = nil
                                if pending == nil { pending = job }
                                launch()
                            }
                        }
                        wake = next
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: next)
                    }
                }
                launch()
            }
        }
    }
}

/// A no-op requires a fresh angle AND a consistent active display. Unknown is never achieved.
func simulatorHingeAlreadySatisfied(target: Double, angle: Double?, primary: Bool?) -> Bool {
    guard let angle, angle.isFinite, let primary, abs(target - angle) < 0.6 else { return false }
    return target <= 30 ? primary : target >= 150 ? !primary : true
}
