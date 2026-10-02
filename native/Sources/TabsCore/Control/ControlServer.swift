import Darwin
import Foundation
import os

/// The control socket: newline-delimited JSON over a Unix-domain socket. Each
/// line a client writes is one request (`ControlDispatcher`'s envelope); each
/// line it reads back is that request's response. A connection may carry any
/// number of requests; they're answered in order.
///
/// It is per-boot (`control-<pid>.sock` by default, like the Electron app's —
/// pane ids persist across boots and instances, so a fixed name could reach
/// the wrong process), owner-only on disk, and refuses peers running as
/// another user. Transport only: what a request does is the handler's business.
///
/// No client can hold up another, or the app: all socket I/O is non-blocking
/// on one serial queue that never waits for a client. A client that stops
/// reading its answers gets no more requests read (backpressure, so memory
/// stays bounded) and is disconnected once it has made no progress for
/// `Limits.stallTimeout`. At `Limits.maxConnections`, a new client takes the
/// place of the longest-idle connection, or waits in the backlog if every
/// connection is busy. Every descriptor is close-on-exec, so processes the app
/// spawns (shells) never inherit the socket.
package final class ControlServer: @unchecked Sendable {
    /// One request line in, one response line out (no newline in either).
    package typealias Handler = @Sendable (String) async -> String

    package struct Limits: Sendable {
        /// A line longer than this closes the connection (a runaway client).
        package var maxLineBytes = 16 << 20
        /// Requests read but not yet answered, per connection; reading pauses
        /// at this many.
        package var maxPendingRequests = 64
        /// Answer bytes the client hasn't read yet, per connection; reading
        /// pauses above this.
        package var maxUnsentBytes = 4 << 20
        /// A client with unread answers that reads none of them for this long
        /// is disconnected.
        package var stallTimeout: Duration = .seconds(30)
        /// Connections served at once. Past it, a new client replaces the
        /// longest-idle one, or waits in the backlog until one is idle.
        package var maxConnections = 64
        /// How long a new connection that hasn't finished a request is safe
        /// from being replaced: it may simply not have sent it yet.
        package var newConnectionGrace: Duration = .seconds(2)

        package init() {}
    }

    package enum StartError: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String, limit: Int)
        /// Another process is listening there; its socket is never replaced.
        case inUse(String)
        case system(String, errno: Int32)

        package var description: String {
            switch self {
            case .pathTooLong(let path, let limit): "socket path is \(path.utf8.count) bytes, the limit is \(limit - 1): \(path)"
            case .inUse(let path): "another process is listening at \(path)"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    package let path: String
    package let limits: Limits

    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.tabs.prototype.control-server")
    // Everything below is touched only on `queue`.
    private var acceptSource: (any DispatchSourceRead)?
    private var acceptPaused = false
    private var backingOff = false
    private var recheckScheduled = false
    private var connections: [Int32: Connection] = [:]

    package init(path: String, limits: Limits = Limits(), handler: @escaping Handler) {
        self.path = path
        self.limits = limits
        self.handler = handler
    }

    /// The default location: `<directory>/control-<pid>.sock`.
    package static func defaultPath(in directory: URL) -> String {
        directory.appending(path: "control-\(getpid()).sock").path
    }

    /// Removes `control-<pid>.sock` files in `directory` whose process is gone
    /// — what a crash leaves behind. Returns the paths removed.
    @discardableResult
    package static func removeStaleSockets(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed: [String] = []
        for name in names where name.hasPrefix("control-") && name.hasSuffix(".sock") {
            guard let pid = Int32(name.dropFirst("control-".count).dropLast(".sock".count)), pid != getpid() else { continue }
            if kill(pid, 0) == -1, errno == ESRCH {
                let path = directory.appending(path: name).path
                if unlink(path) == 0 { removed.append(path) }
            }
        }
        return removed
    }

    /// Connections being served (tests).
    package var connectionCount: Int { queue.sync { connections.count } }

    // MARK: Lifecycle

    package func start() throws(StartError) {
        Self.catchBrokenPipes()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < limit else { throw .pathTooLong(path, limit: limit) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A socket file nobody answers on is stale (a crashed boot with a
        // recycled pid) and goes; one somebody answers on is another app's.
        if Self.answers(at: address) { throw .inUse(path) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno: errno) }
        Self.prepare(fd)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind", errno: code)
        }
        // Owner-only; peers are also checked by uid on accept.
        chmod(path, 0o600)
        // A burst of clients (a script, parallel agents) queues rather than
        // being refused.
        guard listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("listen", errno: code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        // The descriptor outlives every event the source may still deliver.
        source.setCancelHandler { close(fd) }
        queue.sync { acceptSource = source }
        source.resume()
        Log.core.info("control socket listening at \(self.path, privacy: .public)")
    }

    /// Closes every connection and removes the socket file. Idempotent, and
    /// prompt: nothing on `queue` ever waits for a client. The owner must call
    /// it (never from `queue`). Requests of those connections still waiting
    /// never run; one already running is cancelled.
    package func stop() {
        queue.sync {
            if let source = acceptSource {
                source.cancel()
                if acceptPaused { source.resume() }  // a suspended source never runs its cancel handler
                acceptPaused = false
                acceptSource = nil
                unlink(path)
            }
            for connection in Array(connections.values) { connection.close() }
            connections.removeAll()
        }
    }

    /// A peer that hangs up before reading its answer makes our write raise
    /// SIGPIPE, whose default action kills the process. SO_NOSIGPIPE per socket
    /// isn't enough: setsockopt fails (EINVAL) on a socket whose peer already
    /// left — a client that connects, sends and disconnects before we accept.
    /// So SIGPIPE is handled process-wide, and a broken pipe is just an EPIPE
    /// from write. Caught by a handler that does nothing rather than ignored:
    /// an ignored signal is inherited through exec, so every shell the app
    /// spawns would ignore SIGPIPE too (`yes | head -1` would print "Broken
    /// pipe"); a caught one is reset to its default.
    private static func catchBrokenPipes() {
        var action = sigaction()
        action.__sigaction_u = __sigaction_u(__sa_handler: { _ in })
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGPIPE, &action, nil)
    }

    /// Whether something accepts connections at `address` now.
    private static func answers(at address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
    }

    /// Non-blocking and close-on-exec. (macOS has no SOCK_CLOEXEC, so there's
    /// a window between socket()/accept() and this in which a concurrent fork
    /// could inherit the descriptor; spawners should also close what they
    /// don't pass, e.g. POSIX_SPAWN_CLOEXEC_DEFAULT.)
    private static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    // MARK: Accepting (on `queue`)

    private func acceptPending(on listener: Int32) {
        while acceptSource != nil, !backingOff {
            if connections.count >= limits.maxConnections {
                // Full. If a client is waiting, make room by dropping the
                // longest-idle connection; otherwise it waits in the backlog
                // until one is idle.
                var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&waiting, 1, 0) > 0,
                    let idlest = connections.values.filter(\.isReplaceable).min(by: { $0.lastActivity < $1.lastActivity })
                else { break }
                Log.core.info("control socket at its connection limit: dropped the longest-idle client for a new one")
                idlest.close()
            }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE: backOff()
                default: break  // EAGAIN: nothing more pending
                }
                break
            }
            Self.prepare(fd)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Log.core.error("control socket refused a peer running as another user")
                close(fd)
                continue
            }
            // Belt and braces with the process-wide SIG_IGN in start(): this
            // fails (harmlessly) if the peer has already left.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(
                fd: fd, queue: queue, limits: limits,
                onClose: { [weak self] fd in
                    self?.connections[fd] = nil
                    self?.updateAccepting()
                },
                onIdle: { [weak self] in self?.updateAccepting() })
            connections[fd] = connection
            connection.start(handler: handler)
        }
        updateAccepting()
    }

    /// Out of descriptors: the listener stays readable, so without a pause its
    /// source would spin. Retry shortly.
    private func backOff() {
        Log.core.error("control socket can't accept: \(String(cString: strerror(errno)), privacy: .public); retrying shortly")
        backingOff = true
        updateAccepting()
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.backingOff = false
            self?.updateAccepting()
        }
    }

    /// Listens only while there's room — below the cap, or a connection to
    /// replace: otherwise clients wait in the backlog. A connection still in
    /// its grace period becomes replaceable without any event, so a full
    /// server looks again once that has passed.
    private func updateAccepting() {
        guard let source = acceptSource else { return }
        let full = connections.count >= limits.maxConnections
        let shouldAccept = !backingOff && (!full || connections.values.contains(where: \.isReplaceable))
        if full, !shouldAccept, !recheckScheduled {
            recheckScheduled = true
            let (seconds, attoseconds) = limits.newConnectionGrace.components
            let delay = DispatchTimeInterval.nanoseconds(Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000) + 1_000_000)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recheckScheduled = false
                self?.updateAccepting()
            }
        }
        if shouldAccept, acceptPaused {
            acceptPaused = false
            source.resume()
        } else if !shouldAccept, !acceptPaused {
            acceptPaused = true
            source.suspend()
        }
    }

    // MARK: Connections (on `queue`)

    /// One client. Reads lines and writes answers without ever blocking; a
    /// single task answers its requests in order, so a slow request delays
    /// only its own connection.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let queue: DispatchQueue
        private let limits: Limits
        private let onClose: (Int32) -> Void
        private let onIdle: () -> Void
        private let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        /// Answers the requests; cancelled when the connection closes.
        private var worker: Task<Void, Never>?
        /// When the client last sent or received anything.
        private(set) var lastActivity = ContinuousClock.now
        private let connectedAt = ContinuousClock.now
        /// Requests answered so far.
        private var answered = 0

        private var readSource: (any DispatchSourceRead)?
        private var readPaused = false
        private var writeSource: (any DispatchSourceWrite)?
        private var writePaused = true  // created inactive
        private var stallTimer: (any DispatchSourceTimer)?
        /// Sources whose cancel handler hasn't run: the descriptor stays open
        /// until they're done with it.
        private var liveSources = 0

        private var inbound: [UInt8] = []
        /// How far `inbound` has been searched for a newline without finding one.
        private var scanned = 0
        /// Whether `inbound` may still hold complete lines (the pending limit
        /// stopped delivery before it was searched to the end).
        private var mayHoldLines = false
        private var outbound: [UInt8] = []
        /// Bytes at the front of `outbound` already written.
        private var sent = 0
        /// Requests handed to the handler and not yet answered.
        private var pending = 0
        private var readEnded = false
        private var closed = false
        private var descriptorClosed = false

        init(fd: Int32, queue: DispatchQueue, limits: Limits, onClose: @escaping (Int32) -> Void, onIdle: @escaping () -> Void) {
            self.fd = fd
            self.queue = queue
            self.limits = limits
            self.onClose = onClose
            self.onIdle = onIdle
            (lines, continuation) = AsyncStream<String>.makeStream()
        }

        /// Nothing in flight in either direction.
        var isIdle: Bool { !closed && pending == 0 && sent >= outbound.count && inbound.isEmpty }

        /// Safe to drop for a new client: idle, nothing sent that we haven't
        /// read, and either done with a request or silent past its grace — a
        /// client just accepted in a burst has usually sent its request
        /// already, only unread.
        var isReplaceable: Bool {
            guard isIdle, !hasUnreadBytes else { return false }
            return answered > 0 || connectedAt.duration(to: .now) > limits.newConnectionGrace
        }

        private var hasUnreadBytes: Bool {
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
        }

        func start(handler: @escaping Handler) {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            track(source)
            readSource = source
            source.resume()
            let lines = lines
            let queue = queue
            // Holds the connection until its stream finishes, which close()
            // (and EOF) guarantee. Cancelled by close(): requests still queued
            // never run, and the running one is cancelled.
            worker = Task { [self] in
                for await line in lines {
                    if Task.isCancelled { break }
                    let response = await handler(line)
                    queue.async { self.answer(response) }
                }
            }
        }

        private func track(_ source: any DispatchSourceProtocol) {
            liveSources += 1
            source.setCancelHandler { [self] in
                liveSources -= 1
                closeDescriptorIfDone()
            }
        }

        // MARK: Reading

        private func readAvailable() {
            guard !closed, !readEnded else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                inbound.append(contentsOf: chunk[0..<count])
                lastActivity = .now
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF or error. Lines already read are still answered: a
                // client that sends its requests and then closes its write
                // side (nc, a shell pipe) gets every answer.
                endReading()
            } else {
                return
            }
            deliverLines()
        }

        /// Hands complete lines to the handler, as many as the pending limit
        /// allows; the rest wait in `inbound` with reading paused. Each byte is
        /// searched for a newline once, however the line arrives.
        private func deliverLines() {
            guard !closed else { return }
            var start = 0
            mayHoldLines = false
            while true {
                guard pending < limits.maxPendingRequests else {
                    mayHoldLines = true
                    break
                }
                guard let newline = inbound[max(start, scanned)...].firstIndex(of: 0x0A) else {
                    scanned = inbound.count
                    break
                }
                deliver(inbound[start..<newline])
                start = newline + 1
                scanned = start
            }
            inbound.removeFirst(start)
            scanned -= start
            if !mayHoldLines, inbound.count > limits.maxLineBytes {
                Log.core.error("control socket closed a connection whose line exceeded \(self.limits.maxLineBytes) bytes")
                close()
                return
            }
            if readEnded, !mayHoldLines {
                // The client has said all it will. A last line without its
                // newline (`printf '{…}' | nc -U`) is still a request.
                if !inbound.isEmpty, pending < limits.maxPendingRequests {
                    deliver(inbound[...])
                    inbound.removeAll()
                    scanned = 0
                }
                if inbound.isEmpty { continuation.finish() }
            }
            updateReading()
            closeIfFinished()
        }

        private func deliver(_ bytes: ArraySlice<UInt8>) {
            let line = String(decoding: bytes, as: UTF8.self)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            pending += 1
            continuation.yield(line)
        }

        /// Reads only while the client keeps up: few enough unanswered
        /// requests and unread answer bytes.
        private func updateReading() {
            guard let source = readSource, !readEnded, !closed else { return }
            let shouldRead = pending < limits.maxPendingRequests && outbound.count - sent < limits.maxUnsentBytes
            if shouldRead, readPaused {
                readPaused = false
                source.resume()
            } else if !shouldRead, !readPaused {
                readPaused = true
                source.suspend()
            }
        }

        private func endReading() {
            readEnded = true
            guard let source = readSource else { return }
            source.cancel()
            if readPaused { source.resume() }
            readPaused = false
            readSource = nil
        }

        // MARK: Writing

        private func answer(_ response: String) {
            guard !closed else { return }
            pending -= 1
            answered += 1
            outbound.append(contentsOf: response.utf8)
            outbound.append(0x0A)
            flush()
            deliverLines()
            if isIdle { onIdle() }
        }

        /// Writes what the socket takes now; waits for room otherwise.
        private func flush() {
            while !closed, sent < outbound.count {
                let written = outbound.withUnsafeBytes { write(fd, $0.baseAddress! + sent, $0.count - sent) }
                if written > 0 {
                    sent += written
                    lastActivity = .now
                    disarmStallTimer()
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    waitForRoom()
                    return
                } else {
                    close()  // the client went away
                    return
                }
            }
            outbound.removeAll(keepingCapacity: outbound.count <= 1 << 16)
            sent = 0
            if let source = writeSource, !writePaused {
                writePaused = true
                source.suspend()
            }
        }

        private func waitForRoom() {
            if writeSource == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.flush()
                    self.deliverLines()
                    if self.isIdle { self.onIdle() }
                }
                track(source)
                writeSource = source
            }
            if let source = writeSource, writePaused {
                writePaused = false
                source.resume()
            }
            // Compact rather than grow without bound while the client lags.
            if sent > 1 << 16, sent > outbound.count / 2 {
                outbound.removeFirst(sent)
                sent = 0
            }
            armStallTimer()
        }

        private func armStallTimer() {
            guard stallTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let (seconds, attoseconds) = limits.stallTimeout.components
            timer.schedule(deadline: .now() + .nanoseconds(Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Log.core.error("control socket disconnected a client that stopped reading its answers")
                self.close()
            }
            stallTimer = timer
            timer.resume()
        }

        private func disarmStallTimer() {
            stallTimer?.cancel()
            stallTimer = nil
        }

        // MARK: Closing

        /// Done once the client has closed its side and every answer is out.
        private func closeIfFinished() {
            if readEnded, pending == 0, sent >= outbound.count, !mayHoldLines, inbound.isEmpty { close() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            continuation.finish()
            worker?.cancel()
            for source in [readSource, writeSource] as [(any DispatchSourceProtocol)?] {
                source?.cancel()
            }
            if let readSource, readPaused { readSource.resume() }
            if let writeSource, writePaused { writeSource.resume() }
            readSource = nil
            writeSource = nil
            disarmStallTimer()
            closeDescriptorIfDone()
            onClose(fd)
        }

        private func closeDescriptorIfDone() {
            guard closed, liveSources == 0, !descriptorClosed else { return }
            descriptorClosed = true
            Darwin.close(fd)
        }
    }
}
