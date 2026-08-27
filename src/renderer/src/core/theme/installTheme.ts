import { resolveTheme, type Theme } from '@shared/theme'
import { useSettingsStore } from '../store/settingsStore'

/**
 * Paints a theme onto the document: the token values every rule in global.css
 * reads, plus `color-scheme` (native scrollbars and the built-in chrome of
 * `<select>`/`<input type="color">`/`<input type="range">`, which the app never
 * styles itself) and a `data-theme` attribute for anything that needs to branch
 * in CSS or assert in a test.
 *
 * Iterates the theme's own record rather than a list of properties kept here,
 * so a new ThemeToken needs no edit in this file.
 */
function applyTheme(theme: Theme): void {
  const root = document.documentElement
  root.dataset.theme = theme.id
  root.style.colorScheme = theme.colorScheme
  for (const [token, value] of Object.entries(theme.tokens)) {
    root.style.setProperty(token, value)
  }
}

/** The media query whose answer `system` resolves through. */
const PREFERS_DARK = '(prefers-color-scheme: dark)'

/**
 * Applies the current theme and keeps it applied. Returns the disposer, though
 * the app itself never calls it — the subscriptions live as long as the
 * renderer does; it exists for tests.
 *
 * Call this at module scope in an entry point, BEFORE `createRoot().render()`
 * and after the `window.api` bridge exists. It reads the settings store, which
 * reads `window.api.settings.getSync()` at module-eval time (the sync-IPC-at-
 * init pattern — see CLAUDE.md), so the first token write happens before React
 * mounts anything and no frame is ever painted with the wrong palette. An
 * async hydrate here would flash the default theme.
 *
 * `system` is resolved from `prefers-color-scheme` rather than by asking the
 * main process for `nativeTheme.shouldUseDarkColors`. That is not a shortcut
 * around IPC — it's the same number: main sets `nativeTheme.themeSource` from
 * this very setting, and themeSource is precisely what feeds Chromium's
 * `prefers-color-scheme`, so the two cannot disagree. Reading it here keeps
 * the resolution synchronous and gives live OS tracking for free through the
 * query's own `change` event.
 *
 * Cross-window edits need no extra wiring either: settingsStore already
 * mirrors another window's change into this one (the `settings:changed`
 * broadcast), so the store subscription below fires and the theme follows.
 */
export function installTheme(): () => void {
  const media = window.matchMedia(PREFERS_DARK)
  // The store fires on every settings write — including a continuous one like
  // a terminal color-picker drag — so skip the DOM writes unless the resolved
  // theme actually changed. Theme objects are module singletons, so identity
  // is the right comparison.
  let applied: Theme | null = null
  const apply = (): void => {
    const theme = resolveTheme(useSettingsStore.getState().colorTheme, media.matches)
    if (theme === applied) return
    applied = theme
    applyTheme(theme)
  }

  apply()
  media.addEventListener('change', apply)
  const unsubscribe = useSettingsStore.subscribe(apply)

  return () => {
    media.removeEventListener('change', apply)
    unsubscribe()
  }
}
