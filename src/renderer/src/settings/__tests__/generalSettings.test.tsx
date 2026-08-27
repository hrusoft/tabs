import { togglableContentTypes } from '@shared/content/enablement'
import { DEFAULT_SETTINGS } from '@shared/settings'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { lastSettingsWrite, mountSettingsPage } from '../../testing/settingsPageFixture'
import { GeneralSettings } from '../GeneralSettings'

/**
 * The General page's one control that is more than a row of data — its
 * Content types section. Mounted directly, like the Keyboard page's own
 * test — the Settings window is its own entry point and there is no
 * renderApp equivalent for it.
 *
 * Each test states the settings it is about; nothing here inherits a shipped
 * default. The "every flat setting has a row somewhere" coverage check lives
 * in settingsCoverage.test.tsx, since that page's rows are now split between
 * this page and PanesSettings.
 */

function mount(disabledContentTypes: string[]): void {
  mountSettingsPage(GeneralSettings, { disabledContentTypes })
}

/** The last `disabledContentTypes` the page persisted through the bridge. */
function lastWrite(): string[] | undefined {
  return lastSettingsWrite('disabledContentTypes')
}

function checkbox(type: string): HTMLInputElement {
  return screen.getByTestId(`settings-content-type-${type}-checkbox`) as HTMLInputElement
}

test('offers one checkbox per togglable content type, driven by the census', () => {
  mount([])

  const types = togglableContentTypes().map((manifest) => manifest.type)
  // Not vacuous: the built-ins really are togglable.
  expect(types.length).toBeGreaterThan(0)
  for (const type of types) expect(checkbox(type)).toBeChecked()

  // Labelled from the manifest, so core names no content type in its own copy.
  for (const { displayName } of togglableContentTypes()) {
    expect(screen.getByText(displayName)).toBeInTheDocument()
  }
})

test('a disabled type shows as unchecked', () => {
  const [first] = togglableContentTypes()
  mount([first!.type])

  expect(checkbox(first!.type)).not.toBeChecked()
})

test('unchecking a type adds exactly that one to the setting', async () => {
  const [first] = togglableContentTypes()
  mount([])
  const user = userEvent.setup()

  await user.click(checkbox(first!.type))

  expect(lastWrite()).toEqual([first!.type])
})

test('checking a type back removes it without disturbing the others', async () => {
  const [first, second] = togglableContentTypes()
  expect(second).toBeDefined()
  mount([first!.type, second!.type])
  const user = userEvent.setup()

  await user.click(checkbox(first!.type))

  expect(lastWrite()).toEqual([second!.type])
})

test('the write is a fresh array, never the shared defaults singleton mutated', async () => {
  const [first] = togglableContentTypes()
  mount([])
  const user = userEvent.setup()

  await user.click(checkbox(first!.type))

  expect(lastWrite()).not.toBe(DEFAULT_SETTINGS.disabledContentTypes)
  expect(DEFAULT_SETTINGS.disabledContentTypes).toEqual([])
})
