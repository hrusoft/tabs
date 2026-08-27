import { nativeTheme } from 'electron'
import { DEFAULT_SETTINGS } from '../shared/settings'
import { resolveTheme, type ThemeSetting } from '../shared/theme'
import { forEachLiveWindow } from './liveWindows'
import { getSettings, subscribeSettings } from './settings'

/**
 * The half of theming that CSS can't reach.
 *
 * Two things live here. `nativeTheme.themeSource` swings everything Chromium
 * and AppKit paint on the app's behalf — the traffic lights, the Settings
 * window's native title bar, the `dialog.showMessageBox` quit/close
 * confirmations, and (because it feeds `prefers-color-scheme` app-wide) any
 * `<webview>` guest whose page supports dark mode. Its vocabulary is exactly
 * `'dark' | 'light' | 'system'`, which is where ThemeSetting's comes from.
 *
 * And the window background: a BrowserWindow paints it before the renderer's
 * first frame, so without one both windows flash Chromium's default white on
 * launch. It comes from the theme rather than a literal so it can never drift
 * from what the renderer paints a moment later.
 */

/**
 * The live setting. Held here rather than read back from
 * `nativeTheme.themeSource` so this module owns its own state — themeSource is
 * where it's *pushed*, not where it's kept.
 */
let current: ThemeSetting = DEFAULT_SETTINGS.colorTheme

/**
 * The color the OS window paints under the renderer. Safe to call from a
 * BrowserWindow constructor: installNativeTheme runs before any window is built
 * (see index.ts's whenReady), so `current` already reflects the persisted
 * setting by then.
 */
export function themeWindowBackground(): string {
  // shouldUseDarkColors only matters while `current` is 'system' — under an
  // explicit 'dark'/'light' resolveTheme ignores it, and themeSource has
  // forced it to agree anyway.
  return resolveTheme(current, nativeTheme.shouldUseDarkColors).windowBackground
}

function paintWindows(): void {
  const background = themeWindowBackground()
  forEachLiveWindow((win) => win.setBackgroundColor(background))
}

function apply(setting: ThemeSetting): void {
  current = setting
  nativeTheme.themeSource = setting
  paintWindows()
}

/**
 * Pushes the persisted theme into the native layer and keeps it there. Must be
 * called after registerSettingsIpc (it reads the loaded settings) and before
 * the first window is created (which reads themeWindowBackground).
 *
 * Registers no IPC of its own — it rides the settings module's change hook —
 * which is why it isn't named `register*Ipc` like its neighbours in whenReady.
 */
export function installNativeTheme(): void {
  apply(getSettings().colorTheme)

  // The settings module's own change hook — see subscribeSettings' doc in
  // main/settings.ts for why it exists instead of a second `ipcMain.on` on
  // the same channel.
  subscribeSettings((partial) => {
    if (partial.colorTheme === undefined || partial.colorTheme === current) return
    apply(partial.colorTheme)
  })

  // Under 'system', the OS appearance can change while the app runs. Each
  // renderer follows on its own through prefers-color-scheme (see
  // installTheme.ts), but the native window background is not CSS and has to
  // be repainted here. Fires on our own themeSource writes too; repainting is
  // idempotent, so that costs nothing.
  nativeTheme.on('updated', () => {
    if (current === 'system') paintWindows()
  })
}

/**
 * e2e only: returns the native layer to what a freshly launched app would have.
 * `nativeTheme.themeSource` is process-wide mutable state that outlives a
 * renderer reload, so without this a test that switched to light would leave
 * every later test in the file running against light native chrome. See
 * main/e2e.ts.
 */
export function resetThemeForTests(): void {
  apply(DEFAULT_SETTINGS.colorTheme)
}
