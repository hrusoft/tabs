import { execFile, execFileSync } from 'node:child_process'
import { readFileSync, readlinkSync } from 'node:fs'
import { readFile, readlink } from 'node:fs/promises'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/**
 * Caps how long a single probe may take, sync or async. The sync path runs
 * inline on the quit path and blocks the main process outright; the async
 * path is awaited with nothing above it — pane close (paneConfirmClose) and
 * pane creation (the terminal's deriveConfig) both wait on it, so an uncapped
 * hung `ps`/`lsof` would wedge those flows forever rather than degrade to
 * "unknown".
 */
const PROBE_TIMEOUT_MS = 1000

/**
 * One OS lookup about a live process, described once for both supported
 * platforms and runnable either async (ordinary IPC handlers) or sync (the
 * quit path, which cannot await — see CLAUDE.md's before-quit gotcha).
 *
 * Every failure mode — process gone mid-query, unsupported platform, the
 * exec/read itself failing — resolves to undefined: callers treat "unknown"
 * as "nothing to report", never as fatal.
 */
interface ProbeSpec<T> {
  /** The /proc file to read on Linux, and how. */
  linux: {
    op: 'readFile' | 'readlink'
    path: (pid: number) => string
    parse: (raw: string) => T | undefined
  }
  /** The command to exec on macOS, and how to parse its stdout. */
  darwin: {
    command: string
    args: (pid: number) => string[]
    parse: (stdout: string) => T | undefined
  }
}

async function probe<T>(spec: ProbeSpec<T>, pid: number): Promise<T | undefined> {
  try {
    if (process.platform === 'linux') {
      const { op, path, parse } = spec.linux
      return parse(
        op === 'readlink' ? await readlink(path(pid)) : await readFile(path(pid), 'utf-8')
      )
    }
    if (process.platform === 'darwin') {
      const { stdout } = await execFileAsync(spec.darwin.command, spec.darwin.args(pid), {
        timeout: PROBE_TIMEOUT_MS
      })
      return spec.darwin.parse(stdout)
    }
  } catch {
    // Unknown, not fatal — see ProbeSpec's doc comment.
  }
  return undefined
}

function probeSync<T>(spec: ProbeSpec<T>, pid: number): T | undefined {
  try {
    if (process.platform === 'linux') {
      const { op, path, parse } = spec.linux
      return parse(op === 'readlink' ? readlinkSync(path(pid)) : readFileSync(path(pid), 'utf-8'))
    }
    if (process.platform === 'darwin') {
      const stdout = execFileSync(spec.darwin.command, spec.darwin.args(pid), {
        encoding: 'utf-8',
        timeout: PROBE_TIMEOUT_MS
      })
      return spec.darwin.parse(stdout)
    }
  } catch {
    // Unknown, not fatal — see ProbeSpec's doc comment.
  }
  return undefined
}

// ---------------------------------------------------------------------------
// Parsers (exported for unit tests)
// ---------------------------------------------------------------------------

/** Parses `lsof -a -d cwd -Fn`'s field output, pulling the cwd out of its `n`-prefixed name field. */
export function parseLsofCwd(stdout: string): string | undefined {
  const line = stdout.split('\n').find((l) => l.startsWith('n'))
  return line ? line.slice(1) : undefined
}

/** Parses macOS/BSD `ps -o pgid=,tpgid= -p <pid>` output into its two integer fields. */
export function parsePgidTpgid(stdout: string): { pgid: number; tpgid: number } | undefined {
  const match = stdout.trim().match(/^(\d+)\s+(\d+)$/)
  if (!match) return undefined
  return { pgid: Number(match[1]), tpgid: Number(match[2]) }
}

/**
 * Parses the pgrp/tpgid fields out of Linux's `/proc/<pid>/stat`. The comm
 * field is parenthesized and may itself contain spaces or parens, so field
 * splitting starts after its *last* closing paren rather than assuming a
 * fixed column position for it.
 */
