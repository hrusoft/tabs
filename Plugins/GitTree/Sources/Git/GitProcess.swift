import Foundation
import os

/// One child process run to completion: output drained as it arrives (a full
/// pipe would stall the child), given up on at `timeout`, stopped when stdout
/// passes `maxBuffer`. Never throws, and always answers: at `timeout` at the
/// latest, whether or not the process can be stopped, and soon after it exits
/// even while something it started still holds its output.
enum GitProcess {
    enum Outcome: Sendable {
        case exited(Int32, stdout: String, stderr: String)
        case launchFailed(String)
        case timedOut(stderr: String)
        case overflowed(stderr: String)

        var isOverflow: Bool {
            if case .overflowed = self { true } else { false }
        }
    }

    /// How often the pipes are looked at once the process has exited. A job a
    /// hook puts in the background without redirecting its output holds them
    /// for as long as it runs: the first look finding them quiet (nothing
    /// waiting in them, no read under way) answers with what arrived. The
    /// process wrote all its own output before it exited, so quiet pipes have
    /// given every byte of it, however late their reader runs.
    static let drainGrace: Duration = .milliseconds(500)
    /// How long a process told to stop (SIGTERM) at the timeout has before it's
    /// killed (SIGKILL). git removes its lock files on SIGTERM, never on SIGKILL.
    static let killGrace: Duration = .seconds(2)

    static func run(
        executable: String, arguments: [String], directory: String, environment: [String: String], timeout: Duration,
        maxBuffer: Int, drainGrace: Duration = GitProcess.drainGrace
    ) async -> Outcome {
        let state = OSAllocatedUnfairLock(initialState: Collected())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let outputs: [(Output, FileHandle)] = [(.stdout, stdout.fileHandleForReading), (.stderr, stderr.fileHandleForReading)]

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            // Resumed exactly once: when the process has exited and both pipes
            // reached EOF; without waiting for EOF (`now`), once the pipes are
            // quiet after it exited or at the timeout; or when launching
            // failed. The pipes aren't read after that.
            let finish: @Sendable (_ now: Bool) -> Void = { now in
                let outcome: Outcome? = state.withLock { collected in
                    guard !collected.resumed else { return nil }
                    guard now || (collected.exited && collected.stdout.closed && collected.stderr.closed) else { return nil }
                    collected.resumed = true
                    let answer = collected.outcome
                    // Not read again, and the timeout keeps `state` until it fires.
                    collected.stdout.data = Data()
                    collected.stderr.data = Data()
                    return answer
                }
                guard let outcome else { return }
                for (_, handle) in outputs { handle.readabilityHandler = nil }
                continuation.resume(returning: outcome)
            }
            // A read counts from before it takes the bytes until they're
            // collected, so the pipes never look quiet in between.
            for (output, handle) in outputs {
                handle.readabilityHandler = { handle in
                    state.withLock { $0.reading += 1 }
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    let overflow = state.withLock { collected in
                        collected.reading -= 1
                        return collected.take(data, from: output, maxBuffer: maxBuffer)
                    }
                    if data.isEmpty { finish(false) }
                    if overflow { process.terminate() }
                }
            }
            // Something the process left running may hold the pipes: answered
            // once they're quiet, looked at every `drainGrace` from the exit.
            @Sendable func answerWhenQuiet() {
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds(drainGrace)) {
                    let quiet = state.withLock { collected -> Bool? in
                        guard !collected.resumed else { return nil }
                        return collected.reading == 0 && !hasInput(outputs.filter { !collected[$0.0].closed }.map(\.1))
                    }
                    switch quiet {
                    case true?: finish(true)
                    case false?: answerWhenQuiet()
                    case nil: break
                    }
                }
            }
            process.terminationHandler = { process in
                state.withLock {
                    $0.exited = true
                    $0.status = process.terminationStatus
                }
                finish(false)
                guard !state.withLock({ $0.resumed }) else { return }
                answerWhenQuiet()
            }
            do {
                try process.run()
            } catch {
                for (_, handle) in outputs { handle.readabilityHandler = nil }
                let resume = state.withLock { collected -> Bool in
                    guard !collected.resumed else { return false }
                    collected.resumed = true
                    return true
                }
                if resume { continuation.resume(returning: .launchFailed(error.localizedDescription)) }
                return
            }
            // Our copies of the write ends: without closing them the pipes
            // never reach EOF.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(timeout)) {
                // An exited process whose pipes never went quiet is answered
                // with what they gave; one still running is given up on.
                let running = state.withLock { collected -> Bool in
                    guard !collected.resumed, !collected.exited else { return false }
                    collected.timedOut = true
                    return true
                }
                // The caller is answered first: a process may not stop, or not
                // at once (git stuck in uninterruptible I/O, one ignoring SIGTERM).
                finish(true)
                guard running else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds(killGrace)) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Whether any of `handles` has bytes waiting, or an EOF not yet read.
    private static func hasInput(_ handles: [FileHandle]) -> Bool {
        var fds = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        return poll(&fds, nfds_t(fds.count), 0) != 0
    }

    private enum Output { case stdout, stderr }

    /// One pipe's bytes so far, and whether it reached EOF.
    private struct Stream: Sendable {
        var data = Data()
        var closed = false
    }

    private struct Collected: Sendable {
        var stdout = Stream()
        var stderr = Stream()
        var status: Int32 = 0
        var exited = false
        /// Reads under way: bytes taken from a pipe, not yet collected.
        var reading = 0
        var timedOut = false
        var overflowed = false
        var resumed = false

        subscript(output: Output) -> Stream {
            get { output == .stdout ? stdout : stderr }
            set { if output == .stdout { stdout = newValue } else { stderr = newValue } }
        }

        /// One read of `output` collected (empty: its EOF). Returns true when
        /// stdout just passed `maxBuffer`, so the process is to be stopped;
        /// stderr past it is only cut.
        mutating func take(_ data: Data, from output: Output, maxBuffer: Int) -> Bool {
            guard !data.isEmpty else {
                self[output].closed = true
                return false
            }
            switch output {
            case .stdout:
                stdout.data.append(data)
                guard stdout.data.count > maxBuffer, !overflowed else { return false }
                overflowed = true
                return true
            case .stderr:
                if stderr.data.count < maxBuffer { stderr.data.append(data) }
                return false
            }
        }

        /// The answer from what has been collected.
        var outcome: Outcome {
            let err = String(decoding: stderr.data, as: UTF8.self)
            if overflowed { return .overflowed(stderr: err) }
            if timedOut { return .timedOut(stderr: err) }
            return .exited(status, stdout: String(decoding: stdout.data, as: UTF8.self), stderr: err)
        }
    }
}
