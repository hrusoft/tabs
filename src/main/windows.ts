import { join } from 'node:path'
import { is } from '@electron-toolkit/utils'
import { BrowserWindow, type BrowserWindowConstructorOptions, type WebPreferences } from 'electron'
import icon from '../../resources/icon.png?asset'
import { IpcChannel } from '../shared/ipc'
import { contentModuleWindowPreferences, wireContentModulesInto } from './contentTypes'
import { e2eHidden } from './e2eHidden'
import { openExternalUrl } from './openExternal'
import { themeWindowBackground } from './theme'

/**
 * The app's three windows, and everything about constructing them: the
 * pane-tree window, the Settings window and the About window.
 *
 * index.ts owns app lifecycle and registration order; this owns what a
 * window is. Nothing here knows when it is called, and nothing in index.ts
 * knows what a window looks like — with
 * one seam left deliberately: `openSettingsWindow`, `openAboutWindow` and
 * `isAuxiliaryWindow` are exported for the menu (see menu.ts), because those
 * two items each open a window and "Close Pane" has to know whether the
 * focused one hosts panes at all.
 */

/**
 * macOS only: hide the native title bar but keep the traffic lights, floating
 * them over the 28px of chrome the renderer draws itself — the main window's
 * docked root is always a tab group, and that group's own tab bar carries the
 * gutter (.tab-bar-root in global.css, see content/tabs/TabBar.tsx), while the
 * Settings window still draws a plain title bar (.settings-titlebar) — both
 * sized by --window-titlebar-height (28px) in global.css. Shared by both
 * windows rather than spelled out at each call site, so the two can never
 * drift into looking like different apps — `y` centers the lights in that
 * shared height, so changing the token means retuning this too.
 *
 * `y` is eyeballed against the real, rendered window: this value can't be
 * screenshotted or otherwise verified from here, since the traffic lights are
 * native window-frame chrome, not part of the page Playwright/CDP captures —
 * only a human looking at the actual title bar can tell it's centered.
 * Windows/Linux are out of scope for now (see README) and are left with
 * their default framed window.
 */
const hiddenTitleBar =
  process.platform === 'darwin'
    ? ({ titleBarStyle: 'hidden', trafficLightPosition: { x: 11, y: 8 } } as const)
    : {}

let settingsWindow: BrowserWindow | null = null
let aboutWindow: BrowserWindow | null = null

// Only read by the E2E_HIDDEN reset hook (see e2e.ts), which needs whichever
// main window is current — macOS can close them all and build a new one on
// 'activate' (see index.ts), so this can't be captured once at startup.
let mainWindowRef: BrowserWindow | null = null

/**
 * e2e only (E2E_HIDDEN): skip show()/showInactive() entirely and leave the
 * window in its constructor `show: false` state permanently — every window
 * must follow this discipline. Playwright drives webContents over CDP
 * directly (Input.dispatchMouseEvent etc.), which doesn't require the native
 * window to ever be ordered onto the screen — confirmed by running the full
 * e2e suite this way. Positioning the window off-screen instead (tried
 * first) did NOT work: AppKit's constrain-to-visible-screen behavior pulls
 * the window back on screen once Playwright's CDP session attaches and
 * orders it front, even with showInactive().
 */
function showWhenReady(win: BrowserWindow): void {
  if (e2eHidden) return
  win.on('ready-to-show', () => {
    win.show()
  })
}

/** Loads a renderer entry point into `win` — the dev server in dev, the built file otherwise. */
function loadRenderer(win: BrowserWindow, htmlFile: string): void {
  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(`${process.env.ELECTRON_RENDERER_URL}/${htmlFile}`)
  } else {
    win.loadFile(join(import.meta.dirname, `../renderer/${htmlFile}`))
  }
}

/**
 * The options every window in the app shares, layered under each window's own
 * title/size/behavior. `extraWebPreferences` is for what only the pane-tree
 * window needs — the registered content types' own requirements (the
 * browser's `webviewTag`, today; see MainPluginModule.windowPreferences) —
 * spread first, so core's own two settings below still decide how a window
 * loads its renderer regardless of what a content type asked for.
 */
function baseWindowOptions(
  extraWebPreferences: WebPreferences = {}
): Partial<BrowserWindowConstructorOptions> {
  return {
    show: false,
    autoHideMenuBar: true,
    // Painted before the renderer's first frame; without it the window flashes
    // Chromium's default white on launch. Theme-derived so it can't drift from
    // what the renderer paints a moment later — see main/theme.ts.
    backgroundColor: themeWindowBackground(),
    ...(process.platform === 'linux' ? { icon } : {}),
    ...hiddenTitleBar,
    // e2e only: never becomes key/activatable even on the off chance
    // something still tries to show it (belt-and-braces alongside never
    // calling show()/showInactive() below).
    ...(e2eHidden ? { focusable: false } : {}),
    webPreferences: {
      ...extraWebPreferences,
      preload: join(import.meta.dirname, '../preload/index.mjs'),
      sandbox: false
    }
  }
}

