import Darwin
import Foundation

// `tabs-ctl <command> [--flag value …]`: the "control Tabs" skill's relay, run by an agent's
// shell in a Tabs terminal pane (which has TABS_PANE_ID and TABS_CONTROL_SOCKET). It sends
// one request to the app's control socket and prints the one line that comes back; every
// outcome, its own failures included, is one line of JSON on stdout. Relay.swift has the rules.

/// Writes all of `data` to `fd`, waiting out a full pipe: an answer can be far bigger than a
/// pipe's buffer, and a caller reading through one (`| jq`) must get every byte of it.
func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let written = write(fd, pointer, remaining)
            if written > 0 {
                pointer += written
                remaining -= written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&waiting, 1, -1)
            } else {
                return false
            }
        }
        return true
    }
}

func finish(_ line: Data, code: Int32) -> Never {
    _ = writeAll(line + Data("\n".utf8), to: STDOUT_FILENO)
    exit(code)
}

func fail(_ message: String) -> Never { finish(Relay.failure(message), code: 1) }

func systemError() -> String { String(cString: strerror(errno)) }

/// One round trip on the app's socket: the request line out, then everything up to the first
/// newline back (or whatever arrived before the app closed the connection).
func exchange(_ request: Data, on socketPath: String) -> Result<Data, ExchangeError> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(ExchangeError(systemError())) }
    defer { close(fd) }
    // A write to a socket the app has closed fails here instead of killing the process.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    let path = socketPath.utf8CString
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        return .failure(ExchangeError("socket path too long: \(socketPath)"))
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        path.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return .failure(ExchangeError("\(systemError()) (\(socketPath))")) }
    guard writeAll(request + Data("\n".utf8), to: fd) else { return .failure(ExchangeError(systemError())) }

    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            received.append(contentsOf: chunk[..<count])
            if chunk[..<count].contains(UInt8(ascii: "\n")) { break }
        } else if count == 0 {
            break
        } else if errno != EINTR {
            return .failure(ExchangeError(systemError()))
        }
    }
    return .success(received)
}

struct ExchangeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

let environment = ProcessInfo.processInfo.environment
guard let paneId = environment["TABS_PANE_ID"], !paneId.isEmpty,
    let socketPath = environment["TABS_CONTROL_SOCKET"], !socketPath.isEmpty
else { fail("not running inside a Tabs terminal pane (TABS_PANE_ID/TABS_CONTROL_SOCKET unset)") }

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !command.isEmpty else {
    fail("usage: tabs-ctl <command> [--flag value ...] — run \"tabs-ctl capabilities\" to list commands")
}

let request: Data
do {
    request = try Relay.envelope(
        command: command, flags: Relay.flags(Array(arguments.dropFirst())), paneId: paneId,
        cwd: FileManager.default.currentDirectoryPath)
} catch {
    fail("could not encode the request: \(error.localizedDescription)")
}

switch exchange(request, on: socketPath) {
case .failure(let error):
    fail("could not reach Tabs: \(error.message)")
case .success(let answer):
    let line = String(decoding: Relay.firstLine(answer), as: UTF8.self)
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let response = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
        fail("malformed response from Tabs: \(line)")
    }
    finish(Data(text.utf8), code: Relay.exitCode(for: response))
}
