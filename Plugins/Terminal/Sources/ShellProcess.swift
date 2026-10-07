import Darwin
import Foundation

/// One shell on its own pseudo-terminal, without a helper process and
/// without touching the app's own state:
///
/// - **Spawned as `forkpty` does** (`openpty`, `fork`, `login_tty`): the child
///   is a new session with the pty as its controlling terminal (so job
///   control, ⌃C and ⌃Z work), then makes only system calls until `execve`:
///   the child's own directory, the environment as an argument. The app's
///   directory and environment are never changed.
/// - **Only the pty is inherited**, and every signal starts at its default,
///   unblocked: an app started with a signal ignored (`nohup`) doesn't pass
///   that on, so ⌃C still interrupts.
/// - **I/O runs on a private queue.** Output is read as it arrives and handed
///   to the main actor in order, the shell's last output before its exit;
///   input is written without ever blocking the main thread.
/// - **The last output waits for the reader**, however late (see `replica`).
/// - **Output is paced by the main actor.** At most `highWater` bytes wait
///   for it; past that the pty isn't read until they're drawn, so the kernel
///   holds the program back (`yes`, `cat` of a huge file) and ⌃C takes effect
///   at once.
/// - **Ending it** hangs up the pty (the shell gets SIGHUP); the exit is
///   reaped whenever it comes.
final class ShellProcess: @unchecked Sendable {
    struct SpawnError: Error, CustomStringConvertible {
        let description: String
    }

    let pid: pid_t
    private let master: Int32
    /// The app's own hold on the pty's terminal side, until the exit is
    /// reaped. Without it the shell's exit can be the terminal's last close,
    /// which waits at most 0.6 s for the output to be read and then discards
    /// it (zsh's exit comes to that): a reader late under load lost a short
    /// command's output, or a login shell's last lines. With it, the exit
    /// waits for the reader, then revokes the terminal (the master hangs up).
    private let replica: Int32
    /// Serial.
    private let io: DispatchQueue
    /// Delivered on the main actor, in order.
    private let onOutput: @MainActor @Sendable ([UInt8]) -> Void
    private let onExit: @MainActor @Sendable () -> Void

    /// The most read at once, per hand-off to the main actor.
    static let chunkLimit = 256 * 1024
    /// Output handed to the main actor and not yet drawn above which the pty
    /// isn't read, and the level at which reading resumes.
    static let highWater = 1024 * 1024
    static let lowWater = 256 * 1024

    // Confined to `io`.
    private var reader: DispatchSourceRead?
    private var readerIsSuspended = false
    private var exitWatch: DispatchSourceProcess?
    private var pending: [UInt8] = []
    private var retryingWrite = false
    private var writeRetryDelay = 10
    private var masterIsOpen = true
    private var hasExited = false
    private var reapRetryDelay = 1
    /// Bytes handed to the main actor and not yet consumed there.
    private var inFlight = 0

    private init(
        pid: pid_t, master: Int32, replica: Int32, io: DispatchQueue, onOutput: @escaping @MainActor @Sendable ([UInt8]) -> Void,
        onExit: @escaping @MainActor @Sendable () -> Void
    ) {
        self.pid = pid
        self.master = master
        self.replica = replica
        self.io = io
        self.onOutput = onOutput
        self.onExit = onExit
    }

