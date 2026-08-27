import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test as base, expect } from '@playwright/test'
import { type ElectronApplication, _electron as electron, type Page } from 'playwright'

const projectRoot = path.resolve(import.meta.dirname, '..', '..')

/** One app `launchApp` started, and the user-data dir it was pointed at. */
interface LaunchedApp {
  app: ElectronApplication
  userDataDir: string
  /** Set once the app exits, however that happened. */
  exited: boolean
}

/**
 * Every app this module has launched that hasn't had its directory released
 * yet — the registry behind the `userDataDir` fixture's guarantee that it
 * never deletes a directory a live app is still writing to.
 *
 * Module scope is safe because a Playwright worker runs one test at a time,
 * and entries are dropped when their directory is released, so this can't
 * grow across a spec file.
 */
const launched: LaunchedApp[] = []

/**
 * How long a close may take before the app is killed outright. An app wedged
 * on something Playwright can't see (a native modal, say) must not hang the
 * worker until the test timeout — cleanup that can block is worse than
 * cleanup that's blunt.
 */
const CLOSE_TIMEOUT_MS = 5_000

/**
 * True once the app has exited, however that happened — an explicit
 * `close()`, a quit driven from a test, or a crash.
 *
 * The shared-app fixture reads this so a test that quit the app out from under
 * it makes the *next* test relaunch rather than try to reset a dead app, which
 * would fail that innocent test instead of the one that closed it. Deliberately
 * not a try/catch around the reset: a reset that throws for any other reason is
 * a real failure and should surface.
 */
function hasExited(app: ElectronApplication): boolean {
  return launched.find((record) => record.app === app)?.exited ?? true
}

/** Closes an app, falling back to SIGKILL if it won't go quietly. */
async function closeApp(app: ElectronApplication): Promise<void> {
  if (hasExited(app)) return
  // Read the pid before closing and defensively: `process()` throws once
  // Playwright has torn the app down ("Cannot read properties of undefined"),
  // and the app can exit between the check above and this line.
  let pid: number | undefined
  try {
    pid = app.process().pid
  } catch {
    return
  }
  const closed = app
    .close()
    .then(() => 'closed' as const)
    .catch(() => 'closed' as const)
  const timedOut = new Promise<'timeout'>((resolve) => {
    setTimeout(() => resolve('timeout'), CLOSE_TIMEOUT_MS)
  })
  if ((await Promise.race([closed, timedOut])) === 'timeout' && pid !== undefined) {
    try {
      process.kill(pid, 'SIGKILL')
    } catch {
      // Raced with its own exit — nothing left to kill.
    }
  }
}

/**
 * Closes every app still running against `dir`, then deletes it.
 *
 * The order is the whole point. A test that launches its own app closes it as
 * its last statement, so any assertion failure or timeout before that skips
 * the close entirely — and Playwright does not clean up an Electron app
 * launched by hand the way it would a fixture. Deleting the directory first
 * left a live orphan whose renderer kept flushing its debounced `layout:set`
 * into a path that no longer existed, and (before the writers were guarded)
 * that surfaced as a native error dialog naming a temp directory belonging to
 * no test at all, held open for the rest of the run.
 */
async function releaseUserDataDir(dir: string): Promise<void> {
  for (const record of launched) {
    if (record.userDataDir === dir) await closeApp(record.app)
  }
  for (let i = launched.length - 1; i >= 0; i--) {
    if (launched[i]!.userDataDir === dir) launched.splice(i, 1)
  }
  rmSync(dir, { recursive: true, force: true })
}

/**
 * Launches the built app (run `npm run build` first; `npm run test:e2e`
 * does) against an isolated `--user-data-dir` — Electron honors this
 * Chromium switch for `app.getPath('userData')` with no app-side code
 * needed, so settings.json (and any future on-disk state) never touches the
 * real dev machine's app data or leaks between tests. Passing the project
 * root makes Electron resolve package.json "main" → out/main/index.js and
 * keeps app.getAppPath() correct.
 *
 * Launch your own app (via `withApp` below) only in a test that is *about*
 * launching — any test that quits or relaunches, paired with the
 * `userDataDir` fixture. Everything else should take the `electronApp`/`page`
 * fixtures below and share one app per spec file.
 *
 * E2E_HIDDEN=1 tells src/main/windows.ts to never show() the window at all
 * (see the comments there) so no launch ever flashes a window or steals
 * focus. Playwright drives the page over CDP regardless, so this doesn't
 * affect what's testable. It also gates the reset hook `resetApp` needs.
 *
 * Every launch is registered here (see `launched`), so an app still running
 * when its `userDataDir` fixture tears down gets closed rather than having
 * its user-data directory deleted from under it.
 */
