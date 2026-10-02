import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { electronApp, optimizer } from '@electron-toolkit/utils'
import { e2eHidden } from '@tabs/plugin-sdk/main/e2eHidden'
import { app, BrowserWindow, clipboard, ipcMain } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { registerBellIpc } from './bell'
import { registerCaffeinateIpc } from './caffeinate'
import { killCaffeinateSync } from './caffeinateProcess'
import { confirmClosingPanes, confirmQuitSync } from './closeDialogs'
import {
  registerContentModules,
  runContentModuleQuitHooks,
  runContentModuleWindowDiscardHooks
} from './contentTypes'
import { registerE2eHooks } from './e2e'
import { registerExternalControlServer } from './externalControl'
import { registerFontsIpc } from './fonts'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { paneIdsOfWindow, registerLayoutIpc, windowHoldingPane } from './layout'
import { registerLayoutCrossWindowIpc } from './layoutCrossWindow'
import { applyMenu } from './menu'
import { openExternalUrl } from './openExternal'
import { openPaneTreeWindows } from './restoreWindows'
import { flushSettingsWrite, registerSettingsIpc, subscribeSettings } from './settings'
import { registerShortcutsIpc } from './shortcuts'
import { registerSkillsIpc } from './skills'
import { installNativeTheme } from './theme'
import { currentWindowCornerRadius } from './windowChrome'
import {
  getPaneTreeWindows,
  guardPaneTreeWindowClose,
  livePaneTreeWindow,
  livePaneTreeWindows,
  markQuitting,
  onPaneTreeWindowClosed,
  openSettingsWindow,
  windowIdForWebContents
} from './windows'

/**
 * App lifecycle: what gets registered, in what order, and what happens on the
 * way out. The windows themselves live in windows.ts and the application menu
 * in menu.ts — both are constructions with no opinion about when they run.
 * The seven window/pane IPC handlers below are the one exception to
 * "registration calls only": each is a couple of lines with no module of its
 * own to belong to, and inlining them here was judged clearer than minting a
 * registerWindowIpc for seven one-liners.
 */

// Give unpackaged dev/preview runs a userData directory that can never
// collide with the packaged app's default, even on a case-insensitive
// filesystem (macOS's default APFS format resolves "Tabs" and "tabs" to
// the same directory — dev and prod were silently sharing settings.json/
// layout.json). Skipped when --user-data-dir is already on the command
// line, since e2e (e2e/helpers/launch.ts) passes that for a fresh
// per-test tmpdir and it must keep winning over this default. Must run
// before whenReady() resolves — app.setPath() only works pre-ready — and
// before registerSettingsIpc()/registerLayoutIpc() below, which are what
// first actually read app.getPath('userData').
if (!app.isPackaged && !app.commandLine.hasSwitch('user-data-dir')) {
  const devUserDataPath = join(app.getPath('appData'), 'Tabs-dev')
  // setPath() throws if the directory doesn't exist yet; recursive:true
  // is also a harmless no-op on every later launch once it already exists.
  mkdirSync(devUserDataPath, { recursive: true })
  app.setPath('userData', devUserDataPath)
}

