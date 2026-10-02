import Foundation
import os

/// One child process run to completion with the Electron app's `execFile`
/// rules: output drained as it arrives (a full pipe would stall the child),
/// killed at `timeout`, killed when stdout passes `maxBuffer`. Never throws.
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

    static func run(
        executable: String, arguments: [String], directory: String, environment: [String: String], timeout: Duration,
        maxBuffer: Int
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

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            // Resumed exactly once: when the process has exited and both pipes
            // reached EOF, or when launching failed.
            let finish: @Sendable () -> Void = {
                let outcome: Outcome? = state.withLock { collected in
                    guard !collected.resumed, collected.exited, collected.stdoutClosed, collected.stderrClosed else { return nil }
                    collected.resumed = true
                    let err = String(decoding: collected.stderr, as: UTF8.self)
                    if collected.overflowed { return .overflowed(stderr: err) }
                    if collected.timedOut { return .timedOut(stderr: err) }
                    return .exited(collected.status, stdout: String(decoding: collected.stdout, as: UTF8.self), stderr: err)
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.withLock { $0.stdoutClosed = true }
                    finish()
                    return
                }
                let overflow = state.withLock { collected -> Bool in
                    collected.stdout.append(data)
                    if collected.stdout.count > maxBuffer, !collected.overflowed {
                        collected.overflowed = true
                        return true
                    }
                    return false
                }
                if overflow { process.terminate() }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.withLock { $0.stderrClosed = true }
                    finish()
                    return
                }
                state.withLock { collected in
                    if collected.stderr.count < maxBuffer { collected.stderr.append(data) }
                }
            }
            process.terminationHandler = { process in
                state.withLock {
                    $0.exited = true
                    $0.status = process.terminationStatus
                }
                finish()
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
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
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                let running = state.withLock { collected -> Bool in
                    guard !collected.exited else { return false }
                    collected.timedOut = true
                    return true
                }
                if running { process.terminate() }
            }
        }
    }

    private struct Collected: Sendable {
        var stdout = Data()
        var stderr = Data()
        var status: Int32 = 0
        var exited = false
        var stdoutClosed = false
        var stderrClosed = false
        var timedOut = false
        var overflowed = false
        var resumed = false
    }
}
