import Darwin
import Foundation
import Testing

@testable import TabsCore

/// The socket transport alone, with a stub handler: framing, ordering,
/// concurrency, permissions, lifecycle and abuse.
///
/// Nothing here waits out a guess at how long the server takes: a slow request
/// is held by a `Gate` until the test opens it, and the server's state is
/// polled. A server that held a client up would leave a test waiting, so the
/// time limit, not a stopwatch, catches it.
@Suite(.timeLimit(.minutes(1))) struct ControlServerTests {
    private func server(
        _ configure: (inout ControlServer.Limits) -> Void = { _ in }, _ handler: @escaping ControlServer.Handler
    ) throws -> ControlServer {
        var limits = ControlServer.Limits()
        limits.maxLineBytes = 1 << 20
        configure(&limits)
        let server = ControlServer(path: shortSocketPath(), limits: limits, handler: handler)
        try server.start()
        return server
    }

    @Test func manyRequestsOnOneConnectionAreAnsweredInOrder() async throws {
        let server = try server { line in
            // Later requests finish first if the server doesn't keep order.
            if line == "slow" { try? await Task.sleep(for: .milliseconds(20)) }
            return "echo \(line)"
        }
        defer { server.stop() }
        let client = try ControlClient(path: server.path)
        client.sendRaw(Array("slow\nfast\n".utf8))
        #expect(try await client.readLine() == "echo slow")
        #expect(try await client.readLine() == "echo fast")
        #expect(try await client.send("third") == "echo third")
    }

    @Test func aClientThatClosesItsSendingSideStillGetsEveryAnswer() async throws {
        let server = try server { "echo \($0)" }
        defer { server.stop() }
        let client = try ControlClient(path: server.path)
        client.sendRaw(Array("one\ntwo\n".utf8))
        client.finishSending()
        #expect(try await client.readLine() == "echo one")
        #expect(try await client.readLine() == "echo two")
        await #expect(throws: ControlClient.Failure.self, "then the server closes") { try await client.readLine() }
    }

    @Test func clientsAreServedConcurrently() async throws {
        let gate = Gate()
        let server = try server { line in
            await gate.pass(line, holding: line == "slow")
            return line
        }
        defer { server.stop() }
        let slow = try ControlClient(path: server.path)
        let fast = try ControlClient(path: server.path)
        async let slowAnswer = slow.send("slow")
        #expect(await eventually { gate.seen == ["slow"] }, "the slow request is being handled")
        // Still held: a server serving one client at a time would never answer this one.
        #expect(try await fast.send("fast") == "fast", "one slow client doesn't hold up another")
        gate.open()
        #expect(try await slowAnswer == "slow")
    }

    @Test func linesArriveWholeWhateverTheChunking() async throws {
        let server = try server { $0 }
        defer { server.stop() }
        let client = try ControlClient(path: server.path)
        client.sendRaw(Array("{\"a\":".utf8))
        try await Task.sleep(for: .milliseconds(10))
        client.sendRaw(Array("1}\n\n   \n".utf8))
        #expect(try await client.readLine() == "{\"a\":1}", "blank lines are ignored")
        // Split inside é (2 bytes) and inside 🙂 (4): a line is decoded once whole, never chunk by chunk.
        let accented = Array("{\"t\":\"é🙂\"}\n".utf8)
        for chunk in [accented[..<7], accented[7..<9], accented[9...]] {
            client.sendRaw(Array(chunk))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await client.readLine() == "{\"t\":\"é🙂\"}")
        let big = String(repeating: "x", count: 300_000)
        #expect(try await client.send(big) == big)
    }

    @Test func anOversizedLineClosesOnlyThatConnection() async throws {
        let server = try server({ $0.maxLineBytes = 1024 }) { $0 }
        defer { server.stop() }
        let abusive = try ControlClient(path: server.path)
        abusive.sendRaw(Array(repeating: UInt8(ascii: "x"), count: 4096))
        await #expect(throws: ControlClient.Failure.self) { try await abusive.readLine() }
        let polite = try ControlClient(path: server.path)
        #expect(try await polite.send("still here") == "still here")
    }

    @Test func aClientVanishingMidRequestDoesNotHurtTheServer() async throws {
        let gate = Gate()
        let server = try server { line in
            await gate.pass(line, holding: line == "bye")
            return line
        }
        defer { server.stop() }
        do {
            let leaver = try ControlClient(path: server.path)
            leaver.sendRaw(Array("bye\n".utf8))
            #expect(await eventually { gate.seen == ["bye"] }, "its request is being handled")
            withExtendedLifetime(leaver) {}
        }  // …when it goes
        gate.open()
        // The answer meets a broken pipe; only then does the server let the connection go.
        #expect(await eventually { server.connectionCount == 0 })
        #expect(try await ControlClient(path: server.path).send("next") == "next")
    }

    /// A burst of clients that send and hang up at once, some gone before the server has even accepted them
    /// (when SO_NOSIGPIPE can no longer be set): their answers meet broken pipes, an EPIPE and not a SIGPIPE
    /// that would kill this process, and the server lets each connection go and answers the next.
    @Test func clientsHangingUpBeforeTheirAnswerDoNotHurtTheServer() async throws {
        let server = try server { $0 }
        defer { server.stop() }
        for _ in 0..<20 {
            let client = try ControlClient(path: server.path)
            client.sendRaw(Array("bye\n".utf8))
        }  // each client closes as it goes
        #expect(await eventually { server.connectionCount == 0 })
        #expect(try await ControlClient(path: server.path).send("next") == "next")
    }

    @Test func aClientThatNeverReadsHoldsUpNeitherOthersNorQuit() async throws {
        let big = String(repeating: "y", count: 64 * 1024)
        let server = try server({
            $0.maxPendingRequests = 8
            $0.maxUnsentBytes = 128 * 1024
        }) { line in line == "big" ? big : line }
        defer { server.stop() }
        // Far more answer bytes than the socket buffers hold, and it never reads.
        let hog = try ControlClient(path: server.path)
        hog.sendRaw(Array(String(repeating: "big\n", count: 200).utf8))
        try await Task.sleep(for: .milliseconds(100))  // its answers fill the socket's buffers

        // Answered at all: held up by the hog, it never would be.
        #expect(try await ControlClient(path: server.path).send("polite") == "polite", "the stalled client holds up no one else")
        server.stop()  // and stopping (quit) doesn't wait for it: one that did would never return
        withExtendedLifetime(hog) {}
    }

    @Test func aClientThatStopsReadingIsDisconnectedAfterTheStallTimeout() async throws {
        let big = String(repeating: "y", count: 64 * 1024)
        let server = try server({ $0.stallTimeout = .milliseconds(300) }) { line in line == "hello" ? "hi" : big }
        defer { server.stop() }
        let hog = try ControlClient(path: server.path)
        #expect(try await hog.send("hello") == "hi", "connected, and reading at first")
        hog.sendRaw(Array("a\nb\nc\n".utf8))
        #expect(await eventually { server.connectionCount == 0 })
        // What was already in flight is still readable, then the connection ends.
        await #expect(throws: ControlClient.Failure.self) {
            for _ in 0..<3 { _ = try await hog.readLine() }
        }
    }

    @Test func atTheConnectionCapBusyClientsKeepTheirPlaceAndNewOnesWait() async throws {
        let gate = Gate()
        let server = try server({ $0.maxConnections = 2 }) { line in
            await gate.pass(line, holding: line == "slow")
            return line
        }
        defer { server.stop() }
        let first = try ControlClient(path: server.path)
        let second = try ControlClient(path: server.path)
        first.sendRaw(Array("slow\n".utf8))
        second.sendRaw(Array("slow\n".utf8))
        #expect(await eventually { gate.seen == ["slow", "slow"] && server.connectionCount == 2 }, "both connected and busy")
        let third = try ControlClient(path: server.path)  // connects into the backlog
        async let answer = third.send("3")
        try await Task.sleep(for: .milliseconds(50))  // time enough to be taken in, were it going to be
        #expect(server.connectionCount == 2, "both are busy: the new client waits")
        #expect(gate.seen == ["slow", "slow"], "unserved, and neither busy one was dropped for it")
        gate.open()
        #expect(try await answer == "3", "and is served once one of them is idle")
        #expect(try await first.readLine() == "slow")
    }

    @Test func atTheConnectionCapTheLongestIdleClientMakesRoom() async throws {
        let server = try server({ $0.maxConnections = 2 }) { $0 }
        defer { server.stop() }
        let oldest = try ControlClient(path: server.path)
        #expect(try await oldest.send("1") == "1")
        let newer = try ControlClient(path: server.path)
        #expect(try await newer.send("2") == "2")
        let third = try ControlClient(path: server.path)
        #expect(try await third.send("3") == "3", "served at once")
        await #expect(throws: ControlClient.Failure.self, "the longest-idle client was dropped") { try await oldest.readLine() }
        #expect(try await newer.send("still") == "still")
    }

    @Test func aBurstPastTheConnectionCapLosesNoRequest() async throws {
        let server = try server({ $0.maxConnections = 4 }) { "echo \($0)" }
        defer { server.stop() }
        // Every client connects and sends before any is served: the ones just
        // accepted have requests waiting, unread — they're not idle.
        let clients = try (0..<12).map { index in
            let client = try ControlClient(path: server.path)
            client.sendRaw(Array("\(index)\n".utf8))
            return client
        }
        for (index, client) in clients.enumerated() {
            #expect(try await client.readLine() == "echo \(index)")
        }
    }

    @Test func silentClientsMakeRoomOnceTheirGraceIsOver() async throws {
        let server = try server({
            $0.maxConnections = 2
            $0.newConnectionGrace = .milliseconds(100)
        }) { $0 }
        defer { server.stop() }
        // Their grace starts when the server takes them in: after this.
        let started = ContinuousClock.now
        let silent = try [ControlClient(path: server.path), ControlClient(path: server.path)]
        #expect(await eventually { server.connectionCount == 2 }, "both taken in before the next one comes")
        let waiting = try ControlClient(path: server.path)
        #expect(try await waiting.send("hello") == "hello")
        #expect(ContinuousClock.now - started >= .milliseconds(100), "not before the silent ones' grace was over")
        withExtendedLifetime(silent) {}
    }

    @Test func aClosedConnectionsQueuedRequestsNeverRun() async throws {
        let gate = Gate()
        let server = try server { line in
            await gate.pass(line, holding: true)
            return line
        }
        let client = try ControlClient(path: server.path)
        client.sendRaw(Array("a\nb\nc\n".utf8))
        #expect(await eventually { gate.seen == ["a"] }, "a is being handled, b and c wait their turn")
        server.stop()
        gate.open()
        try await Task.sleep(for: .milliseconds(100))  // were b and c still queued, they'd be handled now
        #expect(gate.seen == ["a"], "b and c were never handled")
        withExtendedLifetime(client) {}
    }

    @Test func aLastLineWithoutANewlineIsStillARequest() async throws {
        let server = try server { "echo \($0)" }
        defer { server.stop() }
        let client = try ControlClient(path: server.path)
        client.sendRaw(Array("one\ntwo".utf8))
        client.finishSending()
        #expect(try await client.readLine() == "echo one")
        #expect(try await client.readLine() == "echo two")
    }

    @Test func aSocketAnotherProcessIsListeningOnIsNeverTakenOver() async throws {
        let first = try server { "first \($0)" }
        defer { first.stop() }
        let second = ControlServer(path: first.path) { "second \($0)" }
        #expect(throws: ControlServer.StartError.inUse(first.path)) { try second.start() }
        #expect(try await ControlClient(path: first.path).send("x") == "first x")
    }

    @Test func brokenPipesAreCaughtNotIgnoredSoSpawnedShellsGetTheDefault() throws {
        let server = try server { $0 }
        defer { server.stop() }
        // A child that sends itself SIGPIPE dies of it only if it wasn't
        // spawned ignoring it (an ignored disposition survives exec).
        var pid: pid_t = 0
        let arguments = ["/bin/sh", "-c", "kill -PIPE $$; exit 7"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ) == 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(status & 0x7F == SIGPIPE, "killed by SIGPIPE, not exit 7 (status \(status))")
    }

    @Test func socketDescriptorsAreCloseOnExec() async throws {
        let server = try server { $0 }
        defer { server.stop() }
        let client = try ControlClient(path: server.path)
        #expect(try await client.send("x") == "x")
        // The listener and the accepted connection: a spawned shell must
        // inherit neither.
        let serverSide = Self.descriptors(boundTo: server.path)
        #expect(serverSide.count == 2)
        for fd in serverSide { #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "descriptor \(fd)") }
    }

    /// Open sockets whose local address is `path`.
    private static func descriptors(boundTo path: String) -> [Int32] {
        (Int32(0)..<Int32(getdtablesize())).filter { fd in
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0, address.sun_family == sa_family_t(AF_UNIX) else { return false }
            let bound = withUnsafeBytes(of: &address.sun_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return bound == path
        }
    }

    @Test func theSocketIsOwnerOnlyAndRemovedOnStop() throws {
        let server = try server { $0 }
        var info = stat()
        #expect(stat(server.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        server.stop()
        server.stop()
        #expect(stat(server.path, &info) != 0, "gone after stop")
        #expect(throws: ControlClient.Failure.self) { try ControlClient(path: server.path) }
    }

    @Test func aStaleSocketFileIsReplaced() async throws {
        let path = shortSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = ControlServer(path: path) { "fresh \($0)" }
        try server.start()
        defer { server.stop() }
        #expect(try await ControlClient(path: path).send("x") == "fresh x")
    }

    @Test func aPathTooLongForSockaddrIsRefusedClearly() {
        let path = "/tmp/" + String(repeating: "d", count: 120) + ".sock"
        #expect(throws: ControlServer.StartError.pathTooLong(path, limit: 104)) {
            try ControlServer(path: path) { $0 }.start()
        }
    }
}

