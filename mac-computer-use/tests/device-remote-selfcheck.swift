// Headless: the in-process CoreDevice path without a device. ABI check outcomes and the devicectl fallback, the
// session's tunnel assertion, on-demand screenshots, cached implementations and teardown (fake port), the session
// registry, the tool's connection policy for network devices, and per-feature input routing with the delivery barrier.
// Touches no device: the only real CoreDevice use is the ABI check itself and reading this executable's imports.
// From the repository root after `eyebuild dir device-remote`:
// D=/Volumes/eyedisk/build/mac-pilot/device-remote; S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
// export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache"
// { sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$S/Simulator.swift" | sed '$d'; } > "$D/remote-stubs.swift"
// FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; in zsh use ${=FLAGS}
// swiftc -parse-as-library $FLAGS "$D/remote-stubs.swift" "$S/SimulatorGestureHID.swift" "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" "$S/Device.swift" mac-computer-use/tests/device-remote-selfcheck.swift -o "$D/device-remote-selfcheck" && "$D/device-remote-selfcheck"
import AppKit
import XPC

struct ShellResult { let status: Int32; let output: String }
func shell(_ path: String, _ args: [String], timeout: Double = 15) -> ShellResult { fatalError("offline") }
func jpegBase64(_ image: CGImage, size: CGSize) throws -> String { fatalError("offline") }
struct SessionStub { let requestCancelled = false }
let currentSession: SessionStub? = nil

func check(_ value: Bool, _ message: String, line: UInt = #line) {
    if !value { print("FAIL \(message) (line \(line))"); exit(1) }
    print("PASS \(message)")
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Int] = [:]
    func add(_ key: String, _ by: Int = 1) { lock.lock(); values[key, default: 0] += by; lock.unlock() }
    subscript(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
    func max(_ key: String, _ value: Int) { lock.lock(); values[key] = Swift.max(values[key, default: 0], value); lock.unlock() }
}

// MARK: Fakes for the session

final class FakeAssertion: PhysicalAssertion {
    let counter: Counter
    var invalidate: ((String) -> Void)?
    init(_ counter: Counter) { self.counter = counter }
    func release() { counter.add("released") }
    func onInvalidated(_ body: @escaping (String) -> Void) { invalidate = body }
}

final class FakeRemote: PhysicalRemote {
    let counter: Counter
    /// Features appear only after an assertion (a network device whose tunnel is down) unless already up.
    var tunnelUp: Bool
    var lastAssertion: FakeAssertion?
    var captureError: Error?
    init(_ counter: Counter, tunnelUp: Bool) { self.counter = counter; self.tunnelUp = tunnelUp }
    func supports(_ feature: String) -> Bool { tunnelUp }
    func acquireAssertion(reason: String) async throws -> PhysicalAssertion {
        counter.add("acquired")
        try await Task.sleep(nanoseconds: 50_000_000)
        tunnelUp = true
        let made = FakeAssertion(counter); lastAssertion = made
        return made
    }
    func screenshotCapturer() async throws -> () async throws -> CGImage {
        counter.add("fetch.capture")
        return { [self] in
            counter.add("capture")
            if let captureError { throw captureError }
            return makeImage(gray: 0.5)
        }
    }
    func lockReader() async throws -> () async throws -> Bool { counter.add("fetch.lock"); return { false } }
    func displayReader() async throws -> () async throws -> PhysicalDisplayState {
        counter.add("fetch.display")
        let state = PhysicalDisplayState(portraitPoints: CGSize(width: 393, height: 852), portraitPixels: CGSize(width: 1179, height: 2556), nativePixels: CGSize(width: 1179, height: 2556))
        return { state }
    }
}

final class FakePort: PhysicalDevicePort {
    var remotes: [UUID: FakeRemote] = [:]
    func remote(_ id: UUID) -> PhysicalRemote? { remotes[id] }
}

func makeImage(gray: CGFloat, width: Int = 30, height: Int = 60) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct CoreDeviceErrorStandIn: Error, CustomStringConvertible { var description: String { "CoreDeviceError(errorCode: 25003, A screenshot capture is already in progress)" } }

