import Darwin
import Foundation

/// A control-socket client for tests: one connection, one request line out,
/// one response line back. Blocking socket I/O runs on its own queue behind an
/// async API, so a main-actor test can't deadlock against a main-actor handler.
final class ControlClient: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "com.hrusoft.tabs.control-client")
    private var buffer = Data()

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "connect \(path): \(message)")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Sends one line (a newline is appended) and returns the next response line.
    func send(_ line: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.roundTrip(line) })
            }
        }
    }

    /// Sends raw bytes without waiting for anything (partial lines, garbage).
    func sendRaw(_ bytes: [UInt8]) {
        queue.sync { _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    }

    /// Closes the sending side (as `nc` or a shell pipe does after its input).
    func finishSending() {
        queue.sync { _ = shutdown(fd, SHUT_WR) }
    }

    /// Reads the next response line without sending anything first.
    func readLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.nextLine() }) }
        }
    }

    private func roundTrip(_ line: String) throws -> String {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            guard written > 0 else { throw Failure(description: "write: \(String(cString: strerror(errno)))") }
            offset += written
        }
        return try nextLine()
    }

    private func nextLine() throws -> String {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                throw Failure(description: count == 0 ? "the server closed the connection" : "read: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// A socket path short enough for sockaddr_un (104 bytes on macOS).
func shortSocketPath(_ tag: String = "test") -> String {
    "/tmp/tabs-\(tag)-\(UUID().uuidString.prefix(8)).sock"
}
