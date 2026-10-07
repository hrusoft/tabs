import Darwin
import Foundation
import Testing

/// `ShellProcess` and `ProcessProbe` against real processes on real ptys,
/// with shells that don't read the user's dotfiles (`/bin/sh`, `zsh -f`), so
/// every output is known.
@MainActor
@Suite struct TerminalProcessTests {
    /// What one process printed, and whether it has exited (and what had
    /// arrived by then).
    @MainActor
    final class Capture {
        var output: [UInt8] = []
        var exited = false
        var outputAtExit = ""
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    private static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    private func spawn(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:], directory: String = NSHomeDirectory(),
        columns: Int = 80, rows: Int = 24, queue: DispatchQueue? = nil
    ) throws -> (ShellProcess, Capture) {
        let capture = Capture()
        let process = try ShellProcess.spawn(
            executable: executable, arguments: arguments, environment: ["PATH": Self.path].merging(environment) { $1 },
            directory: directory, columns: columns, rows: rows, queue: queue,
            onOutput: { capture.output += $0 },
            onExit: {
                capture.exited = true
                capture.outputAtExit = capture.text
            })
        return (process, capture)
    }

    private func sh(_ script: String, environment: [String: String] = [:], directory: String = NSHomeDirectory()) throws -> (
        ShellProcess, Capture
    ) {
        try spawn("/bin/sh", ["-c", script], environment: environment, directory: directory)
    }

    /// An interactive zsh without startup files: job control on, and a known
    /// prompt, `READY> ` (set by a line that doesn't itself contain it).
    private func interactiveShell(directory: String = NSHomeDirectory()) throws -> (ShellProcess, Capture) {
        let (process, capture) = try spawn(
            "/bin/zsh", ["-f", "-i"], environment: ["TERM": "dumb", "HOME": NSHomeDirectory()], directory: directory)
        process.write(Array("PS1=\"RE\"\"ADY> \"\r".utf8))
        return (process, capture)
    }

    private func finish(_ process: ShellProcess, _ capture: Capture) async {
        process.terminate()
        _ = await eventually { capture.exited }
    }

    /// T-9 mechanics: output arrives in order, all of it before the exit.
    @Test func outputArrivesInOrderAndBeforeTheExit() async throws {
        let (_, capture) = try sh("printf one; printf two; printf 'three\\n'; exit 3")
        #expect(await eventually { capture.exited })
        #expect(capture.outputAtExit.contains("onetwothree"))
    }

    /// T-9 mechanics: the exit is reported even when watching for it began
    /// after the shell started exiting. The kernel then no longer finds the
    /// process, but holds its exit until its last output is read, and
    /// libdispatch reports the watch at once as an exit, before there's one
    /// to collect (a short command under load, in a busy app or test run).
    @Test func anExitIsReportedWhenWatchingBeginsLate() async throws {
        let io = DispatchQueue(label: "dev.tabs.terminal.pty.held")
        io.suspend()
        let (process, capture) = try spawn("/bin/sh", ["-c", "echo last; exit 3"], queue: io)
        // Exiting: no longer found, and held there by the output nobody reads yet.
        let exiting = await eventually { ProcessProbe.commandName(of: process.pid) == nil }
        io.resume()
        #expect(exiting)
        #expect(await eventually { capture.exited }, "\(capture.text)")
        #expect(capture.outputAtExit.contains("last"))
    }

    /// T-9 mechanics: a shell's last output waits for the reader, however
    /// late. zsh's exit, unlike sh's, would close the terminal, which keeps
    /// unread output only 0.6 s, but the app holds the terminal too
    /// (`ShellProcess.replica`).
    @Test func theLastOutputWaitsForALateReader() async throws {
        let io = DispatchQueue(label: "dev.tabs.terminal.pty.held")
        io.suspend()
        let (process, capture) = try spawn("/bin/zsh", ["-f", "-c", "echo last"], queue: io)
        let exiting = await eventually { ProcessProbe.commandName(of: process.pid) == nil }
        try await Task.sleep(for: .seconds(1))  // past the kernel's 0.6 s
        io.resume()
        #expect(exiting)
        #expect(await eventually { capture.exited }, "\(capture.text)")
        #expect(capture.outputAtExit.contains("last"))
    }

