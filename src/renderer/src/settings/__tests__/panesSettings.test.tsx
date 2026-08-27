import { DEFAULT_NEW_PANE_SPAWN_POSITION, NEW_PANE_SPAWN_POSITIONS } from '@shared/model/floating'
import type { Settings } from '@shared/settings'
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { lastSettingsWrite, mountSettingsPage } from '../../testing/settingsPageFixture'
import { PanesSettings } from '../PanesSettings'

/**
 * The Panes & Tabs page's one control that is more than a row of data — the
 * new-unpinned-pane position picker. Mounted directly, like the Keyboard
 * page's own test — the Settings window is its own entry point and there is
 * no renderApp equivalent for it.
 *
 * Its *geometry* — what each of the nine values does to a spawned window — is
 * covered where it's cheapest, as pure arithmetic in
 * shared/model/__tests__/floating.test.ts and end to end in
 * e2e/browser/floating.spec.ts. What's left for this tier is the control
 * itself: what it shows, what it writes, and what the keyboard does to it.
 *
 * Note jsdom does not implement a native radio group's own arrow-key roving,
 * so the horizontal arrows are deliberately not asserted here — that behaviour
 * is the platform's, not ours. The vertical stepping is ours and is.
 */

function mountSettings(partial: Partial<Settings>): void {
  mountSettingsPage(PanesSettings, partial)
}

function positionCell(position: string): HTMLInputElement {
  return screen.getByTestId(`settings-unpinned-position-${position}`) as HTMLInputElement
}

/** The last position the page persisted through the bridge. */
function lastPositionWrite(): string | undefined {
  return lastSettingsWrite('newUnpinnedPanePosition')
}

test('offers one cell per position, with the stored one selected', () => {
  mountSettings({ newUnpinnedPanePosition: 'bottom-left' })

  for (const position of NEW_PANE_SPAWN_POSITIONS) {
    expect(positionCell(position)).toBeInTheDocument()
  }
  expect(screen.getAllByRole('radio')).toHaveLength(NEW_PANE_SPAWN_POSITIONS.length)
  expect(positionCell('bottom-left')).toBeChecked()
  expect(positionCell('top-right')).not.toBeChecked()
})

test('clicking a cell writes exactly that position', async () => {
  mountSettings({ newUnpinnedPanePosition: 'top-right' })
  const user = userEvent.setup()

  await user.click(positionCell('middle-center'))

  expect(lastPositionWrite()).toBe('middle-center')
  expect(positionCell('middle-center')).toBeChecked()
})

test('a stored value no position matches selects the default cell, not none', () => {
  // What a hand-edited settings.json can produce. The control degrading to
  // "nothing selected" would misreport where panes will actually spawn.
  mountSettings({ newUnpinnedPanePosition: 'banana' as never })

  expect(positionCell(DEFAULT_NEW_PANE_SPAWN_POSITION)).toBeChecked()
})

test('the down arrow steps a row, where the native group would step a cell', async () => {
  mountSettings({ newUnpinnedPanePosition: 'top-left' })
  const user = userEvent.setup()
  positionCell('top-left').focus()

  await user.keyboard('{ArrowDown}')

  // Native radio handling would have landed on top-center, to the right.
  expect(positionCell('middle-left')).toBeChecked()
  expect(lastPositionWrite()).toBe('middle-left')
})

test('the vertical arrows wrap, the way the native horizontal ones do', async () => {
  mountSettings({ newUnpinnedPanePosition: 'top-center' })
  const user = userEvent.setup()
  positionCell('top-center').focus()

  await user.keyboard('{ArrowUp}')

  expect(positionCell('bottom-center')).toBeChecked()
})