async function launchApp(userDataDir: string): Promise<ElectronApplication> {
  const app = await electron.launch({
    args: [projectRoot, `--user-data-dir=${userDataDir}`],
    env: { ...process.env, E2E_HIDDEN: '1' }
  })
  const record: LaunchedApp = { app, userDataDir, exited: false }
  launched.push(record)
  app.on('close', () => {
    record.exited = true
  })
  return app
}

/**
 * One self-launched app for the span of `run`, closed in a `finally` — so an
 * assertion failure or timeout inside the body can't leave the app running
 * for the dir-teardown backstop to reap. The close is awaited either way,
 * which for the relaunch tests *is* the quit under test: return whatever the
 * next phase needs and assert it outside. Two-instance tests nest one
 * `withApp` inside another.
 */
export async function withApp<T>(
  userDataDir: string,
  run: (app: ElectronApplication, page: Page) => Promise<T>
): Promise<T> {
  const app = await launchApp(userDataDir)
  try {
    const page = await app.firstWindow()
    return await run(app, page)
  } finally {
    await app.close()
  }
}

/** The shared app of one spec file, together with the dir it owns. */
interface RunningApp {
  app: ElectronApplication
  userDataDir: string
  specFile: string
}

function freshUserDataDir(): string {
  return mkdtempSync(path.join(tmpdir(), 'tabs-e2e-'))
}

async function startApp(specFile: string): Promise<RunningApp> {
  const userDataDir = freshUserDataDir()
  return { app: await launchApp(userDataDir), userDataDir, specFile }
}

/** Ends a shared app and cleans up after it. */
async function stopApp(running: RunningApp): Promise<void> {
  await releaseUserDataDir(running.userDataDir)
}

/**
 * Returns a reused app to the state a freshly launched one would be in, by
 * driving the main process's own reset hook (src/main/e2e.ts): ptys killed,
 * extra windows gone, layout/settings back to defaults, renderer reloaded.
 * `evaluate` runs in the main process, which is the only place that global
 * exists — it is deliberately not IPC, so nothing test-only reaches preload.
 */
async function resetApp(running: RunningApp): Promise<void> {
  await running.app.evaluate(() => globalThis.__tabsE2e?.reset())
  // Playwright learns a window closed from its own CDP events, so its
  // windows() list can still include the just-destroyed Settings window for
  // a moment. Settle it here rather than in each test that counts windows.
  await expect.poll(() => running.app.windows().length).toBe(1)
}

/**
 * One app per spec file, reset between tests, rather than a launch + quit
 * per Electron test (~550ms of pure overhead each). Held on the worker so
 * it outlives a single test; relaunched from scratch whenever the worker
 * moves on to a different spec file, which keeps a leak that slips through
 * `resetApp` contained to (and bisectable within) the file that caused it.
 *
 * Spec files are the unit of parallelism — playwright.config.ts runs several
 * workers but deliberately does not set `fullyParallel`, since splitting one
 * file's tests across workers would mean each of them launching its own app
 * for that file and undo most of the saving.
 *
 * Tests that open a terminal should still close it before finishing: the
 * reset kills stray ptys, but a live one at *quit* is what trips the
 * before-quit foreground check (the full why lives on openTerminal in
 * helpers/terminal.ts), and quit still happens at the end of every file.
 */
export const test = base.extend<
  { electronApp: ElectronApplication; userDataDir: string },
  { sharedApp: { current?: RunningApp | undefined } }
>({
  sharedApp: [
    // biome-ignore lint/correctness/noEmptyPattern: Playwright's fixture API requires the destructuring slot
    async ({}, use) => {
      const holder: { current?: RunningApp | undefined } = {}
      await use(holder)
      if (holder.current) await stopApp(holder.current)
    },
    { scope: 'worker' }
  ],
  // A fresh, unused dir for the quit-and-relaunch tests that call launchApp
  // themselves. Kept separate from the shared app's own dir on purpose: those
  // tests need a directory no other running app is writing to. Teardown closes
  // any app still running against it before deleting it — see
  // releaseUserDataDir for why that order matters.
  // biome-ignore lint/correctness/noEmptyPattern: Playwright's fixture API requires the destructuring slot
  userDataDir: async ({}, use) => {
    const dir = freshUserDataDir()
    await use(dir)
    await releaseUserDataDir(dir)
  },
  electronApp: async ({ sharedApp }, use, testInfo) => {
    const stale =
      sharedApp.current &&
      (sharedApp.current.specFile !== testInfo.file || hasExited(sharedApp.current.app))
    if (sharedApp.current && stale) {
      await stopApp(sharedApp.current)
      sharedApp.current = undefined
    }
    if (sharedApp.current) {
      await resetApp(sharedApp.current)
    } else {
      sharedApp.current = await startApp(testInfo.file)
    }
    await use(sharedApp.current.app)
  },
  page: async ({ electronApp }, use) => {
    const page = await electronApp.firstWindow()
    await use(page)
  }
})

export { expect } from '@playwright/test'