func run(_ body: @escaping () async throws -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { do { try await body() } catch { print("FAIL unexpected error \(error)"); exit(1) }; done.signal() }
    if done.wait(timeout: .now() + 60) != .success { print("FAIL async check timed out"); exit(1) }
}

@main struct DeviceRemoteSelfcheck {
    static func main() throws {
        abi()
        session()
        policy()
        inputRoutes()
        print("device-remote-selfcheck: all passed")
    }

    // MARK: ABI check and fallback

    static func abi() {
        let open = UnsafeMutablePointer<UInt32>.allocate(capacity: 1); open.pointee = 1 << 16       // not class-bound
        let classBound = UnsafeMutablePointer<UInt32>.allocate(capacity: 1); classBound.pointee = 0  // class-bound
        let framework = UnsafeMutableRawPointer(bitPattern: 0x1000)!
        func link(missing: String? = nil, boundProtocol: String? = nil, bound: Bool = true, mismatch: String? = nil, logs: Counter) -> PhysicalDeviceLink {
            let made = PhysicalDeviceLink(openFramework: { _ in framework }, findSymbol: { _, name in
                if name == missing { return nil }
                if name == "$s7Mercury17XPCPeerConnectionMp" || name == boundProtocol { return UnsafeMutableRawPointer(classBound) }
                return UnsafeMutableRawPointer(open)
            }, imagesBound: { bound }, protocolTypeMismatch: { mismatch })
            made.log = { _ in logs.add("log") }
            return made
        }
        let logs = Counter()
        let symbol = PhysicalDeviceLink.inProcessSymbols[PhysicalDeviceLink.inProcessSymbols.count / 2]
        let missing = link(missing: symbol, logs: logs)
        guard case .unavailable(let reason) = missing.inProcessCheck() else { return check(false, "missing symbol disables the in-process path") }
        check(reason.contains(symbol), "missing symbol disables the in-process path and names it")
        _ = missing.inProcessCheck()
        check(logs["log"] == 1, "the reason is logged once per process")
        guard case .unavailable(let flagged) = link(boundProtocol: "$s10CoreDevice17LockStateProtocolMp", logs: logs).inProcessCheck() else { return check(false, "class-bound protocol") }
        check(flagged.contains("class-bound"), "a protocol that became class-bound disables it")
        guard case .unavailable(let changed) = link(mismatch: "LockStateCapability.ProtocolType is X", logs: logs).inProcessCheck() else { return check(false, "type mismatch") }
        check(changed.contains("ProtocolType"), "a ProtocolType mismatch disables it")
        guard case .unavailable(let unbound) = link(bound: false, logs: logs).inProcessCheck() else { return check(false, "unbound") }
        check(unbound.contains("not bound at launch"), "unbound weak imports (framework missing at launch) disable it")
        check(PhysicalDeviceLink(openFramework: { _ in nil }).inProcessCheck() != .available, "missing framework disables it")
        check(link(logs: logs).inProcessCheck() == .available, "all checks passing enables it")

        // Fallback: an unavailable path never creates a session; the devicectl closure answers.
        let port = FakePort()
        let off = PhysicalDeviceSessions(available: { .unavailable("test") }, makePort: { port })
        let id = UUID()
        var fallbacks = 0
        let value = try? physicalWithFallback(off, id, seconds: 2, "test", { _ in 1 }, fallback: { fallbacks += 1; return 2 })
        check(off.session(id) == nil && value == 2 && fallbacks == 1 && off.unavailableReason == "test", "ABI mismatch: no session, devicectl fallback answers")
        let on = PhysicalDeviceSessions(available: { .available }, makePort: { port })
        port.remotes[id] = FakeRemote(Counter(), tunnelUp: true)
        check((try? physicalWithFallback(on, id, seconds: 2, "test", { _ in 1 }, fallback: { 2 })) == 1, "in-process answer used when available")
        check((try? physicalWithFallback(on, id, seconds: 2, "test", { _ in throw PhysicalSessionError.failed("x") }, fallback: { 3 })) == 3, "in-process failure falls back to devicectl")

        // This executable: the real framework (Xcode installed) passes, and every CoreDevice import is weak and listed.
        let real = PhysicalDeviceLink()
        real.log = { print("LOG \($0)") }
        let outcome = real.inProcessCheck()
        print("real in-process check: \(outcome)")
        check(outcome == .available, "the real CoreDevice of this Mac passes the ABI check")
        let imports = Process()
        imports.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        imports.arguments = ["dyld_info", "-imports", CommandLine.arguments[0]]
        let pipe = Pipe(); imports.standardOutput = pipe
        try? imports.run(); imports.waitUntilExit()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").filter { $0.contains("(from CoreDevice") }
        let listed = Set(PhysicalDeviceLink.inProcessSymbols + PhysicalDeviceLink.symbols)
        let names = lines.compactMap { $0.split(separator: " ").first(where: { $0.hasPrefix("_$s") }).map { String($0.dropFirst()) } }
        check(!names.isEmpty && lines.allSatisfy { $0.contains("weak-import") }, "all \(names.count) CoreDevice/CoreDeviceUtilities imports are weak")
        let unlisted = names.filter { !listed.contains($0) }
        check(unlisted.isEmpty, "every CoreDevice import is in the ABI check list" + (unlisted.isEmpty ? "" : ": missing \(unlisted)"))
    }

    // MARK: Session

    static func session() {
        run {
            let counter = Counter(), port = FakePort(), id = UUID()
            let remote = FakeRemote(counter, tunnelUp: false)
            port.remotes[id] = remote
            let session = PhysicalDeviceSession(id: id, port: port, transport: { "localNetwork" })
            async let a = session.capture(), b = session.capture()
            _ = try await (a, b)
            check(counter["acquired"] == 1 && session.holdsAssertion, "network: one usage assertion raises the tunnel before use (concurrent first calls share it)")
            check(counter["fetch.capture"] == 1, "the screenshot implementation is fetched once")
            for _ in 0..<5 { _ = try await session.capture() }
            _ = try await session.lockState(); _ = try await session.lockState()
            check(counter["fetch.capture"] == 1 && counter["fetch.lock"] == 1 && counter["acquired"] == 1, "implementations and the assertion are reused")
            remote.captureError = CoreDeviceErrorStandIn()
            do { _ = try await session.capture(); check(false, "busy") } catch { check(error as? PhysicalSessionError == .busy, "25003 surfaces as busy") }
            check(session.holdsImplementations, "busy keeps the implementations")
            remote.captureError = PhysicalSessionError.failed("connection invalidated")
            do { _ = try await session.capture() } catch {}
            check(!session.holdsImplementations, "a failure drops the implementations")
            remote.captureError = nil
            _ = try await session.capture()
            check(counter["fetch.capture"] == 2, "they are fetched again on the next call")
            let display = try await session.displayInfo()
            check(display.portraitPoints == CGSize(width: 393, height: 852), "display info read")
            // CoreDevice ends the assertion: dropped without a second release, acquired again on the next use.
            remote.lastAssertion?.invalidate?("tunnel closed")
            check(!session.holdsAssertion && counter["released"] == 0, "invalidated assertion dropped, not released")
            check(session.invalidations == 1 && !session.holdsImplementations, "invalidation drops the implementations")
            remote.tunnelUp = false
            _ = try await session.capture()
            check(counter["acquired"] == 2 && session.holdsAssertion, "re-acquired after invalidation")
            session.close(); session.close()
            check(counter["released"] == 1 && !session.holdsAssertion && !session.holdsImplementations, "close releases the assertion exactly once")
            do { _ = try await session.capture(); check(false, "closed") } catch { check(error as? PhysicalSessionError == .closed, "no calls after close") }

            let wiredCounter = Counter(), wiredID = UUID()
            port.remotes[wiredID] = FakeRemote(wiredCounter, tunnelUp: true)
            let wired = PhysicalDeviceSession(id: wiredID, port: port, transport: { "wired" })
            _ = try await wired.capture()
            check(wiredCounter["acquired"] == 0, "wired with its features up: no assertion")
            let absent = PhysicalDeviceSession(id: UUID(), port: port, transport: { "wired" })
            absent.appearWait = 0.2
            do { _ = try await absent.capture(); check(false, "absent") } catch { check(error as? PhysicalSessionError == .notFound, "unknown device: notFound") }
            let downCounter = Counter(), downID = UUID()
            let down = FakeRemote(downCounter, tunnelUp: false)
            port.remotes[downID] = down
            let refused = PhysicalDeviceSession(id: downID, port: port, transport: { "wired" })
            refused.featureWait = 0.3
            down.tunnelUp = false
            // An assertion that does not bring the features: refused with what to do.
            final class NoTunnel: PhysicalRemote {
                let counter: Counter; init(_ c: Counter) { counter = c }
                func supports(_ feature: String) -> Bool { false }
                func acquireAssertion(reason: String) async throws -> PhysicalAssertion { FakeAssertion(counter) }
                func screenshotCapturer() async throws -> () async throws -> CGImage { fatalError() }
                func lockReader() async throws -> () async throws -> Bool { fatalError() }
                func displayReader() async throws -> () async throws -> PhysicalDisplayState { fatalError() }
            }
            final class OnePort: PhysicalDevicePort { let r: PhysicalRemote; init(_ r: PhysicalRemote) { self.r = r }; func remote(_ id: UUID) -> PhysicalRemote? { r } }
            let stuck = PhysicalDeviceSession(id: downID, port: OnePort(NoTunnel(downCounter)), transport: { "localNetwork" })
            stuck.featureWait = 0.3
            do { _ = try await stuck.capture(); check(false, "stuck") } catch {
                guard case PhysicalSessionError.notConnected(let detail)? = error as? PhysicalSessionError else { return check(false, "notConnected \(error)") }
                check(detail.contains("unlock"), "features never appear: notConnected with what to do")
            }
            stuck.close()
            check(downCounter["released"] == 1, "its assertion is released at close")
        }

        // Registry: reuse, end and idle sweep.
        var now = 0.0
        let port = FakePort(), counter = Counter(), id = UUID()
        port.remotes[id] = FakeRemote(counter, tunnelUp: false)
        let registry = PhysicalDeviceSessions(available: { .available }, makePort: { port }, clock: { now })
        registry.noteTransport(id, "localNetwork")
        let first = registry.session(id)!
        check(registry.session(id) === first, "one session per device, reused")
        run { _ = try await first.capture() }
        now = registry.idleClose - 1
        registry.sweep()
        check(registry.count == 1 && !first.closed, "a session used within idleClose stays")
        check(registry.session(id) === first, "use refreshes it")
        now = 2 * registry.idleClose
        registry.sweep()
        check(registry.count == 0 && first.closed && counter["released"] == 1, "idle: closed, assertion released once")
        let second = registry.session(id)!
        check(second !== first, "a new session after the idle close")
        registry.end(nil)
        check(second.closed && registry.count == 0, "release ends every session")
    }

    // MARK: Tool policy for network devices

    static func policy() {
        let network = UUID(), unpaired = UUID(), away = UUID(), wiredDown = UUID()
        let devices = [
            PhysicalDeviceInfo(identifier: network, name: "net", model: nil, osVersion: "iOS 27", transport: "localNetwork", connectionState: "tunnel disconnected", pairingState: "paired", tunnelState: "disconnected"),
            PhysicalDeviceInfo(identifier: unpaired, name: "new", model: nil, osVersion: "iOS 27", transport: "wired", connectionState: "tunnel disconnected", pairingState: "unpaired", tunnelState: "disconnected"),
            PhysicalDeviceInfo(identifier: away, name: "away", model: nil, osVersion: "iOS 27", transport: nil, connectionState: nil, pairingState: "paired", tunnelState: nil),
            PhysicalDeviceInfo(identifier: wiredDown, name: "cable", model: nil, osVersion: "iOS 27", transport: "wired", connectionState: "tunnel disconnected", pairingState: "paired", tunnelState: "disconnected"),
        ]
        var ended: [UUID?] = []
        let tool = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in false }, display: { _ in CGSize(width: 393, height: 852) }, screenshot: { _, _ in "jpeg" },
                                            open: { _, _ in fatalError("no input in this check") }, endSessions: { ended.append($0) }))
        func text(_ result: [String: Any]) -> String { ((result["content"] as! [[String: Any]])[0]["text"] as! String) }
        let listing = (try? text(tool.call(["action": "list"]))) ?? ""
        check(listing.contains("| network |") && listing.contains("| USB |") && listing.contains("unknown transport"), "list shows the transport")
        let allowed = (try? text(tool.call(["action": "allow", "device": network.uuidString]))) ?? ""
        check(allowed.contains("network"), "a paired network device whose tunnel is down is allowed (tunnel raised on use)")
        let shot = try? tool.call(["action": "screenshot", "device": network.uuidString])
        check(shot != nil, "screenshot works on the network device")
        for (id, expect) in [(unpaired, "not paired"), (away, "same network"), (wiredDown, "USB cable")] {
            do { _ = try tool.call(["action": "allow", "device": id.uuidString]); check(false, "refused \(id)") }
            catch { check("\(error)".contains(expect), "refused with what to do: \(expect)") }
        }
        _ = try? tool.call(["action": "release"])
        check(ended.count == 1 && ended[0] == nil, "release ends the device sessions")
        _ = try? tool.call(["action": "allow", "device": network.uuidString])
        let other = UUID()
        let two = DeviceTool(DeviceBackend(list: { devices + [PhysicalDeviceInfo(identifier: other, name: "b", model: nil, osVersion: nil, transport: "wired", connectionState: "Connected", pairingState: "paired")] },
                                           locked: { _ in false }, display: { _ in .zero }, screenshot: { _, _ in "" }, open: { _, _ in fatalError() }, endSessions: { ended.append($0) }))
        _ = try? two.call(["action": "allow", "device": network.uuidString])
        _ = try? two.call(["action": "allow", "device": other.uuidString])
        check(ended.last == network, "allowing another device ends the previous device's session")
    }

    // MARK: Per-feature input connections and the delivery barrier

    static func inputRoutes() {
        var sent: [String: Int] = [:], barriers: [String] = []
        func route(_ name: String, _ answer: PhysicalHIDLink.Barrier) -> PhysicalInputRoute {
            PhysicalInputRoute(send: { _ in sent[name, default: 0] += 1; return true }, barrier: { wait in barriers.append("\(name) \(wait)"); return answer })
        }
        let link = physicalInputLink([PhysicalFeature.hid: route(PhysicalFeature.hid, .acknowledged), PhysicalFeature.button: route(PhysicalFeature.button, .timedOut)],
                                     connection: xpc_dictionary_create(nil, nil, 0), size: CGSize(width: 393, height: 852), deviceID: "phone", barrierWait: 0.5)
        link.touch(CGPoint(x: 10, y: 10), phase: 0, screen: nil)
        check(link.button(page: 0x0c, usage: 0x40, down: true, feature: PhysicalFeature.button), "a button goes to the button connection")
        check(!link.send("IndigoScrollEvent", xpc_dictionary_create(nil, nil, 0), feature: "com.apple.coredevice.feature.remote.hid.scroll"),
              "a feature without a connection is not sent")
        check(sent == [PhysicalFeature.hid: 1, PhysicalFeature.button: 1], "each message reached only its feature's connection")
        let drained = link.drain([PhysicalFeature.hid, PhysicalFeature.button, "com.apple.coredevice.feature.remote.hid.scroll"])
        check(drained?.acknowledged == [PhysicalFeature.hid], "only an answered barrier counts as drained")
        check(drained?.unconfirmed[PhysicalFeature.button]?.contains("0.5") == true && drained?.unconfirmed["com.apple.coredevice.feature.remote.hid.scroll"] == "no connection",
              "unanswered and unconnected features are reported unconfirmed")
        check(barriers.sorted() == ["\(PhysicalFeature.button) 0.5", "\(PhysicalFeature.hid) 0.5"], "the barrier went once to each connected feature with its wait")
        let simulator = HIDLink(connection: xpc_dictionary_create(nil, nil, 0), size: .zero, deviceID: "sim", send: { _ in true })
        check(simulator.drain([PhysicalFeature.hid]) == nil, "the simulator link has no device barrier")
        let message = PhysicalHIDLink.barrierMessage()
        check(xpc_dictionary_get_count(message) == 1 && xpc_dictionary_get_bool(message, "isBarrier"), "the barrier message holds only isBarrier: true")
    }
}
