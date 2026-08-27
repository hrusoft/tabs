import { DARK_THEME, LIGHT_THEME } from '@shared/theme'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { useSettingsStore } from '../core/store/settingsStore'
import { installTheme } from '../core/theme/installTheme'

/**
 * A controllable `prefers-color-scheme` — the polyfill in vitest.polyfills.ts
 * only keeps matchMedia from throwing, so anything testing the `system` alias
 * installs its own over it. Deliberately a getter: installTheme resolves the
 * query object once and re-reads `.matches` on every apply, which is exactly
 * the behavior that has to keep working.
 */
function installFakeMatchMedia(initialDark: boolean): (dark: boolean) => void {
  const listeners = new Set<() => void>()
  let dark = initialDark
  const query = {
    get matches() {
      return dark
    },
    media: '(prefers-color-scheme: dark)',
    addEventListener: (_type: string, listener: () => void) => {
      listeners.add(listener)
    },
    removeEventListener: (_type: string, listener: () => void) => {
      listeners.delete(listener)
    }
  }
  window.matchMedia = (() => query) as unknown as typeof window.matchMedia
  return (next: boolean) => {
    dark = next
    for (const listener of [...listeners]) listener()
  }
}

function tokensOf(): Record<string, string> {
  const style = document.documentElement.style
  const result: Record<string, string> = {}
  for (const token of Object.keys(DARK_THEME.tokens)) {
    result[token] = style.getPropertyValue(token)
  }
  return result
}

const originalMatchMedia = window.matchMedia
let dispose: (() => void) | undefined

beforeEach(() => {
  useSettingsStore.setState({ colorTheme: 'dark' })
})

afterEach(() => {
  dispose?.()
  dispose = undefined
  window.matchMedia = originalMatchMedia
  document.documentElement.removeAttribute('style')
  document.documentElement.removeAttribute('data-theme')
})

describe('installTheme', () => {
  it('applies every token, color-scheme and data-theme up front', () => {
    installFakeMatchMedia(false)
    dispose = installTheme()

    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(document.documentElement.style.colorScheme).toBe('dark')
    expect(tokensOf()).toEqual(DARK_THEME.tokens)
  })

  // The store is the only thing the picker touches; everything else has to
  // follow from it, including in the window that didn't make the change (whose
  // store is updated by the settings:changed mirror).
  it('re-applies when the setting changes', () => {
    installFakeMatchMedia(false)
    dispose = installTheme()

    useSettingsStore.getState().setSetting('colorTheme', 'light')

    expect(document.documentElement.dataset.theme).toBe('light')
    expect(document.documentElement.style.colorScheme).toBe('light')
    expect(tokensOf()).toEqual(LIGHT_THEME.tokens)
  })

  it('leaves the tokens alone when an unrelated setting changes', () => {
    installFakeMatchMedia(false)
    dispose = installTheme()
    document.documentElement.style.setProperty('--bg', 'sentinel')

    useSettingsStore.getState().setSetting('showNavFlash', false)

    // The identity guard in installTheme means an unrelated write does no DOM
    // work at all — a continuous control (a color-picker drag) fires the store
    // on every tick.
    expect(document.documentElement.style.getPropertyValue('--bg')).toBe('sentinel')
  })

  describe('system', () => {
    it('resolves to dark or light from the OS preference at install time', () => {
      installFakeMatchMedia(true)
      useSettingsStore.setState({ colorTheme: 'system' })
      dispose = installTheme()
      expect(document.documentElement.dataset.theme).toBe('dark')
      dispose()

      installFakeMatchMedia(false)
      dispose = installTheme()
      expect(document.documentElement.dataset.theme).toBe('light')
    })

    // The ticket's actual requirement: not just resolved at launch, but
    // tracked while the app is running.
    it('follows the OS preference changing while running', () => {
      const setDark = installFakeMatchMedia(false)
      useSettingsStore.setState({ colorTheme: 'system' })
      dispose = installTheme()
      expect(document.documentElement.dataset.theme).toBe('light')

      setDark(true)
      expect(document.documentElement.dataset.theme).toBe('dark')
      expect(tokensOf()).toEqual(DARK_THEME.tokens)

      setDark(false)
      expect(document.documentElement.dataset.theme).toBe('light')
    })

    it('ignores the OS preference once a real theme is picked', () => {
      const setDark = installFakeMatchMedia(false)
      useSettingsStore.setState({ colorTheme: 'dark' })
      dispose = installTheme()

      setDark(true)
      expect(document.documentElement.dataset.theme).toBe('dark')
      setDark(false)
      expect(document.documentElement.dataset.theme).toBe('dark')
    })
  })

  it('stops following anything after its disposer runs', () => {
    const setDark = installFakeMatchMedia(false)
    useSettingsStore.setState({ colorTheme: 'system' })
    dispose = installTheme()
    expect(document.documentElement.dataset.theme).toBe('light')

    dispose()
    dispose = undefined

    // Both subscriptions, not just one: the media query and the store.
    setDark(true)
    expect(document.documentElement.dataset.theme).toBe('light')
    useSettingsStore.getState().setSetting('colorTheme', 'dark')
    expect(document.documentElement.dataset.theme).toBe('light')
  })
})