export function createWindow(): void {
  const mainWindow = new BrowserWindow({
    title: 'Tabs',
    width: 1200,
    height: 800,
    ...baseWindowOptions(contentModuleWindowPreferences())
  })

  showWhenReady(mainWindow)

  mainWindowRef = mainWindow
  mainWindow.on('closed', () => {
    if (mainWindowRef === mainWindow) mainWindowRef = null
  })

  // The renderer hides the window header entirely in fullscreen (like a
  // native title bar): it can't be observed from CSS or the DOM Fullscreen
  // API, since this is the native, traffic-light-triggered fullscreen, not
  // the HTML one — so the main process has to push it over IPC.
  mainWindow.on('enter-full-screen', () => {
    mainWindow.webContents.send(IpcChannel.windowFullScreenChanged, true)
  })
  mainWindow.on('leave-full-screen', () => {
    mainWindow.webContents.send(IpcChannel.windowFullScreenChanged, false)
  })

  mainWindow.webContents.setWindowOpenHandler((details) => {
    openExternalUrl(details.url)
    return { action: 'deny' }
  })

  // Per-type wiring for the pane-tree window — the browser's guest policy
  // today, including the hardening that goes with the `webviewTag` it asked
  // for above. Not applied to the Settings window, which hosts no panes.
  //
  // Before loadRenderer below, and it must be: a guest can attach as soon as
  // the renderer paints, and every one of these listeners has to already be
  // there when the first one does.
  wireContentModulesInto(mainWindow)

  loadRenderer(mainWindow, 'index.html')
}

/**
 * A real, independent OS window for Settings (see settings.html/
 * settings-main.tsx) — not a modal over the main window, and with no `parent`,
 * matching how a real Preferences window behaves: movable to another Space,
 * usable alongside the main window, closable on its own.
 *
 * It wears the same `hiddenTitleBar` treatment as the main window, so its
 * chrome is the app's own (SettingsWindow.tsx draws a .settings-titlebar,
 * the same role the main window's own root tab bar plays — see .tab-bar-root
 * in content/tabs/TabBar.tsx) rather than the OS default — side by side, the
 * two windows read as one app.
 */
function createSettingsWindow(): BrowserWindow {
  const win = new BrowserWindow({
    title: 'Settings',
    width: 720,
    height: 560,
    minWidth: 600,
    minHeight: 440,
    maximizable: false,
    fullscreenable: false,
    ...baseWindowOptions()
  })

  showWhenReady(win)

  win.on('closed', () => {
    settingsWindow = null
  })

  loadRenderer(win, 'settings.html')

  return win
}

/**
 * Shows and focuses `get()`'s window, creating it via `create()` and storing
 * it through `set()` if there isn't one yet. Guarded because every caller is
 * unguarded dispatch — a menu click, or a synchronous ipcMain.on listener —
 * where an escaping throw from window construction is the native error modal
 * persist.ts documents. A failed open degrades to "nothing happened".
 */
function openOrFocus(
  get: () => BrowserWindow | null,
  set: (win: BrowserWindow) => void,
  create: () => BrowserWindow,
  label: string
): void {
  try {
    const existing = get()
    if (existing) {
      if (!e2eHidden) {
        existing.show()
        existing.focus()
      }
      return
    }
    set(create())
  } catch (error) {
    console.error(`[tabs] could not open the ${label} window:`, error)
  }
}

/** Opens the Settings window, creating it if needed, or focusing it if already open. */
export function openSettingsWindow(): void {
  openOrFocus(
    () => settingsWindow,
    (win) => {
      settingsWindow = win
    },
    createSettingsWindow,
    'Settings'
  )
}

/**
 * A small, fixed-size window for the app's identity, its attributions and its
 * donation links (see src/renderer/src/about/AboutWindow.tsx). It replaces
 * what `role: 'appMenu'`'s stock About item used to show — Electron's native
 * panel, which can hold a name, a version and an icon and nothing else: no
 * links to open, no per-amount buttons, no copyable addresses.
 *
 * Built like the Settings window rather than like a dialog, and for the same
 * reasons: no `parent`, so it is a real window the user can move to another
 * Space and leave open, and the same `hiddenTitleBar` treatment so its chrome
 * is the app's own. Not resizable, because its content is a fixed column of
 * prose — everything past the fold scrolls inside `.about-body` instead.
 */
function createAboutWindow(): BrowserWindow {
  const win = new BrowserWindow({
    title: 'About Tabs',
    // Sized so the identity block and all three donation tiers land above the
    // fold; the credit list below them is reference material and scrolls.
    width: 460,
    height: 660,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    ...baseWindowOptions()
  })

  showWhenReady(win)

  win.on('closed', () => {
    aboutWindow = null
  })

  loadRenderer(win, 'about.html')

  return win
}

/** Opens the About window, creating it if needed, or focusing it if already open. */
export function openAboutWindow(): void {
  openOrFocus(
    () => aboutWindow,
    (win) => {
      aboutWindow = win
    },
    createAboutWindow,
    'About'
  )
}

/**
 * Whether `win` is one of the app's auxiliary windows — Settings or About —
 * rather than a pane-tree window. What the File menu's Close Pane item
 * branches on: neither hosts panes, so neither has a listener for the action
 * and for both the item can only mean "close this window" (see menu.ts).
 *
 * One predicate over the set rather than one per window, so the menu keeps a
 * single branch and a fourth window is an edit here instead of there.
 */
export function isAuxiliaryWindow(win: BrowserWindow): boolean {
  return win === settingsWindow || win === aboutWindow
}

/**
 * The current pane-tree window, or null when every window has been closed.
 * A getter rather than a value because macOS can close them all and build a
 * new one on 'activate' — see the comment on `mainWindowRef`.
 */
export function getMainWindow(): BrowserWindow | null {
  return mainWindowRef
}
