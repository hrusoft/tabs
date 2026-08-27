import { randomUUID } from 'node:crypto'
import { mkdirSync, readdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { browserMainCtx } from './pluginContext'

/**
 * The on-disk sink for bytes an agent verb produces — screenshots, saved
 * resources and execute-js file output, each into its own subdirectory. Every
 * one of these hands main some bytes and gets back a *path*, because
 * `tabs-ctl`'s stdout becomes the calling agent's context verbatim and inline
 * bytes there are both enormous and unreadable.
 *
 * Generalized out of `writeScreenshot` so the three don't each reinvent the
 * directory-under-userData choice, the TTL sweep, and the guard around a
 * userData dir that can vanish under a live app (see persist.ts). Each caller
 * names its own subdirectory, so a sweep of one kind never touches another's.
 */

/**
 * How long a generated agent file stays on disk. Swept on every new write
 * rather than on a timer, so a directory can't grow without bound and a caller
 * still has ample time to read the file it was just handed. A caller-named
 * path (an explicit `--out`) is the caller's to manage and is never swept.
 */
const AGENT_FILE_TTL_MS = 10 * 60 * 1000

/**
 * A directory of our own under userData rather than the shared OS temp dir:
 * these files are readable page content, and they should live somewhere
 * attributable to this app and sweepable by it, not in a world-writable
 * directory alongside everything else on the machine.
 */
export function agentFileDir(subdir: string): string {
  const dir = browserMainCtx.get().userDataPath(subdir)
  mkdirSync(dir, { recursive: true })
  return dir
}

/**
 * How often a *write* may pay for a sweep. The TTL is ten minutes, so nothing
 * here needs per-write precision — and without a floor the cost is quadratic:
 * an agent screenshotting on a one-second timer reaches ~600 files inside the
 * TTL and then pays ~600 synchronous stats on the main thread per further
 * screenshot. The launch-time sweep and any explicit call are unaffected; this
 * only throttles the incidental one.
 */
const SWEEP_INTERVAL_MS = 60 * 1000

/** When each subdirectory was last swept from a write, by absolute path. */
const lastSweptAt = new Map<string, number>()

/** Mutable main-process state, so it resets between e2e tests like every other. */
export function resetAgentFileSweepForTests(): void {
  lastSweptAt.clear()
}

export function sweepStaleAgentFiles(dir: string): void {
  lastSweptAt.set(dir, Date.now())
  const cutoff = Date.now() - AGENT_FILE_TTL_MS
  let names: string[]
  try {
    names = readdirSync(dir)
  } catch {
    // The directory vanished between mkdir and here, or isn't listable —
    // sweeping is best-effort housekeeping, same as the per-file branch below.
    return
  }
  for (const name of names) {
    const file = join(dir, name)
    try {
      if (statSync(file).mtimeMs < cutoff) unlinkSync(file)
    } catch {
      // Racing another sweep, or a file someone else already removed —
      // sweeping is best-effort housekeeping, never the caller's problem.
    }
  }
}

/**
 * Writes `bytes` into `subdir` under a generated `<uuid>.<ext>` name, sweeping
 * that subdirectory's stale files first, and returns the absolute path. `ext`
 * is without a dot. Throws on a write failure (a vanished/unwritable userData
 * dir); the caller — inside verb dispatch, owing a socket a ControlResponse —
 * turns that into a clean error, the same as `writeScreenshot` always has.
 */
function writeAgentFile(subdir: string, bytes: Uint8Array, ext: string): string {
  const dir = agentFileDir(subdir)
  if (Date.now() - (lastSweptAt.get(dir) ?? 0) >= SWEEP_INTERVAL_MS) sweepStaleAgentFiles(dir)
  const path = join(dir, `${randomUUID()}.${ext}`)
  writeFileSync(path, bytes)
  return path
}

/**
 * The whole of the `--out` contract every byte-producing verb shares, so none
 * of them restates it: an `outPath` string is a caller-named absolute path
 * (tabs-ctl resolved it against the caller's cwd), written `wx` and never
 * swept — the file is the caller's to manage; anything else (tabs-ctl's bare
 * `--out` arrives as `true`) gets a generated path under the swept `subdir`.
 *
 * `wx` is what refuses to clobber. The caller named this path; silently
 * overwriting whatever is there is the worse surprise, and a re-run with a
 * fresh name is one line for the caller — which is why the refusal's wording
 * is a contract SKILL.md leans on, and therefore belongs in one place rather
 * than in each verb. `what` names the thing in the generic failure message
 * ("could not write the <what> to disk").
 *
 * Returns the path written, or a message ready to become a failed
 * ControlResponse — never throws, so a verb handler stays a straight line.
 */
export function writeAgentOutput(
  outPath: string | true | undefined,
  bytes: Uint8Array,
  options: { subdir: string; ext: string; what: string }
): { path: string } | { error: string } {
  try {
    if (typeof outPath === 'string' && outPath.length > 0) {
      writeFileSync(outPath, bytes, { flag: 'wx' })
      return { path: outPath }
    }
    return { path: writeAgentFile(options.subdir, bytes, options.ext) }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      return { error: `refusing to overwrite an existing file: ${String(outPath)}` }
    }
    return { error: `could not write the ${options.what} to disk: ${String(error)}` }
  }
}
