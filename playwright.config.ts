import { createHash } from 'node:crypto'
import { defineConfig } from '@playwright/test'

/**
 * The harness dev server's port, derived from this checkout's absolute path.
 *
 * It used to be a hardcoded 5199, which made it a machine-global. Two runs
 * started from different checkouts (worktrees, a second clone) collided on it:
 * the first to start bound the port, and because `reuseExistingServer` is on,
 * every later run found the URL responding, started no server of its own, and
 * ran its whole `browser` project against the *first* checkout's renderer
 * bundle — reporting on code that wasn't under test, silently. Then the run
 * that owned the server killed it on exit (Playwright only tears down a server
 * it started itself) and every remaining browser test in the other runs died
 * on ECONNREFUSED, far from anything they were testing.
 *
 * Per-checkout rather than per-run (an ephemeral port) on purpose: a responder
 * on this port is by construction serving *this* checkout, so
 * `reuseExistingServer` stays safe and correct, and a single local run behaves
 * exactly as it did before — same one server, same startup cost, only the
 * number differs. Accepted residual: two runs from the SAME checkout still
 * share one server. That's harmless for correctness (identical code) but the
 * run that started it still kills it on exit, so the other run's remaining
 * browser tests fail on connection refused — run concurrent suites from
 * separate worktrees.
 */
function harnessPortFor(checkoutPath: string): number {
  const digest = createHash('sha1').update(checkoutPath).digest()
  return 5200 + (digest.readUInt16BE(0) % 200)
}

const harnessPort = harnessPortFor(import.meta.dirname)
const harnessOrigin = `http://127.0.0.1:${harnessPort}`

export default defineConfig({
  // Tuned for a fast single run on an otherwise idle machine. Several suite
  // runs at once (each with several Electron instances) can exhaust memory and
  // get one of them SIGKILLed mid-flight — pass `--workers=2` for those, seen
  // to complete cleanly where 4 did not, rather than lowering this and making
  // every normal run pay for the rare case.
  workers: 4,
  // Headroom over the per-step waits inside a test (helpers/terminal.ts's
  // prompt wait is the longest, and one test can open several terminals)
  // rather than a target: a healthy test finishes in a couple of seconds and
  // never approaches this.
  timeout: 60_000,
  reporter: [['list']],
  // macOS crash/persistence dialog suppression — an Electron-only concern,
  // harmless to run for the browser project too.
  globalSetup: './e2e/helpers/global-setup',
  projects: [
    {
      // Real-Electron integration tests: real IPC, ptys, webviews, windows.
      // Spec files run in parallel, each worker owning one whole file at a
      // time and reusing a single app across its tests (see helpers/launch.ts).
      // `fullyParallel` is deliberately left off: spreading one file's tests
      // over several workers would make each of them launch its own app for
      // that file and undo most of the saving that reuse buys.
      name: 'electron',
      testDir: './e2e',
      testIgnore: 'browser/**'
    },
    {
      // The renderer in plain Chromium against the vite-served harness
      // (src/renderer/harness.html) with the fake window.api bridge — for
      // geometry/drag/resize tests that need a real layout engine but nothing
      // from Electron. A browser context is milliseconds to create, so here
      // every test gets a fresh page and fullyParallel is worth it.
      name: 'browser',
      testDir: './e2e/browser',
      fullyParallel: true,
      use: { browserName: 'chromium', baseURL: harnessOrigin }
    }
  ],
  webServer: {
    // The port is passed on the command line rather than living in
    // vite.harness.config.ts: it's derived from this checkout's path (see
    // harnessPort above) and only this config knows it. A CLI --port overrides
    // whatever the vite config says, and --strictPort makes a collision an
    // immediate hard failure instead of vite quietly serving on port+1, which
    // would leave webServer.url pointing at nothing.
    command: `npx vite --config vite.harness.config.ts --port ${harnessPort} --strictPort`,
    url: `${harnessOrigin}/harness.html`,
    reuseExistingServer: true
  }
})