    /// Starts `executable` with `arguments` (argv[0] is the executable) on a
    /// new `columns`×`rows` pty in `directory`. Its I/O runs on a serial
    /// queue of its own, or on `queue` (a test holds one, to begin late).
    static func spawn(
        executable: String, arguments: [String], environment: [String: String], directory: String, columns: Int, rows: Int,
        queue: DispatchQueue? = nil, onOutput: @escaping @MainActor @Sendable ([UInt8]) -> Void,
        onExit: @escaping @MainActor @Sendable () -> Void
    ) throws -> ShellProcess {
        // exec fails in the child, where nothing can be reported: check first.
        guard access(executable, X_OK) == 0 else { throw SpawnError(description: "\(executable): \(errnoText())") }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        // A fresh pty's modes, plus line editing that knows UTF-8 (backspace
        // over a multibyte character).
        var modes = termios()
        var hasModes = false
        var probeMaster: Int32 = -1
        var probeSlave: Int32 = -1
        if openpty(&probeMaster, &probeSlave, nil, nil, nil) == 0 {
            hasModes = tcgetattr(probeSlave, &modes) == 0
            close(probeSlave)
            close(probeMaster)
        }
        modes.c_iflag |= tcflag_t(IUTF8)

        // Everything the child uses is made before the fork: between fork and
        // exec it makes only system calls (the app's other threads, and any
        // lock they held, don't exist in the child).
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(executable)
        let cwd = strdup(directory)
        defer {
            for pointer in argv + envp + [path, cwd] { free(pointer) }
        }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        let defaultHandler = SIG_DFL
        let descriptorLimit = min(getdtablesize(), 1 << 16)

        // The pty is made here, not by forkpty, which would close the app's
        // replica (see `replica`).
        var master: Int32 = -1
        var replica: Int32 = -1
        let opened = hasModes ? openpty(&master, &replica, nil, &modes, &size) : openpty(&master, &replica, nil, nil, &size)
        guard opened == 0 else { throw SpawnError(description: "openpty: \(errnoText())") }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(replica, F_SETFD, FD_CLOEXEC)
        let pid = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                // As forkpty: the child is a new session whose controlling
                // terminal, stdin, stdout and stderr are the pty (login_tty).
                // (posix_spawn's setsid plus opening the slave doesn't make it
                // the controlling terminal: zsh, which reopens its tty with
                // O_NOCTTY, would get no job control and no ⌃C.)
                let pid = forkProcess()
                if pid == 0 {
                    // Without a controlling terminal (it can't be made one),
                    // the pty is still its stdio, as forkpty does.
                    if login_tty(replica) != 0 {
                        _ = dup2(replica, 0)
                        _ = dup2(replica, 1)
                        _ = dup2(replica, 2)
                    }
                    sigprocmask(SIG_SETMASK, &unblocked, nil)
                    // Every signal at its default: an ignored one would
                    // survive exec (SIGKILL and SIGSTOP just refuse).
                    var signalNumber: Int32 = 1
                    while signalNumber < 32 {
                        _ = signal(signalNumber, defaultHandler)  // boundary: allow — the forked child's own dispositions, before exec
                        signalNumber += 1
                    }
                    // Only the pty is inherited.
                    var descriptor: Int32 = 3
                    while descriptor < descriptorLimit {
                        close(descriptor)
                        descriptor += 1
                    }
                    _ = chdir(cwd)  // boundary: allow — the forked child's own directory, before exec; the app's is untouched
                    _ = execve(path, argvBuffer.baseAddress, envpBuffer.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else {
            let reason = errnoText()
            close(master)
            close(replica)
            throw SpawnError(description: "fork: \(reason)")
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let process = ShellProcess(
            pid: pid, master: master, replica: replica, io: queue ?? DispatchQueue(label: "dev.tabs.terminal.pty"), onOutput: onOutput,
            onExit: onExit)
        process.io.async { process.start() }
        return process
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }

    /// fork(2), libSystem's, as forkpty calls it. Swift doesn't offer it (it
    /// points to posix_spawn, which can't give the child a controlling
    /// terminal).
    private static let forkProcess = unsafeBitCast(
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork")!,  // RTLD_DEFAULT
        to: (@convention(c) () -> pid_t).self)

    // MARK: I/O (on `io`)

    private func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: io)
        reader.setEventHandler { [self] in drain() }
        reader.setCancelHandler { [self] in
            masterIsOpen = false
            close(master)
        }
        self.reader = reader
        reader.resume()
        let exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: io)
        exitWatch.setEventHandler { [self] in reap(untilReaped: true) }
        self.exitWatch = exitWatch
        exitWatch.resume()
        // It may have exited before the watch began.
        reap(untilReaped: false)
    }

