import { execFileSync } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/**
 * Two macOS mechanisms can block an unattended e2e run on a modal dialog
 * nothing will ever click, both triggered by a crashing Electron instance
 * (see CLAUDE.md's before-quit gotcha for the specific crash this suite has
 * hit):
 *
 * - CrashReporter's "quit unexpectedly" report dialog, suppressed by forcing
 *   `DialogType` to `none`.
 * - AppKit's window-restoration prompt ("the app quit unexpectedly — reopen
 *   its windows?"), shown *inside the next launch of the app itself* by
 *   `-[NSPersistentUIRestorer promptToIgnorePersistentStateWithCrashHistory:]`
 *   before the main run loop starts. Its crash history is keyed to the app
 *   bundle (the dev Electron binary), NOT the Chromium --user-data-dir, so
 *   one crash mid-suite makes every later `firstWindow()` in that run — and
 *   in every following run — time out on an invisible modal until suppressed
 *   via `ApplePersistenceIgnoreState`.
 *
 * Both keys are set for the duration of the run and restored (or removed
 * again if unset before) on teardown, so neither changes machine behavior
 * long-term.
 */
interface Override {
  domain: string
  key: string
  /** Arguments for `defaults write`. */
  write: string[]
  /** What `defaults read` prints back once written — see the skip in setup. */
  reads: string
}

const OVERRIDES: Override[] = [
  { domain: 'com.apple.CrashReporter', key: 'DialogType', write: ['none'], reads: 'none' },
  {
    domain: 'com.github.Electron',
    key: 'ApplePersistenceIgnoreState',
    write: ['-bool', 'YES'],
    reads: '1'
  }
]

/**
 * Both keys are machine-global user defaults — not scoped to a run, a worktree
 * or a `--user-data-dir` — so two runs overlapping in time race on them, and
 * the *restore* is the half that breaks. Done naively, the first run records
 * "was unset", the second reads the key and records the first run's own value
 * as though it were the machine's, and whichever finishes first strips the
 * suppression from every run still in flight. Losing
 * ApplePersistenceIgnoreState mid-run is the expensive direction: the prompt it
 * suppresses is shown inside the *next* launch of the app, before any renderer
 * exists to click it, so every later `firstWindow()` in that run hangs to its
 * timeout — one unlucky interleaving becomes a run-wide cascade.
 *
 * So the overrides are refcounted through this directory. Each run drops a
 * marker named for its pid; the first run to arrive records the machine's true
 * values in `original.json` (with the 'wx' flag, so exactly one writer can
 * win); and only the last run out — the one that finds no other live marker —
 * restores them. A run that finds the suppression already in place doesn't
 * write it, and so has nothing to undo.
 *
 * Markers are swept by pid liveness, the same idea as the per-pid
 * external-control socket sweep (see CLAUDE.md), and with the same caveat: pid
 * reuse can make a dead run's marker look live. A run that is SIGKILLed leaves
 * its marker behind for the same reason. Both fail in the safe direction —
 * suppression lingering a while longer, never a live run losing it — and the
 * next run's sweep clears them.
 */
const coordDir = join(tmpdir(), 'tabs-e2e-defaults')
const originalsPath = join(coordDir, 'original.json')

/** The machine's own value per key; `null` means "was not set at all". */
type Originals = Record<string, string | null>

function keyOf({ domain, key }: Override): string {
  return `${domain} ${key}`
}

function readDefault({ domain, key }: Override): string | null {
  try {
    // stderr is suppressed: an unset key makes `defaults read` print its own
    // "does not exist" diagnostic straight to stderr on top of exiting
    // non-zero, which is expected here, not a real failure to surface.
    return execFileSync('defaults', ['read', domain, key], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim()
  } catch {
    return null
  }
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/** Drops markers whose run is gone, and returns the pids still running. */
function sweepMarkers(): number[] {
  let entries: string[]
  try {
    entries = readdirSync(coordDir)
  } catch {
    return []
  }
  const live: number[] = []
  for (const entry of entries) {
    if (!entry.startsWith('run-')) continue
    const pid = Number(entry.slice('run-'.length))
    if (!Number.isInteger(pid)) continue
    if (isAlive(pid)) live.push(pid)
    else rmSync(join(coordDir, entry), { force: true })
  }
  return live
}

export default function globalSetup(): (() => void) | undefined {
  if (process.platform !== 'darwin') return

  mkdirSync(coordDir, { recursive: true })
  // No live run means any leftover record belongs to runs that are all gone,
  // and keeping it would have this run restore some dead run's values.
  if (sweepMarkers().length === 0) rmSync(originalsPath, { force: true })

  const current: Originals = {}
  for (const override of OVERRIDES) current[keyOf(override)] = readDefault(override)
  try {
    writeFileSync(originalsPath, JSON.stringify(current, null, 2), { flag: 'wx' })
  } catch {
    // A live run recorded the originals first; that record is the true one.
  }

  const marker = join(coordDir, `run-${process.pid}`)
  writeFileSync(marker, '')

  for (const override of OVERRIDES) {
    // Already suppressed (very likely by a run started just before this one):
    // don't write, so this run has nothing to restore either.
    if (current[keyOf(override)] === override.reads) continue
    execFileSync('defaults', ['write', override.domain, override.key, ...override.write])
  }

  return () => {
    rmSync(marker, { force: true })
    // Someone else is still running and still needs the suppression: leave
    // both keys, and the record of the originals, exactly as they are.
    if (sweepMarkers().length > 0) return

    let originals: Originals | undefined
    try {
      originals = JSON.parse(readFileSync(originalsPath, 'utf-8')) as Originals
    } catch {
      // No readable record — leave the machine alone rather than guess.
      // Deleting a key the user set deliberately is worse than leaving ours
      // in place, and it is not this run's to delete.
      originals = undefined
    }
    for (const override of OVERRIDES) {
      const original = originals?.[keyOf(override)]
      if (original === undefined) continue
      try {
        if (original === null) {
          execFileSync('defaults', ['delete', override.domain, override.key])
        } else {
          execFileSync('defaults', ['write', override.domain, override.key, original])
        }
      } catch {
        // Best-effort restore; nothing else to do if this fails.
      }
    }
    rmSync(coordDir, { recursive: true, force: true })
  }
}