    /// T-3, T-5: the environment and the working directory given are the shell's.
    @Test func theEnvironmentAndDirectoryAreApplied() async throws {
        let directory = makeTemporaryDirectory()
        let (_, capture) = try sh("echo \"env:$GREETING:$(pwd -P)\"", environment: ["GREETING": "hello"], directory: directory)
        #expect(await eventually { capture.exited })
        #expect(capture.text.contains("env:hello:\(directory)"), "\(capture.text)")
    }

    /// T-7: the pty is the shell's controlling terminal, and its process
    /// group the foreground one (job control works).
    /// Under zsh too, which reopens its tty with O_NOCTTY and so never takes
    /// one itself (with posix_spawn alone it had none: no ⌃C, no job control).
    @Test(arguments: [["/bin/sh", "-c"], ["/bin/zsh", "-f", "-c"]])
    func thePtyIsTheControllingTerminal(shell: [String]) async throws {
        // The trailing `:` keeps the shell from exec'ing `ps` in its own place.
        let script = "echo \"tty:$(tty)\"; echo \"groups:$(ps -o pgid= -o tpgid= -p $$ | tr -s ' ')\"; :"
        let (_, capture) = try spawn(shell[0], Array(shell.dropFirst()) + [script])
        #expect(await eventually { capture.exited })
        #expect(capture.text.contains("tty:/dev/ttys"), "\(capture.text)")
        let groups = outputLines(capture.text).first { $0.hasPrefix("groups:") }?.dropFirst("groups:".count)
            .split(separator: " ").map(String.init)
        #expect(groups?.count == 2 && groups?.first == groups?.last, "\(capture.text)")
    }

    /// T-8, T-35, T-38: the pty starts at the size given, a resize reaches
    /// the shell as SIGWINCH with the new size, a zero size is ignored.
    @Test func resizingReachesTheShellAndAZeroSizeIsIgnored() async throws {
        let (process, capture) = try sh(
            "trap 'echo \"size:$(stty size)\"' WINCH; echo \"size:$(stty size)\"; while :; do sleep 0.05; done")
        #expect(await eventually { capture.text.contains("size:24 80") }, "\(capture.text)")
        process.resize(columns: 0, rows: 10)
        process.resize(columns: 50, rows: 0)
        // Time for a wrong resize's SIGWINCH to be trapped (the loop's sleep is 50 ms).
        try await Task.sleep(for: .milliseconds(150))
        process.resize(columns: 100, rows: 30)
        #expect(await eventually { capture.text.contains("size:30 100") }, "\(capture.text)")
        let sizes = outputLines(capture.text).filter { $0.hasPrefix("size:") }
        #expect(sizes.count == 2, "only the start and the real resize: \(sizes)")
        await finish(process, capture)
    }

    /// T-10: terminating ends the shell (SIGHUP, the pty hung up) and reaps it.
    @Test func terminatingEndsAndReapsTheShell() async throws {
        let (process, capture) = try interactiveShell()
        #expect(await eventually { capture.text.contains("READY>") })
        let pid = process.pid
        #expect(isAlive(pid))
        process.terminate()
        #expect(await eventually { capture.exited })
        #expect(!isAlive(pid), "reaped, not a zombie")
        process.terminate()  // twice is harmless
        process.write(Array("echo after\r".utf8))  // and writing after it is ignored
    }

    /// T-70 mechanics: an idle prompt owns its terminal; a running command
    /// holds the foreground group (and its name is known); a background job
    /// doesn't count.
    @Test func theForegroundGroupNamesARunningCommandOnly() async throws {
        let (process, capture) = try interactiveShell()
        #expect(await eventually { capture.text.contains("READY>") })
        #expect(ProcessProbe.foregroundGroup(of: process.pid) == nil, "idle")

        process.write(Array("sleep 30 &\r".utf8))
        #expect(await eventually { capture.text.components(separatedBy: "READY>").count >= 3 }, "\(capture.text)")
        try await Task.sleep(for: .milliseconds(75))
        #expect(
            ProcessProbe.foregroundGroup(of: process.pid) == nil,
            "a background job at an idle prompt")

