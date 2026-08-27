import { expect, test, withApp } from './helpers/launch'
import { initialPane, openNewTab, splitHorizontal } from './helpers/pane'
import { openTerminal, typeAndEnter } from './helpers/terminal'

// Only the tests whose subject is the integration remain here: a real shell
// pushing OSC titles through the pty, and titles surviving a real quit and
// relaunch from disk. The rename mechanics live in
// src/renderer/src/__tests__/titles.test.tsx.

test('a manually renamed pane title is not overwritten by the terminal inside it', async ({
  page
}) => {
  const header = page.getByTestId('pane-header')
  const term = await openTerminal(initialPane(page))

  await header.locator('.pane-title').dblclick()
  await page.getByTestId('pane-title-input').fill('My terminal')
  await page.getByTestId('pane-title-input').press('Enter')
  await expect(header).toContainText('My terminal')

  await typeAndEnter(term, "printf '\\033]0;from-the-shell\\007'")

  await expect(header).toContainText('My terminal')
  await expect(header).not.toContainText('from-the-shell')
})

test('clearing a manual pane title re-enables live updates from the terminal', async ({ page }) => {
  const header = page.getByTestId('pane-header')
  const term = await openTerminal(initialPane(page))

  await header.locator('.pane-title').dblclick()
  await page.getByTestId('pane-title-input').fill('My terminal')
  await page.getByTestId('pane-title-input').press('Enter')
  await expect(header).toContainText('My terminal')

  await header.locator('.pane-title').dblclick()
  await page.getByTestId('pane-title-input').fill('')
  await page.getByTestId('pane-title-input').press('Enter')
  await expect(header).toContainText('Terminal')

  // The trailing sleep holds this title in place against a competing OSC
  // title the shell's own prompt might emit the instant it redraws — see the
  // comment in terminal.spec.ts's equivalent test.
  await typeAndEnter(term, "printf '\\033]0;from-the-shell\\007'; sleep 5")

  await expect(header).toContainText('from-the-shell')
})

test('renamed tab and pane titles survive a relaunch', async ({ userDataDir }) => {
  await withApp(userDataDir, async (_app1, page1) => {
    await page1.getByTestId('pane-header').locator('.pane-title').dblclick()
    await page1.getByTestId('pane-title-input').fill('Scratch pane')
    await page1.getByTestId('pane-title-input').press('Enter')

    await splitHorizontal(initialPane(page1))
    const panes1 = page1.getByTestId('pane')
    // Root's own wrapper stays pane 0; the renamed original leaf (still
    // holding its "Scratch pane" title override, unaffected by the split)
    // is pane 1. Wrap the *other*, untouched split child (pane 2) into a
    // tab group instead — wrapping the renamed one would discard it, since
    // it's still empty content-wise (openContent's empty-target branch in
    // tree.ts keeps only the new tab when the original held nothing).
    await openNewTab(panes1.nth(2))
    // Root's own tablist ("Tabs") is untouched; the new nested one is second.
    const tab1 = page1.getByRole('tablist').nth(1).getByRole('tab')
    await tab1.locator('.tab-title').dblclick()
    await page1.getByTestId('tab-title-input').fill('My deploy')
    await page1.getByTestId('tab-title-input').press('Enter')
  })

  await withApp(userDataDir, async (_app2, page2) => {
    await expect(page2.getByTestId('pane-header').first()).toContainText('Scratch pane')
    await expect(page2.getByRole('tablist').nth(1).getByRole('tab')).toContainText('My deploy')
  })
})
