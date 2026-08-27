import type { BrowserWindow } from 'electron'
import { resetContentModulesForTests } from './contentTypes'
import { unhandledMainControlVerbs } from './controlVerbs'
import { resetExternalControlForTests } from './externalControl'
import { resetLayoutForTests, setLayoutResetting } from './layout'
import { forEachLiveWindow } from './liveWindows'
import { resetPaneHostsForTests } from './paneHostRegistry'
import { resetSettingsForTests } from './settings'
import { resetShortcutsForTests } from './shortcuts'
import { resetThemeForTests } from './theme'

/**
 * The reset entry point e2e/helpers/launch.ts drives, so one app can be
 * reused across every test in a spec file instead of relaunching once per
 * Electron test (launch + close is ~550ms of pure overhead each).
 *
 * Deliberately hung off `globalThis` rather than exposed over IPC: Playwright's
 * `electronApp.evaluate()` runs in the main process and can reach a global,
 * but an IPC channel would mean a matching preload method — real, shippable
 * API surface existing only for tests. This is installed only under
 * E2E_HIDDEN (see index.ts), so a normal run never defines it at all.
 */
interface E2eHooks {
  reset: () => Promise<void>
  /**
   * Protocol verbs no content module claimed — the runtime half of main's
   * verb-coverage guarantee, which the compiler cannot see. Each type's table
   * is exhaustive over its own union at build time (see controlVerbs.ts), but
   * a complete table whose registration never runs — a module dropped from
   * contentTypes.ts, a call moved out of `register()` — builds clean and
   * breaks only when someone drives that verb over the socket.
   *
   * A query rather than a mutation, unlike `reset` above, but here for the
   * same reason: reaching a main-process global from `electronApp.evaluate()`
   * costs no shippable API surface, whereas an IPC channel would need a
   * matching preload method existing only for tests.
   */
  unhandledControlVerbs: () => string[]
}

declare global {
  // `var` rather than let/const: only a `var` declaration actually augments
  // the `globalThis` type, which is what lets e2e/helpers/launch.ts reach
  // this from inside an `electronApp.evaluate()` callback.
  var __tabsE2e: E2eHooks | undefined
}

/**
 * Returns everything to the state a freshly launched app would be in:
 * every pty killed, every window but the main one gone, and layout/settings
 * back to their defaults both in memory and on disk. The renderer is then
 * reloaded so its stores re-read that pristine state through the same
 * synchronous IPC they use at boot (see layoutStore.ts/settingsStore.ts).
 *
 * Order matters. `setLayoutResetting` goes first and is only cleared once the
 * reload has finished, because the reload fires the outgoing renderer's
 * `beforeunload` layout flush — see the `resetting` comment in layout.ts.
 * The state resets come before the reload rather than after, since the
 * renderer reads its initial layout *during* load, not once it's done.
 */
async function reset(mainWindow: BrowserWindow | null): Promise<void> {
  setLayoutResetting(true)
  try {
    // Every content type's mutable main-process state, in one call (see
    // contentTypes.ts) — the terminal's ptys, the browser's guest/network maps.
    //
    // ORDER MATTERS, and in a direction that is easy to undo by accident:
    // this must stay AHEAD of the window destruction below. Killing a pty
    // fires node-pty's exit callback, which reaches for the pane's
    // webContents; doing that against windows already being torn down is the
    // shape of the shutdown crash CLAUDE.md documents (node-addon-api has no
    // safe JS context to rethrow into). The callbacks are defensive — an
    // isDestroyed() guard inside a try/catch — but that is the backstop, not
    // the reason this is safe. Everything here must also stay ahead of the
    // renderer reload further down, since the browser's maps are keyed by
    // webContents ids the reload invalidates.
    resetContentModulesForTests()
    // destroy() rather than close(): it can't be blocked by a beforeunload
    // handler, and it still fires 'closed' so windows.ts's settingsWindow
    // singleton drops its reference and will build a fresh one next time.
    forEachLiveWindow((window) => {
      if (window !== mainWindow) window.destroy()
    })
    resetSettingsForTests()
    resetLayoutForTests()
    // nativeTheme.themeSource is process-wide and survives a renderer reload,
    // so a test that switched to light would otherwise leave every later test
    // in the file running against light native chrome.
    resetThemeForTests()
    // After the settings reset, not before: this releases capture mode (which
    // a test could have left armed) and rebuilds the application menu, which
    // has to happen once the rebound accelerators it reads are back at their
    // defaults.
    resetShortcutsForTests()
    // Anything holding mutable main-process state keyed by a pane id has to
    // be reset here too, or it silently leaks into the next test — the
    // external-control ownership map outlives the panes it names. A content
    // type's own such state needs nothing added here: it declares a
    // `resetForTests` on its MainPluginModule and the call above picks it up,
    // which is how the "remember to add your reset" trap got closed by
    // construction rather than by this comment.
    resetExternalControlForTests()
    resetPaneHostsForTests()

    if (!mainWindow || mainWindow.isDestroyed()) return
    const reloaded = new Promise<void>((resolve) => {
      mainWindow.webContents.once('did-finish-load', () => resolve())
    })
    mainWindow.webContents.reload()
    await reloaded
  } finally {
    setLayoutResetting(false)
  }
}

/**
 * Installs the hooks above. `getMainWindow` is a getter rather than a window,
 * since macOS can close every window and build a new one on 'activate' (see
 * index.ts) — the window this resolves to must be whichever one is current.
 */
export function registerE2eHooks(getMainWindow: () => BrowserWindow | null): void {
  globalThis.__tabsE2e = {
    reset: () => reset(getMainWindow()),
    unhandledControlVerbs: () => unhandledMainControlVerbs()
  }
}