    /// Reads what's waiting (up to `chunkLimit`) and hands it to the main
    /// actor as one chunk; stops reading while too much waits there.
    private func drain() {
        guard masterIsOpen else { return }
        var chunk: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var hungUp = false
        while chunk.count < Self.chunkLimit {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                chunk.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // EAGAIN: nothing more for now. 0 or EIO: every slave is closed.
                hungUp = count == 0 || errno != EAGAIN
                break
            }
        }
        if !chunk.isEmpty {
            let onOutput = onOutput
            let count = chunk.count
            inFlight += count
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onOutput(chunk) }
                self.io.async { self.consumed(count) }
            }
            if inFlight >= Self.highWater, !readerIsSuspended, !hungUp {
                reader?.suspend()
                readerIsSuspended = true
            }
        }
        if hungUp { cancelReader() }
    }

    /// The main actor drew `count` bytes: read again once it has caught up.
    private func consumed(_ count: Int) {
        inFlight -= count
        guard readerIsSuspended, inFlight <= Self.lowWater else { return }
        readerIsSuspended = false
        reader?.resume()
    }

    /// Stops reading and closes the pty (in the cancel handler). A suspended
    /// source runs no cancel handler until resumed, so it's resumed first.
    private func cancelReader() {
        if readerIsSuspended {
            readerIsSuspended = false
            reader?.resume()
        }
        reader?.cancel()
    }

    /// Collects the exit, once: the last output first, then the exit.
    ///
    /// The exit event comes once, and can come before there's an exit to
    /// collect, so after it (`untilReaped`) this tries again until there is:
    /// - XNU stops finding an exiting process (`proc_refdrain`) before it
    ///   lets the exit finish, which waits until the shell's last output is
    ///   read (by the reader, on this queue). A watch that begins in between
    ///   finds no process, and libdispatch reports that as an exit at once.
    /// - It posts the exit event before it marks the process a zombie.
    ///
    /// Never by blocking: the exit may be waiting for the reader. Gone already
    /// (`ECHILD`) counts as exited.
    private func reap(untilReaped: Bool) {
        guard !hasExited else { return }
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, WNOHANG)
        while reaped < 0, errno == EINTR { reaped = waitpid(pid, &status, WNOHANG) }
        guard reaped == pid || (reaped < 0 && errno == ECHILD) else {
            guard untilReaped else { return }
            let delay = reapRetryDelay
            reapRetryDelay = min(reapRetryDelay * 2, 100)
            io.asyncAfter(deadline: .now() + .milliseconds(delay)) { [self] in reap(untilReaped: true) }
            return
        }
        hasExited = true
        exitWatch?.cancel()
        drain()
        // Nothing more can come: the master hangs up once nothing else (a
        // background job) holds the terminal.
        close(replica)
        let onExit = onExit
        DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } }
    }

    private func flush() {
        while !pending.isEmpty, masterIsOpen {
            let written = pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
                writeRetryDelay = 10
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                // The shell isn't reading: try again later, never blocking,
                // backing off to a quarter second while it goes on not reading.
                guard !retryingWrite else { return }
                retryingWrite = true
                let delay = writeRetryDelay
                writeRetryDelay = min(writeRetryDelay * 2, 250)
                io.asyncAfter(deadline: .now() + .milliseconds(delay)) { [self] in
                    retryingWrite = false
                    flush()
                }
                return
            } else {
                pending.removeAll()
            }
        }
        if !masterIsOpen { pending.removeAll() }
    }

    // MARK: Called from the main actor

    /// Sends the user's input to the shell.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        io.async { [self] in
            pending.append(contentsOf: bytes)
            flush()
        }
    }

    /// Output handed to the main actor and not yet consumed there (tests).
    var bytesInFlight: Int { io.sync { inFlight } }

    /// Resizes the pty; the shell gets SIGWINCH. A zero size is ignored.
    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        io.async { [self] in
            guard masterIsOpen else { return }
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
        }
    }

    /// Ends the shell: SIGHUP, and the pty hung up. Synchronous (it runs at
    /// quit too, with nothing after it), and safe to call twice. The pid is
    /// signalled only while unreaped, so it can't have been reused.
    func terminate() {
        io.sync {
            if !hasExited { kill(pid, SIGHUP) }
            cancelReader()
        }
    }
}
