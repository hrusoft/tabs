import { platform } from '@tabs/plugin-sdk/main/platform'
import {
  resolveBinding,
  type ShortcutActionId,
  shortcutAction,
  toAccelerator
} from '@tabs/plugin-sdk/shared/shortcuts'
import { app, BrowserWindow, Menu, type MenuItemConstructorOptions } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { isCaffeinateRunning, stopCaffeinate } from './caffeinateProcess'
import { openNewWindow, openPaneTreeWindows } from './restoreWindows'
import { getSettings } from './settings'
import { isShortcutCaptureActive } from './shortcutCapture'
import {
  isAuxiliaryWindow,
  livePaneTreeWindows,
  openAboutWindow,
  openSettingsWindow
} from './windows'

/**
 * The native application menu: its template, and the accelerators it reads out
 * of the live settings.
 *
 * index.ts says only *when* the menu is (re)built — an ordering that is
 * load-bearing and documented there; this says what it contains. The capture flag
 * this reads lives in shortcutCapture.ts, its own one-value module, so
 * shortcuts.ts can import `applyMenu` from here without a cycle.
 */

/**
 * The accelerator for a rebindable action, or undefined when it must have
 * none: the user cleared it, the recorded key has no accelerator spelling, or
 * capture mode is currently suspending every customizable accelerator so the
 * Settings window can observe the keystroke instead (see main/shortcuts.ts).
 */
function acceleratorFor(id: ShortcutActionId): string | undefined {
  if (isShortcutCaptureActive()) return undefined
  const binding = resolveBinding(getSettings(), id)
  if (!binding) return undefined
  return toAccelerator(binding, platform) ?? undefined
}

/**
 * The accelerator as a spreadable fragment — an unbound action contributes no
 * `accelerator` key at all, which is what MenuItemConstructorOptions'
 * exact-optional typing asks for (Electron treats an explicit undefined the
 * same, so this is purely a type-level distinction).
 */
function acceleratorEntry(id: ShortcutActionId): { accelerator?: string } {
  const accelerator = acceleratorFor(id)
  return accelerator === undefined ? {} : { accelerator }
}

/**
 * A menu item that forwards `id` to the focused window's renderer, which runs
 * the same layoutStore action the pane header buttons do (see paneShortcuts.ts).
 *
 * The label comes from the shared action registry rather than a literal here,
 * so renaming an action is one edit: the Settings row and the File menu can't
 * disagree, and neither can the e2e helpers that look items up by label.
 */
function paneShortcutItem(id: ShortcutActionId): MenuItemConstructorOptions {
  return {
    label: shortcutAction(id).label,
    ...acceleratorEntry(id),
    click: (_item, window) => {
      if (window instanceof BrowserWindow) window.webContents.send(IpcChannel.shortcutAction, id)
    }
  }
}

/**
 * File → Caffeinate…/Decaf — macOS only (see buildMenu's File submenu; the
 * binary this answers doesn't exist elsewhere). The label is computed live
 * from `isCaffeinateRunning()` on every rebuild, which `applyMenu` runs
 * whenever the process starts, stops, or exits on its own (see
 * broadcastRunning in caffeinate.ts) — the same "rebuilt wholesale, no
 * in-place update" mechanism a rebind already relies on.
 *
 * The click handler answers itself rather than going through
 * `paneShortcutItem`, exactly like Close Pane above: running, it stops the
 * process directly in main (no renderer involved at all); not running, it
 * forwards `caffeinate:open-dialog` to a pane-tree window so the renderer
 * can open the dialog that collects the flags to start one.
 *
 * Which pane-tree window: the one the menu was used from (`window`), when it
 * is one. Otherwise — Settings or About focused, whose renderers mount no
 * `<App/>` and so have nothing to hear it, or nothing focused — the most
 * recently opened one. With none open at all (macOS keeps the app running
 * with no windows), it reopens what a reactivate would (see
 * restoreWindows.ts) — the last window closed, with its layout.
 *
 * If a fresh window had to be created, forwarding after `did-finish-load`
 * really is deterministic, not just "usually works": `installCaffeinate`'s
 * subscription is installed at module scope in main.tsx, before `<App/>`
 * ever renders (see its own comment for why that's the guarantee and a
 * `useEffect` inside `<App/>` wasn't — this menu's own commit history has a
 * real instance of that race, in e2e/caffeinate.spec.ts's first test). A
 * module's top-level code runs as part of the page's script execution, which
 * `did-finish-load` (Electron's `load` event) waits on; nothing here has to
 * hope React's effects won a scheduling race.
 */
