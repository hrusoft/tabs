import type { Page } from '@playwright/test'
import {
  activatePane,
  clickPaneRoot,
  initialPane,
  openNewTab,
  splitHorizontal
} from '../helpers/pane'
import { MOD_KEY } from '../helpers/platform'
import { expect, test } from './helpers/harness'

// Focus-follows-active, at the one tier that can hold it honest. Whether a
// pane's content really takes the keyboard turns on whether it is on screen at
// the moment core asks: focus() is silently refused inside a `display: none`
// subtree, which is exactly what a backgrounded tab's panel is
// (TabsRenderer.tsx renders inactive tabs `hidden`). jsdom's focusability
// check reads neither `hidden` nor `display`, so the jsdom tier passes these
// vacuously; the Electron tier covers the same ground with a real pty
// (e2e/keyboard-nav.spec.ts) and pays seconds per shell for it.
//
// The stub content type supplies the DOM half — a focusable container its pane
// handle focuses, the way the terminal focuses xterm's helper textarea (see
// src/renderer/src/testing/stubContent.tsx).

/** Fills the initial pane with stub content, then adds a second tab holding its clone. */
async function twoStubTabs(page: Page): Promise<void> {
  await clickPaneRoot(initialPane(page), 'pane-new-stub-button')
  // "New tab" clones the origin pane's own type, so tab 2 gets a stub too —
  // and lands active, backgrounding tab 1.
  await openNewTab(initialPane(page))
}

test('clicking a tab hands the keyboard to the pane it reveals', async ({ page }) => {
  await twoStubTabs(page)
  const panes = page.getByTestId('pane')
  // Root's own wrapper (0), then the two tabs' content panes.
  await expect(panes).toHaveCount(3)
  const tabs = page.getByRole('tab')
  await expect(panes.nth(2)).toHaveClass(/pane-active/)

  await tabs.nth(0).click()

  await expect(panes.nth(1)).toHaveClass(/pane-active/)
  // The highlight moving is the easy half; this is the one that was broken —
  // the focus landed while the revealed panel was still hidden, so it landed
  // nowhere and typing went to no pane at all.
  await expect(panes.nth(1).getByTestId('stub-content')).toBeFocused()

  // And back, so the return direction is covered too.
  await tabs.nth(1).click()
  await expect(panes.nth(2).getByTestId('stub-content')).toBeFocused()
})

test('cmd+arrow onto another tab hands the keyboard to the pane it reveals', async ({ page }) => {
  await twoStubTabs(page)
  const panes = page.getByTestId('pane')
  const tabs = page.getByRole('tab')

  await tabs.nth(0).click()
  await expect(panes.nth(1).getByTestId('stub-content')).toBeFocused()

  // A pane at the edge of a tab group walks the group before leaving it, so
  // this switches tabs rather than moving across a split.
  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)

  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(2).getByTestId('stub-content')).toBeFocused()
})

test('activating a pane across a split hands it the keyboard', async ({ page }) => {
  // The control for the two above: both panes are visible throughout here, so
  // this path worked even while the tab-switch one silently did not.
  await clickPaneRoot(initialPane(page), 'pane-new-stub-button')
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await expect(panes).toHaveCount(3)

  await activatePane(panes.nth(1))
  await expect(panes.nth(1).getByTestId('stub-content')).toBeFocused()

  await page.keyboard.press(`${MOD_KEY}+ArrowRight`)
  await expect(panes.nth(2)).toHaveClass(/pane-active/)
  await expect(panes.nth(2).getByTestId('stub-content')).toBeFocused()
})
