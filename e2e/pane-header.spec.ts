import { PANE_BUTTON } from '../src/shared/paneDomAttrs'
import { REATTACH_GRACE_MS } from '../src/shared/reattach'
import { expect, test } from './helpers/launch'
import {
  clearPane,
  closePane,
  headerOf,
  initialPane,
  splitHorizontal,
  wrapInTabGroup
} from './helpers/pane'
import { alive, openTerminal, typeAndEnter } from './helpers/terminal'

// Only the tests whose subject is the pty remain here: close/clear killing
// the real shell (through the pane.confirmClose close-blocker IPC), and
// reattach keeping it alive across a structural move. The structural
// pane-chrome tests live in src/renderer/src/__tests__/pane-header.test.tsx.

test('the title-bar close collapses the split and kills the shell inside', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper stays pane 0; the split activated its own new pane,
  // nth(2), which is where the terminal goes.
  const term = await openTerminal(panes.nth(2))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  expect(pid).toBeGreaterThan(0)

  await closePane(panes.nth(2))

  // Root's own wrapper, plus the split's sole survivor (the collapse leaves
  // the original leaf sitting directly in root's tab again).
  await expect(page.getByTestId('pane')).toHaveCount(2)
  await expect(page.getByTestId('terminal')).toHaveCount(0)
  await expect(page.getByTestId('empty-pane')).toHaveCount(1)
  // Disposal is debounced (terminalRegistry.ts); a real close has no
  // follow-up mount, so the process still dies shortly after.
  await expect.poll(() => alive(electronApp, pid), { timeout: 3000 }).toBe(false)
})

test('clearing a pane empties it in place, keeping the split but killing the shell', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper stays pane 0; the split activated its own new pane,
  // nth(2), which is where the terminal goes.
  const term = await openTerminal(panes.nth(2))
  const pid = Number(await term.getAttribute('data-pty-pid'))

  await clearPane(panes.nth(2))

  // Same slot, new placeholder: the split survives, the content doesn't —
  // root's wrapper plus the split's two panes.
  await expect(panes).toHaveCount(3)
  await expect(page.getByTestId('terminal')).toHaveCount(0)
  await expect(page.getByTestId('empty-pane')).toHaveCount(2)
  await expect(headerOf(panes.nth(2))).toContainText('Empty pane')
  // Nothing left to clear on a placeholder.
  await expect(headerOf(panes.nth(2)).getByTestId(PANE_BUTTON.clear)).toBeDisabled()
  await expect.poll(() => alive(electronApp, pid), { timeout: 3000 }).toBe(false)
})

test('the tab-group control wraps a live terminal into a group without killing it', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  await typeAndEnter(term, 'echo before-wrap-marker')
  await expect(term).toContainText('before-wrap-marker')

  await wrapInTabGroup(initialPane(page))

  // The terminal became the sole tab of a group that took over its slot —
  // and, unlike removal paths, the one-tab group persists. Root's own
  // tablist ("Tabs") is untouched, so this is the second one.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tablist').nth(1).getByRole('tab')).toHaveCount(1)
  await expect(page.getByRole('tab', { name: 'Terminal' })).toBeVisible()
  const panes = page.getByTestId('pane')
  // Root's own wrapper, the new group's wrapper, and the terminal's own pane.
  await expect(panes).toHaveCount(3)
  // The group's chrome is its tab strip, hosting the pane controls.
  await expect(headerOf(panes.nth(1)).getByTestId(PANE_BUTTON.close)).toHaveCount(1)
  // The wrap hands focus to the group it created.
  await expect(panes.nth(1)).toHaveClass(/pane-active/)

  // Same shell, same buffer: outlive the disposal grace with the
  // scrollback intact.
  await expect(term).toHaveAttribute('data-pty-pid', String(pid))
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, pid)).toBe(true)
  await expect(term).toContainText('before-wrap-marker')
  await typeAndEnter(term, 'echo survived-the-wrap')
  await expect(term).toContainText('survived-the-wrap')
})
