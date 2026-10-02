import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, renameSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'

/**
 * The e2e app runs from a clone of Electron.app with `LSUIElement` set, so
 * LaunchServices treats it as a UI element (no Dock tile, no Cmd-Tab entry)
 * from its first instant. macOS only (global-setup.ts calls this only there).
 *
 * The obvious way to keep e2e apps out of the Dock is to call Electron's Dock
 * hide at startup, and that is exactly what can't be done. On macOS 27,
 * loginwindow treats an app switching *out of* the Dock as something to
 * police: if background task management says the app may not run in the
 * background, and the app has never shown a window (no e2e app ever does), it
 * is force-quit 30s later. An app that was a UI element from launch never
 * switches, so loginwindow never tracks it. Full story in CLAUDE.md.
 *
 * The clone is an APFS clone (`cp -c`), so it takes no disk space of its own
 * and is made in under a tenth of a second. Only its Info.plist differs from
 * the stock bundle, and the stock bundle's ad-hoc signature doesn't cover its
 * Info.plist, so no re-signing is needed. The bundle id stays
 * `com.github.Electron`, which is what global-setup.ts's
 * `ApplePersistenceIgnoreState` suppression is keyed to.
 *
 * It lives under node_modules/.cache, so it belongs to this checkout and goes
 * away with its node_modules. It is keyed by Electron's version: an upgrade
 * gets a fresh clone and the old one is deleted, rather than a bundle being
 * replaced under a run that might still be using it.
 */

const projectRoot = path.resolve(import.meta.dirname, '..', '..')
const cacheRoot = path.join(projectRoot, 'node_modules', '.cache', 'tabs-e2e')

/**
 * How global setup hands the clone's executable to every worker. Playwright
 * starts workers after global setup, with its environment.
 */
export const CLONE_EXECUTABLE_ENV = 'TABS_E2E_ELECTRON_EXECUTABLE'

function plistValue(plist: string, key: string): string | undefined {
  try {
    return execFileSync('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plist], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim()
  } catch {
    return undefined
  }
}

function infoPlist(bundle: string): string {
  return path.join(bundle, 'Contents', 'Info.plist')
}

/** A finished clone: in place, and marked as a UI element. */
function isUsableClone(bundle: string): boolean {
  return plistValue(infoPlist(bundle), 'LSUIElement') === 'true'
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/**
 * Electron's executable, downloading it first if this checkout hasn't yet.
 * The electron package has no install script: its binary arrives the first
 * time something resolves `require('electron')`, which is also how Playwright
 * finds it when no `executablePath` is given. In a fresh `npm ci` checkout
 * there is no Electron.app to clone until that happens.
 */
function stockExecutable(): string {
  try {
    return createRequire(path.join(projectRoot, 'package.json'))('electron') as string
  } catch (error) {
    // `npm ci` alone doesn't help here: it reinstalls the package, which
    // still has no binary until something downloads one.
    throw new Error(
      'e2e global setup could not get the Electron binary it clones for the e2e app ' +
        '(a fresh checkout downloads it on first use, which needs the network). ' +
        `Install it with \`npx install-electron --no\`, then rerun. Cause: ${String(error)}`
    )
  }
}

/** Deletes clones for other Electron versions and temp copies left by killed runs. */
function sweep(keepDir: string): void {
  let entries: string[]
  try {
    entries = readdirSync(cacheRoot)
  } catch {
    return
  }
  for (const entry of entries) {
    const dir = path.join(cacheRoot, entry)
    if (dir !== keepDir) {
      rmSync(dir, { recursive: true, force: true })
      continue
    }
    for (const inner of readdirSync(dir)) {
      const pid = /^Electron\.app\.tmp-(\d+)$/.exec(inner)?.[1]
      if (pid && !isAlive(Number(pid))) {
        rmSync(path.join(dir, inner), { recursive: true, force: true })
      }
    }
  }
}

/**
 * Makes (or reuses) the clone and returns the path of its executable. Throws,
 * with the reason, if it can't: running e2e on the stock bundle would mean
 * either Dock clutter or the force-quits, so there is no quiet fallback.
 *
 * Safe for two runs starting at once from the same checkout: each builds under
 * its own temp name and renames it into place, and whichever rename loses
 * just uses the winner's clone.
 */
export function ensureElectronClone(): string {
  const exe = stockExecutable()
  const stockBundle = path.resolve(exe, '..', '..', '..')
  if (path.extname(stockBundle) !== '.app') {
    throw new Error(`Expected Electron's executable inside an .app bundle, got ${exe}`)
  }
  const version = plistValue(infoPlist(stockBundle), 'CFBundleVersion')
  if (!version) throw new Error(`Could not read CFBundleVersion from ${infoPlist(stockBundle)}`)

  const dir = path.join(cacheRoot, `electron-${version}`)
  const clone = path.join(dir, path.basename(stockBundle))
  const cloneExe = path.join(clone, path.relative(stockBundle, exe))
  sweep(dir)
  if (isUsableClone(clone) && existsSync(cloneExe)) return cloneExe

  mkdirSync(dir, { recursive: true })
  const temp = `${clone}.tmp-${process.pid}`
  rmSync(temp, { recursive: true, force: true })
  try {
    execFileSync('/bin/cp', ['-Rc', stockBundle, temp], { stdio: ['ignore', 'ignore', 'pipe'] })
    execFileSync('/usr/bin/plutil', ['-replace', 'LSUIElement', '-bool', 'YES', infoPlist(temp)], {
      stdio: ['ignore', 'ignore', 'pipe']
    })
  } catch (error) {
    rmSync(temp, { recursive: true, force: true })
    const stderr = (error as { stderr?: Buffer }).stderr?.toString().trim()
    throw new Error(
      `e2e global setup could not make its UI-element clone of ${stockBundle} at ${clone}. ` +
        '`cp -c` needs an APFS volume. ' +
        `Cause: ${stderr || String(error)}`
    )
  }
  if (!isUsableClone(temp)) {
    rmSync(temp, { recursive: true, force: true })
    throw new Error(`The Electron clone at ${temp} did not take LSUIElement=true`)
  }
  try {
    renameSync(temp, clone)
  } catch {
    if (isUsableClone(clone)) {
      // Another run from this checkout got there first: use its clone.
      rmSync(temp, { recursive: true, force: true })
      return cloneExe
    }
    // Something at the final path that isn't a finished clone is a leftover.
    rmSync(clone, { recursive: true, force: true })
    renameSync(temp, clone)
  }
  return cloneExe
}