app
  .whenReady()
  .then(() => {
    electronApp.setAppUserModelId('com.hrusoft.tabs')

    // Never switch the activation policy here, least of all under e2e: macOS 27
    // force-quits a never-shown app ~30s after it leaves the Dock. e2e keeps
    // the Dock clear by launching a UIElement clone instead (CLAUDE.md).

    app.on('browser-window-created', (_, window) => {
      optimizer.watchWindowShortcuts(window)
    })

    registerSettingsIpc()
    // After registerSettingsIpc (it reads the loaded settings) and before
    // createWindow below (which reads themeWindowBackground).
    installNativeTheme()
    // Strictly after registerSettingsIpc: the menu reads each customizable
    // accelerator out of the live settings, which don't exist until that call
    // has loaded them. Rebuilt again whenever a rebind lands, and whenever the
    // Settings window arms/disarms capture; rebuilds ride menu.ts's applyMenu.
    registerShortcutsIpc()
    subscribeSettings((partial) => {
      if (partial.shortcuts) applyMenu()
    })
    applyMenu()
    registerLayoutIpc({
      resolveWindowId: windowIdForWebContents,
      onWindowClosed: onPaneTreeWindowClosed,
      liveWindowIds: () => getPaneTreeWindows().keys(),
      onWindowsDiscarded: runContentModuleWindowDiscardHooks
    })
    // A window closing while another stays open ends every pane it holds, so
    // it asks first the way closing one pane does.
    guardPaneTreeWindowClose((windowId, win) =>
      confirmClosingPanes(paneIdsOfWindow(windowId), win.webContents)
    )
    registerLayoutCrossWindowIpc()
    registerBellIpc()
    registerFontsIpc()
    registerSkillsIpc()
    registerCaffeinateIpc()
    // Every content type's IPC and core-registry entries, in one call (see
    // contentTypes.ts). After registerSettingsIpc above, so a module may read
    // the loaded settings — the terminal's registration used to sit *before* it
    // and simply never needed them.
    registerContentModules()
    registerExternalControlServer({
      rendererHolding: (paneId) => {
        const windowId = windowHoldingPane(paneId)
        return windowId === undefined ? undefined : livePaneTreeWindow(windowId)?.webContents
      },
      allRenderers: () => livePaneTreeWindows().map((win) => win.webContents)
    })
    // Resolved per-caller rather than closed over a single mainWindow, since
    // createWindow() (and so this handler's window) can run again after
    // every window closes on macOS (see the 'activate' handler below).
    ipcMain.handle(
      IpcChannel.windowIsFullScreen,
      (event) => BrowserWindow.fromWebContents(event.sender)?.isFullScreen() ?? false
    )
    onRendererMessage(IpcChannel.windowOpenSettings, () => openSettingsWindow())
    // Clicking a link in a terminal pane (see packages/plugin-terminal/renderer/links.ts). Only
    // the main process can reach the OS browser, and only it should be trusted
    // to vet the URL — openExternalUrl drops anything that isn't http(s)/mailto.
    onRendererMessage(IpcChannel.windowOpenExternal, (_event, url: string) => openExternalUrl(url))
    // The About window's identity block (see src/renderer/src/about/). Read
    // out of the live process every time rather than captured once, so the
    // numbers on screen are the running ones and no release step has to
    // remember to restate them anywhere.
    registerSyncGetter(IpcChannel.windowGetAppInfoSync, () => ({
      version: app.getVersion(),
      electron: process.versions.electron,
      chrome: process.versions.chrome,
      node: process.versions.node
    }))
    // Feeds --os-corner-radius (global.css) before the first frame, so the
    // active-pane outline never paints a sharp corner against the window's
    // OS-rounded one. See windowChrome.ts for why this is a table, not a query.
    registerSyncGetter(IpcChannel.windowGetCornerRadiusSync, () => currentWindowCornerRadius())
    // The app's own copy actions (the About window's copy-address buttons,
    // plugins' `copyText` — the git tree's Copy SHA-1). Main-side because
    // navigator.clipboard requires a focused document and no e2e window ever
    // genuinely is — see AppWindowApi.copyText in src/shared/api.ts.
    onRendererMessage(IpcChannel.windowCopyText, (_event, text: string) => {
      clipboard.writeText(text)
    })
    // Asked by the renderer before closing a pane/tab (and everything nested
    // in it — a tab group can hold several blocking panes at once): resolves
    // true straight away if nothing in `ids` currently blocks a close (e.g. a
    // terminal's foreground process — see closeBlockers.ts), or after the user
    // confirms a single dialog listing everything that does.
    ipcMain.handle(IpcChannel.paneConfirmClose, (event, ids: string[]) =>
      confirmClosingPanes(ids, event.sender)
    )
    openPaneTreeWindows()

    // e2e only: lets a spec file reuse one app across its tests instead of
    // relaunching for every one. Never installed in a normal run.
    if (e2eHidden) registerE2eHooks(getPaneTreeWindows)

    app.on('activate', () => {
      // Pane-tree windows only: an open Settings/About window must not keep
      // the main window from reopening.
      if (getPaneTreeWindows().size === 0) openPaneTreeWindows()
    })
    // A throw anywhere in the registration sequence above would otherwise be an
    // unhandled rejection — no window, no error, nothing to click. Logging is
    // all that's safe here (a dialog would violate the E2E_HIDDEN rule in
    // e2eHidden.ts); the individual registrations guard their own best-effort
    // work so this stays a backstop, not the plan.
  })
  .catch((error) => {
    console.error('[tabs] startup failed:', error)
  })

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

// If any content reports a close blocker (a terminal with a live foreground
// process — see closeBlockers.ts), ask first via a synchronous dialog, then
// refresh each terminal's persisted cwd and kill every pty so a quit never
// leaves orphaned shells. Everything here is deliberately
// synchronous, with no preventDefault + async work + re-quit() dance: the
// full story — why the async pattern hung shutdown, the accepted ~1-2%
// residual risk of the *next* launch hanging from spawning `lsof`/`ps` here
// at all, and the periodic-refresh alternative — lives in CLAUDE.md's
// before-quit gotcha. Stress-test repeated quit/relaunch cycles (see
// e2e/layout.spec.ts's relaunch tests) after touching this handler.
app.on('before-quit', (event) => {
  if (!confirmQuitSync()) {
    event.preventDefault()
    return
  }
  // From here every window close is shutdown, not the user closing a window
  // — see markQuitting.
  markQuitting()
  flushSettingsWrite()
  // Then each content type's own quit work, in list order — the terminal's
  // refreshes every live pty's cwd into the layout and kills them all. Still
  // strictly synchronous and after the settings flush: core's own persistence
  // must not be able to be skipped by a module, and runContentModuleQuitHooks
  // catches per module so one type's failure cannot skip another's teardown.
  runContentModuleQuitHooks()
  // A plain signal send on an already-spawned handle, not a fork — carries
  // none of the shutdown hazard above, which is specifically about forking
  // *new* processes from this handler. See caffeinateProcess.ts's own comment.
  killCaffeinateSync()
})
