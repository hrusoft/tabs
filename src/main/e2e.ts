import type { BrowserWindow, Point } from 'electron'
import type { CaffeinateFlags } from '../shared/api'
import type { Settings } from '../shared/settings'
import { startCaffeinate } from './caffeinate'
import { currentCaffeinatePid, resetCaffeinateForTests } from './caffeinateProcess'
import { resetContentModulesForTests } from './contentTypes'
import { unhandledMainControlVerbs } from './controlVerbs'
import { resetExternalControlForTests } from './externalControl'
import { resetLayoutForTests, setLayoutResetting } from './layout'
import {
  resetCrossWindowDragForTests,
  setCrossWindowCursorPointForTests
} from './layoutCrossWindow'
import { forEachLiveWindow } from './liveWindows'
import { resetPaneHostsForTests } from './paneHostRegistry'
import { mergeSettingsForTests, resetSettingsForTests } from './settings'
import { resetShortcutsForTests } from './shortcuts'
import { resetThemeForTests } from './theme'
import type { WindowId } from './windows'

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
   * a complete table whose registration never runs (see controlVerbs.ts)
   * builds clean and breaks only when someone drives that verb over the
   * socket.
   *
   * A query rather than a mutation, unlike `reset` above, but here for the
   * same reason: reaching a main-process global from `electronApp.evaluate()`
   * costs no shippable API surface, whereas an IPC channel would need a
   * matching preload method existing only for tests.
   */
  unhandledControlVerbs: () => string[]
  /**
   * A settings write as though another window made it (see
   * mergeSettingsForTests) — how a test states the settings its subject
   * depends on without driving the Settings window, whose UI is not the
   * subject of most tests that need one.
   */
  mergeSettings: (partial: Partial<Settings>) => void
  /**
   * The OS pid of the managed caffeinate process, or undefined if none is
   * running — how "quitting the app stops the process" is proven against
   * the *specific* process this app spawned rather than by process name
   * (`pgrep -f caffeinate` is a machine-global check: this Mac can easily
   * have an unrelated caffeinate already running, and CLAUDE.md's "several
   * checkouts at once" entry is exactly this class of bug). See
   * e2e/caffeinate.spec.ts.
   */
  caffeinatePid: () => number | undefined
  /**
   * Starts the managed caffeinate process directly, bypassing the renderer
   * and its IPC round trip — the same reasoning `mergeSettings` bypasses the
   * Settings window: most of e2e/caffeinate.spec.ts's tests are about Decaf,
   * the cup button, a timer, or quitting, not about re-proving the Start
   * button's IPC path a second time (its own test covers that once, through
   * the real dialog).
   */
  startCaffeinateForTests: (flags: CaffeinateFlags) => void
  /** Overrides the cursor point the cross-window drag poll reads (`null` restores the real one) — see layoutCrossWindow.ts. */
  setCrossWindowCursorPoint: (point: Point | null) => void
}

declare global {
  // `var` rather than let/const: only a `var` declaration actually augments
  // the `globalThis` type, which is what lets e2e/helpers/launch.ts reach
  // this from inside an `electronApp.evaluate()` callback.
  var __tabsE2e: E2eHooks | undefined
}

/**
 * Returns everything to the state a freshly launched app would be in:
 * every pty killed, every window but the first pane-tree one gone, and
 * layout/settings back to their defaults both in memory and on disk. The
 * renderer is then reloaded so its stores re-read that pristine state
 * through the same synchronous IPC they use at boot (see
 * layoutStore.ts/settingsStore.ts).
 *
 * `keepWindow` is the pane-tree window the fixture launched with; every
 * other window goes, auxiliary or a second pane-tree window a test opened
 * and forgot to close.
 *
 * Order matters. `setLayoutResetting` goes first and is only cleared once the
 * reload has finished, because the reload fires the outgoing renderer's
 * `beforeunload` layout flush — see the `resetting` comment in layout.ts.
 * The state resets come before the reload rather than after, since the
 * renderer reads its initial layout *during* load, not once it's done.
 */
async function reset(keepWindow: BrowserWindow | null): Promise<void> {
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
    // Same reasoning, same placement: a child process this reset kills fires
    // its own async exit callback, which must not run against windows already
    // torn down below (see caffeinateProcess.ts's killCaffeinateSync comment).
    resetCaffeinateForTests()
    // destroy() rather than close(): it can't be blocked by a beforeunload
    // handler, and it still fires 'closed' so windows.ts's auxiliary-window
    // singletons (and the pane-tree registry, for any extra window) drop
    // their reference and will build a fresh one next time.
    forEachLiveWindow((window) => {
      if (window !== keepWindow) window.destroy()
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
    // Before anything acts on a window id the destruction above invalidated.
    resetCrossWindowDragForTests()

    if (!keepWindow || keepWindow.isDestroyed()) return
    const reloaded = new Promise<void>((resolve) => {
      keepWindow.webContents.once('did-finish-load', () => resolve())
    })
    keepWindow.webContents.reload()
    await reloaded
  } finally {
    setLayoutResetting(false)
  }
}

/**
 * Installs the hooks above. Takes a getter, not a window: macOS can close
 * every window and build a new one on 'activate', so the first entry is
 * resolved at reset time.
 */
export function registerE2eHooks(
  getPaneTreeWindows: () => ReadonlyMap<WindowId, BrowserWindow>
): void {
  globalThis.__tabsE2e = {
    reset: () => reset(getPaneTreeWindows().values().next().value ?? null),
    unhandledControlVerbs: () => unhandledMainControlVerbs(),
    mergeSettings: (partial) => mergeSettingsForTests(partial),
    caffeinatePid: () => currentCaffeinatePid(),
    startCaffeinateForTests: (flags) => startCaffeinate(flags),
    setCrossWindowCursorPoint: (point) => setCrossWindowCursorPointForTests(point)
  }
}
