import { CONTENT_TYPE_MANIFESTS } from '@shared/content/registry'
import { act, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, test } from 'vitest'
import { mountSettingsPage } from '../../testing/settingsPageFixture'
import { registerBuiltinSettingsPages } from '../registerBuiltinPages'
import { SettingsWindow } from '../SettingsWindow'

/**
 * The Settings window's sidebar against a disabled content type.
 *
 * Mounts the real window over the real page list — `registerBuiltinSettingsPages`
 * is safe to import here for the same reason it exists at all: page defs are
 * separate modules from their renderers, so nothing drags xterm or the
 * `<webview>` tag into this tier (see registerBuiltinPages.ts). Registration is
 * idempotent, so the shared module-level registry survives across tests.
 *
 * Each test states its own `disabledContentTypes`.
 */

function mount(disabledContentTypes: string[]): void {
  mountSettingsPage(SettingsWindow, { disabledContentTypes })
}

/** The census entry whose settings page is the one this file drives. */
const withPage = CONTENT_TYPE_MANIFESTS.find((manifest) => manifest.settings)

beforeEach(() => {
  registerBuiltinSettingsPages()
})

test('a content type with a settings page gets a sidebar entry while it is enabled', () => {
  expect(withPage).toBeDefined()
  mount([])

  expect(screen.getByTestId(`settings-tab-${withPage?.type}`)).toBeInTheDocument()
  // Core's own pages are absent from the census, so the filter never sees them.
  expect(screen.getByTestId('settings-tab-general')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-panes')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-keyboard')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-skills')).toBeInTheDocument()
})

test('the sidebar lists content types in census order, between the core pages', () => {
  // Order is stamped by each package's settings context from its census
  // position — a page cannot pick a colliding literal, so the sidebar cannot
  // fall through to the registry's label tiebreak (which once decided
  // browser-vs-gitTree by accident of their display names).
  mount([])

  const ids = screen
    .getAllByTestId(/^settings-tab-/)
    .map((el) => el.getAttribute('data-testid')?.replace('settings-tab-', ''))
  const typesWithPages = CONTENT_TYPE_MANIFESTS.filter((manifest) => manifest.settings).map(
    (manifest) => manifest.type as string
  )
  expect(ids).toEqual(['general', 'panes', 'keyboard', ...typesWithPages, 'skills'])
})

test('disabling that type removes its sidebar entry, and only its own', () => {
  mount([String(withPage?.type)])

  expect(screen.queryByTestId(`settings-tab-${withPage?.type}`)).not.toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-general')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-panes')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-keyboard')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-skills')).toBeInTheDocument()
})

test('a page hidden while the user is reading it falls back rather than going blank', async () => {
  mount([])
  const user = userEvent.setup()

  await user.click(screen.getByTestId(`settings-tab-${withPage?.type}`))
  expect(screen.getByTestId(`settings-page-${withPage?.type}`)).toBeInTheDocument()

  // The realistic route in: another window (or the main window's own store
  // mirror) turning the type off while this one is showing its page.
  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [String(withPage?.type)] })
  })

  // Not an empty content area with nothing selected in the sidebar.
  expect(screen.getByTestId('settings-page-general')).toBeInTheDocument()
  expect(screen.getByTestId('settings-tab-general')).toHaveAttribute('data-active', 'true')
})

test('re-enabling returns the user to the page they were reading', async () => {
  mount([])
  const user = userEvent.setup()
  await user.click(screen.getByTestId(`settings-tab-${withPage?.type}`))

  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [String(withPage?.type)] })
  })
  expect(screen.getByTestId('settings-page-general')).toBeInTheDocument()

  act(() => {
    window.__fakeApi?.emitSettingsChange({ disabledContentTypes: [] })
  })

  // The selection was derived, never written back over `activeTab` — which is
  // exactly what makes this recoverable instead of silently losing the user's
  // place.
  expect(screen.getByTestId(`settings-page-${withPage?.type}`)).toBeInTheDocument()
  expect(screen.getByTestId(`settings-tab-${withPage?.type}`)).toHaveAttribute(
    'data-active',
    'true'
  )
})