export function parseProcStatPgidTpgid(stat: string): { pgid: number; tpgid: number } | undefined {
  const closeParen = stat.lastIndexOf(')')
  if (closeParen === -1) return undefined
  const fields = stat
    .slice(closeParen + 1)
    .trim()
    .split(/\s+/)
  // Fields after comm, 0-indexed: state, ppid, pgrp, session, tty_nr, tpgid, ...
  const pgid = Number(fields[2])
  const tpgid = Number(fields[5])
  if (!Number.isFinite(pgid) || !Number.isFinite(tpgid)) return undefined
  return { pgid, tpgid }
}

/** Basename of a `ps`/`/proc` command path, since macOS's `ps -o comm=` sometimes reports a full path. */
function commandBasename(raw: string): string {
  return raw.trim().split('/').pop() as string
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

const cwdProbe: ProbeSpec<string> = {
  linux: { op: 'readlink', path: (pid) => `/proc/${pid}/cwd`, parse: (raw) => raw },
  darwin: {
    command: 'lsof',
    args: (pid) => ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'],
    parse: parseLsofCwd
  }
}

const pgidTpgidProbe: ProbeSpec<{ pgid: number; tpgid: number }> = {
  linux: { op: 'readFile', path: (pid) => `/proc/${pid}/stat`, parse: parseProcStatPgidTpgid },
  darwin: {
    command: 'ps',
    args: (pid) => ['-o', 'pgid=,tpgid=', '-p', String(pid)],
    parse: parsePgidTpgid
  }
}

const commandNameProbe: ProbeSpec<string> = {
  linux: { op: 'readFile', path: (pid) => `/proc/${pid}/comm`, parse: commandBasename },
  darwin: {
    command: 'ps',
    args: (pid) => ['-o', 'comm=', '-p', String(pid)],
    parse: commandBasename
  }
}

/** Best-effort live working directory of `pid`, looked up via the OS. */
export function getProcessCwd(pid: number): Promise<string | undefined> {
  return probe(cwdProbe, pid)
}

/** Synchronous twin of `getProcessCwd`, for the quit path. */
export function getProcessCwdSync(pid: number): string | undefined {
  return probeSync(cwdProbe, pid)
}

export interface ForegroundProcess {
  /** Best-effort short command name (e.g. "vim", "npm"), or undefined if it couldn't be determined. */
  command: string | undefined
}

/**
 * Best-effort check for whether `pid` (a shell on its own tty) is currently
 * *not* the tty's foreground process group — i.e. some other command (a long
 * build, vim, ssh, npm run dev...) owns the terminal, as opposed to the
 * shell sitting at an idle prompt. The same signal real terminal emulators
 * use for "are you sure you want to close this": process groups are
 * compared, not mere child processes, so an idle prompt with completion
 * daemons or a `command &` backgrounded job doesn't false-positive.
 * Undefined when idle or unknown.
 */
export async function getForegroundProcess(pid: number): Promise<ForegroundProcess | undefined> {
  const tpgid = foregroundTpgid(await probe(pgidTpgidProbe, pid))
  if (tpgid === undefined) return undefined
  return { command: await probe(commandNameProbe, tpgid) }
}

/** Synchronous twin of `getForegroundProcess`, for the quit path. */
export function getForegroundProcessSync(pid: number): ForegroundProcess | undefined {
  const tpgid = foregroundTpgid(probeSync(pgidTpgidProbe, pid))
  if (tpgid === undefined) return undefined
  return { command: probeSync(commandNameProbe, tpgid) }
}

/**
 * What "something other than the shell owns the terminal" means, stated once
 * for both twins: the tty's foreground process group differs from the
 * shell's own — undefined for an idle prompt or an unreadable pid.
 */
function foregroundTpgid(ids: { pgid: number; tpgid: number } | undefined): number | undefined {
  return !ids || ids.pgid === ids.tpgid ? undefined : ids.tpgid
}
