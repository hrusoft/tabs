import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { electronApp, optimizer } from '@electron-toolkit/utils'
import { app, BrowserWindow, clipboard, ipcMain } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { registerBellIpc } from './bell'
import { confirmClosingPanes, confirmQuitSync } from './closeDialogs'
import { registerContentModules, runContentModuleQuitHooks } from './contentTypes'
import { registerE2eHooks } from './e2e'
import { e2eHidden } from './e2eHidden'
import { registerExternalControlServer } from './externalControl'
import { registerFontsIpc } from './fonts'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import { registerLayoutIpc } from './layout'
import { applyMenu } from './menu'
import { openExternalUrl } from './openExternal'
import { flushSettingsWrite, registerSettingsIpc, subscribeSettings } from './settings'
import { registerShortcutsIpc } from './shortcuts'
import { registerSkillsIpc } from './skills'
import { installNativeTheme } from './theme'
import { createWindow, getMainWindow, openSettingsWindow } from './windows'

/**
 * App lifecycle: what gets registered, in what order, and what happens on the
 * way out. The windows themselves live in windows.ts and the application menu
 * in menu.ts — both are constructions with no opinion about when they run.
 * The six window/pane IPC handlers below are the one exception to
 * "registration calls only": each is a couple of lines with no module of its
 * own to belong to, and inlining them here was judged clearer than minting a
 * registerWindowIpc for six one-liners.
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

    // e2e only: an accessory-policy app can show windows without becoming the
    // frontmost app, so launching/closing it across many tests doesn't steal
    // focus or flash the Dock/Cmd-Tab switcher.
    if (e2eHidden && process.platform === 'darwin') {
      app.dock?.hide()
    }

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
    registerLayoutIpc()
    registerBellIpc()
    registerFontsIpc()
    registerSkillsIpc()
    // Every content type's IPC and core-registry entries, in one call (see
    // contentTypes.ts). After registerSettingsIpc above, so a module may read
    // the loaded settings — the terminal's registration used to sit *before* it
    // and simply never needed them.
    registerContentModules()
    registerExternalControlServer()
    // Resolved per-caller rather than closed over a single mainWindow, since
    // createWindow() (and so this handler's window) can run again after
    // every window closes on macOS (see the 'activate' handler below).
    ipcMain.handle(
      IpcChannel.windowIsFullScreen,
      (event) => BrowserWindow.fromWebContents(event.sender)?.isFullScreen() ?? false
    )
    onRendererMessage(IpcChannel.windowOpenSettings, () => openSettingsWindow())
    // Clicking a link in a terminal pane (see src/plugins/terminal/renderer/links.ts). Only
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
    // The About window's copy-address buttons. Main-side because
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
    createWindow()

    // e2e only: lets a spec file reuse one app across its tests instead of
    // relaunching for every one. Never installed in a normal run.
    if (e2eHidden) registerE2eHooks(getMainWindow)

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow()
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
  flushSettingsWrite()
  // Then each content type's own quit work, in list order — the terminal's
  // refreshes every live pty's cwd into the layout and kills them all. Still
  // strictly synchronous and after the settings flush: core's own persistence
  // must not be able to be skipped by a module, and runContentModuleQuitHooks
  // catches per module so one type's failure cannot skip another's teardown.
  runContentModuleQuitHooks()
})