        process.write(Array("sleep 30\r".utf8))
        // The group holds the terminal from the fork, still named zsh until it execs `sleep`.
        #expect(
            await eventually {
                ProcessProbe.foregroundGroup(of: process.pid).flatMap(ProcessProbe.commandName(of:)) == "sleep"
            })
        process.write([0x03])  // ⌃C reaches the foreground job
        #expect(
            await eventually {
                ProcessProbe.foregroundGroup(of: process.pid) == nil
            })
        process.write(Array("kill %1\r".utf8))
        await finish(process, capture)
    }

    /// T-100, T-106 mechanics: the live directory follows `cd`.
    @Test func theWorkingDirectoryFollowsCd() async throws {
        let directory = makeTemporaryDirectory()
        let (process, capture) = try interactiveShell()
        #expect(await eventually { capture.text.contains("READY>") })
        // The kernel reports a resolved path; home may be reached through a symlink.
        let resolved = realpath(NSHomeDirectory(), nil)
        defer { free(resolved) }
        let home = resolved.map { String(cString: $0) } ?? NSHomeDirectory()
        #expect(ProcessProbe.workingDirectory(of: process.pid) == home)
        process.write(Array("cd \(directory)\r".utf8))
        #expect(await eventually { ProcessProbe.workingDirectory(of: process.pid) == directory })
        await finish(process, capture)
        #expect(ProcessProbe.workingDirectory(of: process.pid) == nil, "gone: unknown, never fatal")
        #expect(ProcessProbe.commandName(of: process.pid) == nil)
    }

    /// A paste far larger than the pty's buffer arrives whole (written in
    /// pieces as the program reads).
    @Test func aLargeWriteArrivesWhole() async throws {
        let (process, capture) = try sh("stty raw -echo; echo READY-$((1+1)); head -c 200000 | wc -c")
        #expect(await eventually { capture.text.contains("READY-2") })
        process.write([UInt8](repeating: UInt8(ascii: "x"), count: 200_000))
        #expect(await eventually { capture.text.contains("200000") }, "\(capture.text.suffix(200))")
        await finish(process, capture)
    }

    /// A flood (`yes`) never gets further ahead of the main actor than the
    /// high-water mark: past it the pty isn't read, the kernel holds the
    /// program back, and ⌃C ends it at once instead of after gigabytes of
    /// queued output.
    @Test func aFloodIsPacedByTheMainActorAndCtrlCStopsIt() async throws {
        let (process, capture) = try sh("echo READY-$((1+1)); yes")
        #expect(await eventually { capture.text.contains("READY-2") })
        // The main actor busy elsewhere: nothing handed to it is drawn meanwhile.
        usleep(200_000)
        #expect(process.bytesInFlight <= ShellProcess.highWater + ShellProcess.chunkLimit)
        process.write([0x03])
        #expect(await eventually { capture.exited }, "⌃C ends the flood promptly, not after gigabytes")
        await finish(process, capture)
    }

    /// A signal the app ignores (started with `nohup`, say) isn't passed on:
    /// every signal starts at its default in the shell, so ⌃C still
    /// interrupts.
    @Test func anIgnoredSignalIsntInherited() async throws {
        // Ignored only across the fork (the child inherits dispositions there):
        // process-wide, so not a moment longer, with other tests running.
        let previous = signal(SIGINT, SIG_IGN)
        let spawned = Result { try sh("echo READY-$((1+1)); exec sleep 30") }
        signal(SIGINT, previous)
        let (process, capture) = try spawned.get()
        #expect(await eventually { capture.text.contains("READY-2") })
        process.write([0x03])
        #expect(
            await eventually { capture.exited },
            "⌃C interrupts (well before the sleep's 30 s), though the app ignores SIGINT: \(capture.text), alive: \(isAlive(process.pid))")
        await finish(process, capture)
    }

    /// A shell that can't start throws instead of leaving a dead process.
    @Test func aMissingExecutableThrows() {
        #expect(throws: ShellProcess.SpawnError.self) {
            _ = try ShellProcess.spawn(
                executable: "/no/such/shell", arguments: [], environment: [:], directory: "/", columns: 80, rows: 24,
                onOutput: { _ in }, onExit: {})
        }
    }
}
