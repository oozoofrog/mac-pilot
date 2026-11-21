import CryptoKit
import Darwin
import Foundation

enum XCTestSocketError: String, LocalizedError {
    case closed = "The XCTest socket closed."
    case timeout = "The XCTest socket deadline expired."
    case cancelled = "The XCTest request was cancelled."
    case frame = "Invalid XCTest socket frame."
    var errorDescription: String? { rawValue }
}

struct XCTestSocket {
    let fd: Int32
    let key: SymmetricKey

    enum Direction: UInt8 {
        case request = 1, reply = 2
        var limit: Int { self == .request ? 16_384 : 1_048_576 }
    }

    static func frame(_ data: Data, as direction: Direction, key: SymmetricKey) throws -> Data {
        guard data.count <= direction.limit - 28,
              let body = try AES.GCM.seal(data, using: key, authenticating: [direction.rawValue]).combined else { throw XCTestSocketError.frame }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    static func open(_ frame: Data, as direction: Direction, key: SymmetricKey) throws -> Data? {
        guard frame.count >= 4 else { return nil }
        let size = Int(frame.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard (28...direction.limit).contains(size), frame.count <= size + 4 else { throw XCTestSocketError.frame }
        guard frame.count == size + 4 else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: frame.dropFirst(4)), using: key, authenticating: [direction.rawValue])
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    static func wait(_ fd: Int32, events: Int16, until deadline: Double, cancelled: () -> Bool = { false }) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while now < deadline {
            if cancelled() { throw XCTestSocketError.cancelled }
            let milliseconds = Int32(min(250, ceil(max(0, deadline - now) * 1000)))
            let rc = poll(&descriptor, 1, milliseconds)
            if rc > 0 {
                guard descriptor.revents & events != 0 else { throw XCTestSocketError.closed }
                return
            }
            if rc < 0 && errno != EINTR { throw XCTestSocketError.closed }
        }
        throw XCTestSocketError.timeout
    }

    private func read(_ count: Int, until deadline: Double, cancelled: () -> Bool) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try Self.wait(fd, events: Int16(POLLIN), until: deadline, cancelled: cancelled)
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw XCTestSocketError.closed }
                offset += n
            }
        }
        return data
    }

    func receive(_ direction: Direction, until deadline: Double, cancelled: () -> Bool = { false }) throws -> Data {
        let header = try read(4, until: deadline, cancelled: cancelled)
        let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard (28...direction.limit).contains(size) else { throw XCTestSocketError.frame }
        let bytes = try read(size, until: deadline, cancelled: cancelled)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: [direction.rawValue])
    }

    func send(_ data: Data, as direction: Direction, until deadline: Double, cancelled: () -> Bool = { false }) throws {
        let frame = try Self.frame(data, as: direction, key: key)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Self.wait(fd, events: Int16(POLLOUT), until: deadline, cancelled: cancelled)
                let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_DONTWAIT)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw XCTestSocketError.closed }
                offset += n
            }
        }
    }
}
