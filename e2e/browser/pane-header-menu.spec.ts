import { PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { headerOf, initialPane } from '../helpers/pane'
import { expect, test } from './helpers/harness'

// Real-CSS coverage for the pane header's hover-expand groups
// (PaneHeaderMenuGroup): the menu is `visibility: hidden` until its group's
// root button is hovered, which only a real browser enforces — jsdom never
// loads global.css, so this behavior is invisible there (see
// src/renderer/src/__tests__/pane-header.test.tsx for the structural half).

test('a menu item is not clickable until its group root is hovered', async ({ page }) => {
  // Not the docked root's own header — that group's root button *is* New
  // tab directly (PaneHeaderControls.tsx's isDockedRoot branch), so it
  // wouldn't exercise the hover-to-reveal nesting this test is about.
  const header = headerOf(initialPane(page))
  const newTab = header.getByTestId(PANE_BUTTON.newTab)

  // Present in the DOM (structural, unconditional) but not yet interactive —
  // the click never lands because the panel is `visibility: hidden`.
  await expect(newTab.click({ trial: true, timeout: 500 })).rejects.toThrow()

  // force: true — the menu opens flush over its root button (see
  // .pane-header-dropdown in global.css), so hovering the root is exactly
  // what makes it stop being the thing at that position; Playwright's own
  // "does the target itself receive this" check can never pass for it.
  await header.getByTestId(PANE_BUTTON.splitHorizontal).hover({ force: true })
  await newTab.click()

  // Root's own wrapper, the pane's own original tab content, and the new
  // sibling tab New tab just added (this pane sits directly in root's own
  // tab — see openContent in tree.ts — so the click adds a sibling rather
  // than wrapping a new nested group).
  await expect(page.getByTestId('pane')).toHaveCount(3)
})