function caffeinateMenuItem(): MenuItemConstructorOptions {
  return {
    label: isCaffeinateRunning() ? 'Decaf' : shortcutAction('caffeinate').label,
    ...acceleratorEntry('caffeinate'),
    click: (_item, window) => {
      if (isCaffeinateRunning()) {
        stopCaffeinate()
        return
      }
      const open = livePaneTreeWindows()
      const existing = open.find((win) => win === window) ?? open.at(-1)
      if (existing) {
        existing.webContents.send(IpcChannel.caffeinateOpenDialog)
        return
      }
      const created = openPaneTreeWindows().at(-1)
      if (!created) return
      created.webContents.once('did-finish-load', () => {
        created.webContents.send(IpcChannel.caffeinateOpenDialog)
      })
    }
  }
}

/**
 * Electron's auto-generated default menu binds Cmd/Ctrl+W to `role: 'close'`
 * (closes the whole window) and has no Cmd/Ctrl+T at all — both need a real
 * menu item to override, since a renderer-side `keydown` listener never sees
 * a key combo that a native menu accelerator already claims. The pane actions
 * are sent to the focused window's renderer on the single
 * `IpcChannel.shortcutAction` channel, carrying the action id — the HANDLERS
 * table in content/paneShortcuts.ts runs the same layoutStore calls the
 * header buttons make.
 *
 * The file and edit menus are spelled out for that reason; app/view/window are
 * still the stock role menus. Edit only needs replacing because Cmd/Ctrl+K has
 * to hang off a menu item too, and Clear Buffer belongs where Terminal.app and
 * iTerm2 put it — so the roles `role: 'editMenu'` would have generated are
 * listed by hand instead (macOS still folds Start Dictation and Emoji &
 * Symbols into any Edit menu itself).
 *
 * New Horizontal Split / New Vertical Split / New Unpinned Pane need real menu
 * items for the same reason New Tab does, not just to appear in the menu: a
 * `layer: 'renderer'` binding would stop working the instant a `<webview>`
 * pane has focus (a focused guest swallows every keydown before the host
 * window sees it — see packages/plugin-browser/main/guestNavKeys.ts), while a menu
 * accelerator fires regardless of which pane is focused. Each of these is
 * exactly as available from inside a browser pane as New Tab is, and giving
 * that up would be a regression.
 *
 * The macOS application menu is spelled out for a third instance of the same
 * pattern: `role: 'appMenu'` generates an About item wired to Electron's
 * native about panel, which can show a name, a version and an icon and
 * nothing else — no links, no donation buttons, no copyable addresses (see
 * `aboutWindow` in windows.ts). Only that one item changes; Services,
 * Hide, Hide Others, Show All and Quit stay stock roles, so this gives up
 * nothing the way the View menu did. Other platforms have no application
 * menu to put it in, so they get a Help menu holding the same item — that is
 * where both Windows and Linux conventionally look for it.
 *
 * View is spelled out for the same structural reason as Edit, and gives up
 * something real to get it: the stock `role: 'viewMenu'` template opens with
 * Reload and Force Reload, which own CommandOrControl+R/+Shift+R — the two
 * accelerators Refresh needed (content decides what refreshing means, same as
 * Clear Buffer; see the 'refresh-pane' entry in content/paneShortcuts.ts's
 * HANDLERS). Dropping the stock Reload items is a deliberate trade, not an
 * oversight — a knowingly accepted loss of the renderer-reload escape hatch
 * that role gives every Electron app, in exchange for a mnemonic Cmd/Ctrl+R
 * for an in-app action. The rest of the role's items (dev tools, zoom,
 * fullscreen) are kept verbatim.
 *
 * The accelerators here are user-rebindable (see shared/shortcuts.ts), so
 * this reads them from settings rather than hardcoding them, and must be
 * re-run whenever they change — `Menu.setApplicationMenu` replaces the menu
 * wholesale, there is no in-place accelerator update. An item whose binding
 * the user cleared keeps its place in the menu and stays clickable; it just
 * has no key equivalent. Every *other* accelerator in this template belongs to
 * a stock `role` and stays fixed (they're reserved in shared/shortcuts.ts, so
 * nothing can be rebound on top of them).
 */