/// What a stub handler was given, in order — and a gate that holds the
/// requests it is told to until the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Every request handed to the handler so far.
    var seen: [String] { lock.withLock { lines } }

    /// Records `line`; if `holding`, returns only once the gate is open.
    func pass(_ line: String, holding: Bool) async {
        lock.withLock { lines.append(line) }
        guard holding else { return }
        await withCheckedContinuation { continuation in
            let through = lock.withLock {
                if !isOpen { held.append(continuation) }
                return isOpen
            }
            if through { continuation.resume() }
        }
    }

    /// Lets every held request through, and any later one.
    func open() {
        let released = lock.withLock {
            isOpen = true
            defer { held.removeAll() }
            return held
        }
        for continuation in released { continuation.resume() }
    }
}

/// Polls `condition` until it holds; false if it still doesn't after `timeout`.
private func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

@MainActor
@Suite struct StaleSocketTests {
    @Test func socketsOfDeadProcessesAreRemovedAndLiveOnesKept() throws {
        let directory = TestSupport.temporaryDirectory()
        // A pid that can't be running (pid_max on macOS is 99998) and this process's own.
        let dead = directory.appending(path: "control-99999.sock").path
        let mine = directory.appending(path: "control-\(getpid()).sock").path
        let unrelated = directory.appending(path: "settings.json").path
        for path in [dead, mine, unrelated] { FileManager.default.createFile(atPath: path, contents: Data()) }
        #expect(ControlServer.removeStaleSockets(in: directory) == [dead])
        #expect(FileManager.default.fileExists(atPath: mine))
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }
}
