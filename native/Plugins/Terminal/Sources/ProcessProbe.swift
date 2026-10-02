import Darwin

/// What the OS knows about a live shell — `processProbe.ts`, asked of the
/// kernel directly instead of `lsof` and `ps`: synchronous, cheap (a syscall,
/// no child process), so there's no async twin and no timeout. Every failure
/// (the process gone mid-query, a pid that isn't ours) is nil: "unknown", never
/// fatal, as there.
enum ProcessProbe {
    /// The live working directory of `pid` (its `cd`s included), or nil.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// The short command name of `pid` (`vim`, `npm`), or nil.
    static func commandName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// `pid`'s process group, and its terminal's foreground process group
    /// (`ps -o pgid=,tpgid=`), or nil.
    static func processGroups(of pid: pid_t) -> (group: pid_t, terminalGroup: pid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (pid_t(bitPattern: info.pbi_pgid), pid_t(bitPattern: info.e_tpgid))
    }

    /// The process group holding the shell's terminal when it isn't the
    /// shell's own — something other than an idle prompt owns the terminal
    /// (a build, vim, ssh): the signal real terminal emulators use for "are
    /// you sure". Process groups, not child processes, so a completion daemon
    /// or a `cmd &` job at an idle prompt doesn't count. nil: idle, or unknown.
    static func foregroundGroup(of shell: pid_t) -> pid_t? {
        guard let groups = processGroups(of: shell), groups.group > 0, groups.terminalGroup > 0,
            groups.terminalGroup != groups.group
        else { return nil }
        return groups.terminalGroup
    }
}
