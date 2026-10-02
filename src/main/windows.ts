import { join } from 'node:path'
import { is } from '@electron-toolkit/utils'
import { e2eHidden } from '@tabs/plugin-sdk/main/e2eHidden'
import { createId } from '@tabs/plugin-sdk/shared/model/ids'
import {
  BrowserWindow,
  type BrowserWindowConstructorOptions,
  screen,
  type WebContents,
  type WebPreferences
} from 'electron'
import icon from '../../resources/icon.png?asset'
import { IpcChannel } from '../shared/ipc'
import { contentModuleWindowPreferences, wireContentModulesInto } from './contentTypes'
import { openExternalUrl } from './openExternal'
import { themeWindowBackground } from './theme'

/**
 * The app's three kinds of window, and everything about constructing them:
 * the pane-tree windows, the Settings window and the About window.
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
 * A pane-tree window's stable identity, minted once on creation. Not
 * `BrowserWindow.id`: that is per process lifetime, and a persisted layout
 * must find "the same window" on the next boot.
 */
export type WindowId = string

/**
 * macOS only: hide the native title bar but keep the traffic lights, floating
 * them over the 30px of chrome the renderer draws itself — the main window's
 * docked root is always a tab group, and that group's own tab bar carries the
 * gutter (.tab-bar-root in global.css, see content/tabs/TabBar.tsx), while the
 * Settings and About windows draw a plain title bar (.window-titlebar in
 * styles/windowTitlebar.css) — all sized by --window-titlebar-height (30px)
 * in global.css.
 * Shared by all three windows rather than spelled out at each call site, so
 * none of them can drift into looking like a different app — `y` centers the
 * lights in that shared height, so changing the token means retuning this too.
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
    ? ({ titleBarStyle: 'hidden', trafficLightPosition: { x: 14, y: 9 } } as const)
    : {}

/** Every live pane-tree window by id. Insertion order is Map order, which e2e relies on to find the window its fixture launched (see e2e.ts). */
const paneTreeWindows = new Map<WindowId, BrowserWindow>()

/**
 * Every app window front to back, as far as main can tell: a window moves
 * to the front when it is created and whenever it gains focus, which on
 * macOS is the stacking order among one app's windows. Electron has no
 * "topmost window at this point", and creation order answers it backwards
 * for a cascade: the oldest window is the one underneath. Settings and
 * About are in it too — one over the cursor hides the pane-tree window
 * beneath it as surely as another pane-tree window would.
 */
const stack: BrowserWindow[] = []

function trackStacking(win: BrowserWindow): void {
  const toFront = (): void => {
    const at = stack.indexOf(win)
    if (at !== -1) stack.splice(at, 1)
    stack.unshift(win)
  }
  toFront()
  win.on('focus', toFront)
  win.on('closed', () => {
    const at = stack.indexOf(win)
    if (at !== -1) stack.splice(at, 1)
  })
}

/**
 * Listeners for a pane-tree window closing while the app keeps running (not
 * during a quit — see `markQuitting`), told how many remain. How layout.ts
 * hears about closes without this module knowing about persistence. The
 * window's renderer is already destroyed when they run.
 */
type CloseListener = (windowId: WindowId, remaining: number) => void

const closeListeners = new Set<CloseListener>()

export function onPaneTreeWindowClosed(listener: CloseListener): () => void {
  closeListeners.add(listener)
  return () => closeListeners.delete(listener)
}

/**
 * Set once `before-quit` has committed to quitting — never earlier, since a
 * cancelled quit must leave a later single close behaving normally. Without
 * it, every window closing as part of the quit would look like the user
 * closing it, and layout.ts would forget all but the last.
 */
let quitting = false

export function markQuitting(): void {
  quitting = true
}

/**
 * Asked before a pane-tree window closes — a close ends its panes (see
 * layout.ts) — and resolves whether it may. Injected so this module stays
 * ignorant of what a window holds; index.ts wires it to the same "you would
 * be ending live work" dialog a pane close asks. Unset, every close goes
 * ahead.
 */
let closeGuard: ((windowId: WindowId, win: BrowserWindow) => Promise<boolean>) | null = null

export function guardPaneTreeWindowClose(
  guard: (windowId: WindowId, win: BrowserWindow) => Promise<boolean>
): void {
  closeGuard = guard
}

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

