import { execFileSync } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { CLONE_EXECUTABLE_ENV } from './helpers/electronClone'
import { expect, test } from './helpers/launch'

// The harness's contract with macOS itself, rather than anything the app does.
//
// macOS 27 force-quits a never-shown app about 30s after it switches out of the
// Dock, if background task management won't let it run in the background. The
// e2e app is never shown, so it must never make that switch. It stays out of
// the Dock by launching as a UI element from the start, from the LSUIElement
// clone of Electron.app that global setup makes (helpers/electronClone.ts).
// This test catches the two ways that breaks at runtime: the harness launching
// something other than the clone, and anything switching the running app into
// the Dock. The companion unit test, src/main/__tests__/activationPolicy.test.ts,
// catches a Dock hide being re-added, which is harmless on the clone but fatal
// on the stock binary. Full story in CLAUDE.md.

/**
 * How LaunchServices classifies a running pid: "Foreground" has a Dock tile,
 * "UIElement" doesn't. `lsappinfo info` only takes an ASN, not a pid, hence
 * the `find` first.
 */
function launchServicesType(pid: number): string | undefined {
  const asn = execFileSync('/usr/bin/lsappinfo', ['find', `pid=${pid}`], {
    encoding: 'utf8'
  }).trim()
  if (!asn) return undefined
  const info = execFileSync('/usr/bin/lsappinfo', ['info', '-only', 'ApplicationType', asn], {
    encoding: 'utf8'
  })
  return /type="([^"]+)"/.exec(info)?.[1]
}

test('the e2e app runs from the UI-element clone and never gets a Dock tile', async ({
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'LaunchServices and the Dock are macOS-only')
  // Launching has finished by the time a window exists, so LaunchServices
  // has classified the app.
  await electronApp.firstWindow()

  const cloneExecutable = process.env[CLONE_EXECUTABLE_ENV]
  expect(cloneExecutable, 'global setup exports the clone path').toBeTruthy()
  const running = await electronApp.evaluate(({ app }) => app.getPath('exe'))
  expect(realpathSync(running)).toBe(realpathSync(cloneExecutable ?? ''))

  const pid = electronApp.process().pid
  expect(pid).toBeDefined()
  expect(launchServicesType(pid ?? 0)).toBe('UIElement')
})