function buildMenu(): Menu {
  // The tail of the edit menu, which `role: 'editMenu'` varies by platform.
  const editMenuTail: MenuItemConstructorOptions[] =
    process.platform === 'darwin'
      ? [
          { role: 'pasteAndMatchStyle' },
          { role: 'delete' },
          { role: 'selectAll' },
          { type: 'separator' },
          { label: 'Speech', submenu: [{ role: 'startSpeaking' }, { role: 'stopSpeaking' }] }
        ]
      : [{ role: 'delete' }, { type: 'separator' }, { role: 'selectAll' }]
  // Everything `role: 'appMenu'` would have generated, with About rewired to
  // the app's own window. Spelled as `label: app.name` + an explicit submenu
  // rather than `role: 'appMenu'` plus an override: whether a supplied
  // submenu beats a submenu-role's generated one is undocumented, while this
  // is the shape Electron's own menu docs use. macOS replaces the label with
  // the bundle name regardless — it is the first template entry that makes
  // this the application menu, not what it is called.
  const appMenu: MenuItemConstructorOptions = {
    label: app.name,
    submenu: [
      { label: 'About Tabs', click: () => openAboutWindow() },
      { type: 'separator' },
      { role: 'services' },
      { type: 'separator' },
      { role: 'hide' },
      { role: 'hideOthers' },
      { role: 'unhide' },
      { type: 'separator' },
      { role: 'quit' }
    ]
  }
  const template: MenuItemConstructorOptions[] = [
    ...(process.platform === 'darwin' ? [appMenu] : []),
    {
      label: 'File',
      submenu: [
        {
          // A window-level action with no renderer to forward to, like
          // Settings… below. See openNewWindow for what it opens.
          label: shortcutAction('new-window').label,
          ...acceleratorEntry('new-window'),
          click: () => openNewWindow()
        },
        {
          label: 'Settings…',
          ...acceleratorEntry('open-settings'),
          click: () => openSettingsWindow()
        },
        { type: 'separator' },
        paneShortcutItem('command-palette'),
        { type: 'separator' },
        paneShortcutItem('new-tab'),
        paneShortcutItem('split-horizontal'),
        paneShortcutItem('split-vertical'),
        paneShortcutItem('new-unpinned-pane'),
        {
          // Spelled out rather than built by paneShortcutItem: this is the one
          // forwarding item with a second behavior to choose between.
          label: shortcutAction('close-pane').label,
          ...acceleratorEntry('close-pane'),
          click: (_item, window) => {
            if (!(window instanceof BrowserWindow)) return
            // Neither auxiliary window has a close-pane listener (neither is
            // a pane-tree window) — closing one is just closing the window.
            if (isAuxiliaryWindow(window)) {
              window.close()
              return
            }
            window.webContents.send(IpcChannel.shortcutAction, 'close-pane')
          }
        },
        ...(process.platform === 'darwin'
          ? ([{ type: 'separator' }, caffeinateMenuItem()] satisfies MenuItemConstructorOptions[])
          : [])
      ]
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        ...editMenuTail,
        { type: 'separator' },
        // Content decides what clearing means — a terminal empties its
        // scrollback, anything else ignores it (see the 'clear-buffer' entry
        // in content/paneShortcuts.ts's HANDLERS). The Settings window has no
        // listener at all, so it needs no special case here the way Close
        // Pane does.
        paneShortcutItem('clear-buffer')
      ]
    },
    {
      label: 'View',
      submenu: [
        paneShortcutItem('refresh-pane'),
        { type: 'separator' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' }
      ]
    },
    { role: 'windowMenu' },
    // macOS already carries About in the application menu above; everywhere
    // else this is the only route to the window.
    ...(process.platform === 'darwin'
      ? []
      : ([
          { role: 'help', submenu: [{ label: 'About Tabs', click: () => openAboutWindow() }] }
        ] satisfies MenuItemConstructorOptions[]))
  ]
  return Menu.buildFromTemplate(withGuardedClicks(template))
}

/**
 * `items` with every custom `click` guarded, submenus included. Electron
 * dispatches a click synchronously with nothing to catch what escapes it — a
 * throw from building a window is the native error modal persist.ts
 * documents — so every click is wrapped here, once, the way
 * onRendererMessage wraps every `ipcMain.on` listener, rather than each
 * thing a click opens remembering to guard itself.
 */
function withGuardedClicks(items: MenuItemConstructorOptions[]): MenuItemConstructorOptions[] {
  return items.map((item) => {
    const { click, submenu } = item
    return {
      ...item,
      ...(click && {
        click: (...args: Parameters<typeof click>) => {
          try {
            click(...args)
          } catch (error) {
            console.error(`[tabs] menu item "${item.label ?? item.role}" threw:`, error)
          }
        }
      }),
      ...(Array.isArray(submenu) && { submenu: withGuardedClicks(submenu) })
    }
  })
}

/**
 * Rebuilds the application menu from the current settings and capture state,
 * and installs it. The only entry point — `buildMenu` stays private so nobody
 * can construct a menu without also making it the live one.
 */
export function applyMenu(): void {
  Menu.setApplicationMenu(buildMenu())
}