/**
 * Loads a renderer entry point into `win` — the dev server in dev, the built
 * file otherwise. `query` is appended to the URL; the renderer never reads
 * it, but it gives each pane-tree window a distinct URL, which e2e matches
 * windows by.
 */
function loadRenderer(win: BrowserWindow, htmlFile: string, query?: Record<string, string>): void {
  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    const url = new URL(`${process.env.ELECTRON_RENDERER_URL}/${htmlFile}`)
    for (const [key, value] of Object.entries(query ?? {})) url.searchParams.set(key, value)
    win.loadURL(url.toString())
  } else {
    win.loadFile(
      join(import.meta.dirname, `../renderer/${htmlFile}`),
      query ? { query } : undefined
    )
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

/** Offset of a new pane-tree window from the one it cascades off — roughly AppKit's own. */
const CASCADE_OFFSET_PX = 24

/** A new pane-tree window's size. */
const PANE_TREE_WINDOW_SIZE = { width: 1200, height: 800 }

/**
 * Where a new pane-tree window goes when others exist: offset from the
 * focused one (else the most recent), wrapping to the work-area origin if
 * the new window — at its own size, not the anchor's — would leave the
 * display. Undefined for the first window, which takes Electron's default
 * (centered). Without this every window landed on the same spot and a
 * second one covered the first completely.
 */
function cascadePosition(): Pick<BrowserWindowConstructorOptions, 'x' | 'y'> | undefined {
  const focused = BrowserWindow.getFocusedWindow()
  const anchor =
    (focused && windowIdFor(focused) !== undefined ? focused : undefined) ??
    livePaneTreeWindows().at(-1)
  if (!anchor) return undefined
  const from = anchor.getBounds()
  const workArea = screen.getDisplayMatching(from).workArea
  const x = from.x + CASCADE_OFFSET_PX
  const y = from.y + CASCADE_OFFSET_PX
  const { width, height } = PANE_TREE_WINDOW_SIZE
  return {
    x: x + width > workArea.x + workArea.width ? workArea.x : x,
    y: y + height > workArea.y + workArea.height ? workArea.y : y
  }
}

/** Creates a pane-tree window under `windowId` — minted fresh unless recreating one whose layout was persisted. */
export function createWindow(windowId: WindowId = createId()): BrowserWindow {
  const mainWindow = new BrowserWindow({
    title: 'Tabs',
    ...PANE_TREE_WINDOW_SIZE,
    ...cascadePosition(),
    ...baseWindowOptions(contentModuleWindowPreferences())
  })

  showWhenReady(mainWindow)

  paneTreeWindows.set(windowId, mainWindow)
  trackStacking(mainWindow)
  // Closing a window ends its panes, the last one's included, so a close
  // asks first when that would end live work. The one exception is the last
  // window off macOS: closing it quits the app, and before-quit asks
  // instead — asking here as well would ask twice. Asking is asynchronous,
  // so the close is held and re-issued once the answer is yes.
  let closeConfirmed = false
  mainWindow.on('close', (event) => {
    if (quitting || closeConfirmed || !closeGuard) return
    if (process.platform !== 'darwin' && paneTreeWindows.size <= 1) return
    event.preventDefault()
    void closeGuard(windowId, mainWindow).then((proceed) => {
      if (!proceed || mainWindow.isDestroyed()) return
      closeConfirmed = true
      mainWindow.close()
    })
  })
  mainWindow.on('closed', () => {
    paneTreeWindows.delete(windowId)
    if (!quitting) {
      for (const listener of closeListeners) listener(windowId, paneTreeWindows.size)
    }
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

  loadRenderer(mainWindow, 'index.html', { windowId })

  return mainWindow
}

/** A singleton auxiliary window: opened on demand, focused if already open. */
interface AuxiliaryWindow {
  /** Shows and focuses the window, creating it if there isn't one yet. */
  open(): void
  /** Whether `win` is this window. */
  owns(win: BrowserWindow): boolean
}

/**
 * The shape the Settings and About windows share: a real, independent OS
 * window — no `parent`, so it can move to another Space and stay open beside
 * the main one — wearing the same `hiddenTitleBar` treatment as the main
 * window, so its chrome is the app's own (a `.window-titlebar`, see
 * styles/windowTitlebar.css) and side by side they read as one app. Each
 * instance holds its own singleton, dropped when the window closes.
 *
 * `open` needs no guard of its own: its callers — a menu click, a
 * synchronous ipcMain.on listener — already catch what escapes them (see
 * menu.ts's withGuardedClicks and ipcListeners.ts's onRendererMessage).
 */
function auxiliaryWindow(
  htmlFile: string,
  options: BrowserWindowConstructorOptions
): AuxiliaryWindow {
  let current: BrowserWindow | null = null
  return {
    open() {
      if (current) {
        if (!e2eHidden) {
          current.show()
          current.focus()
        }
        return
      }
      const win = new BrowserWindow({ ...options, ...baseWindowOptions() })
      trackStacking(win)
      showWhenReady(win)
      win.on('closed', () => {
        current = null
      })
      loadRenderer(win, htmlFile)
      current = win
    },
    owns: (win) => win === current
  }
}

/** Settings (settings.html / settings-main.tsx), behaving like a real Preferences window. */
const settingsWindow = auxiliaryWindow('settings.html', {
  title: 'Settings',
  width: 720,
  height: 560,
  minWidth: 600,
  minHeight: 440,
  maximizable: false,
  fullscreenable: false
})

/**
 * The app's identity, its attributions and its donation links (see
 * src/renderer/src/about/AboutWindow.tsx). It replaces what `role: 'appMenu'`'s
 * stock About item used to show — Electron's native panel, which can hold a
 * name, a version and an icon and nothing else: no links to open, no
 * per-amount buttons, no copyable addresses. Not resizable, because its
 * content is a fixed column of prose — everything past the fold scrolls
 * inside `.about-body` instead.
 */
const aboutWindow = auxiliaryWindow('about.html', {
  title: 'About Tabs',
  // Sized so the identity block and all three donation tiers land above the
  // fold; the credit list below them is reference material and scrolls.
  width: 460,
  height: 660,
  resizable: false,
  maximizable: false,
  fullscreenable: false
})

/** Opens the Settings window, creating it if needed, or focusing it if already open. */
export function openSettingsWindow(): void {
  settingsWindow.open()
}

/** Opens the About window, creating it if needed, or focusing it if already open. */
export function openAboutWindow(): void {
  aboutWindow.open()
}

/**
 * Whether `win` is one of the app's auxiliary windows — Settings or About —
 * rather than a pane-tree window. What the File menu's Close Pane item
 * branches on: neither hosts panes, so neither has a listener for the action
 * and for both the item can only mean "close this window" (see menu.ts).
 */
export function isAuxiliaryWindow(win: BrowserWindow): boolean {
  return settingsWindow.owns(win) || aboutWindow.owns(win)
}

/** Every live pane-tree window by id. A live view, not a snapshot: read it at the point of use, never across an await. */
export function getPaneTreeWindows(): ReadonlyMap<WindowId, BrowserWindow> {
  return paneTreeWindows
}

/** The pane-tree window `windowId` names, unless it has been destroyed. */
export function livePaneTreeWindow(windowId: WindowId): BrowserWindow | undefined {
  const win = paneTreeWindows.get(windowId)
  return win && !win.isDestroyed() ? win : undefined
}

/** Every pane-tree window not yet destroyed, oldest first. */
export function livePaneTreeWindows(): BrowserWindow[] {
  return [...paneTreeWindows.values()].filter((win) => !win.isDestroyed())
}

/** Every live app window, frontmost first, with its pane-tree id — undefined for Settings or About. See `stack`. */
export function windowsFrontToBack(): { win: BrowserWindow; windowId: WindowId | undefined }[] {
  return stack
    .filter((win) => !win.isDestroyed())
    .map((win) => ({ win, windowId: windowIdFor(win) }))
}

/** The id `win` was registered under, or undefined for an auxiliary or closed window. A linear scan; the registry holds a handful. */
function windowIdFor(win: BrowserWindow): WindowId | undefined {
  for (const [id, candidate] of paneTreeWindows) {
    if (candidate === win) return id
  }
  return undefined
}

/** The id of the pane-tree window owning `webContents`, or undefined for an auxiliary window or a `<webview>` guest. */
export function windowIdForWebContents(webContents: WebContents): WindowId | undefined {
  const win = BrowserWindow.fromWebContents(webContents)
  return win ? windowIdFor(win) : undefined
}
