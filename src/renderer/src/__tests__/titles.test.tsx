import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { renderApp } from '../testing/renderApp'

// Ported from e2e/titles.spec.ts — the rename mechanics are pure renderer
// behavior (including the right-click menu, which is the app's own DOM
// ContextMenu, not a native one). The OSC-title and relaunch-persistence
// tests stay in the Electron tier, where the real pty/disk are the subject.
//
// A fresh render already has one tab (root's own default — see ensureTabsRoot
// in tree.ts), titled "Tabs" — no setup click needed to get one to rename.

test('double-clicking a tab title, typing, and Enter renames it', async () => {
  renderApp()
  const user = userEvent.setup()
  const tab = screen.getByRole('tab')
  expect(tab).toHaveTextContent('Tabs')

  await user.dblClick(within(tab).getByText('Tabs'))
  const input = screen.getByTestId('tab-title-input')
  expect(input).toHaveFocus()
  await user.keyboard('Deploy{Enter}')

  expect(screen.queryByTestId('tab-title-input')).not.toBeInTheDocument()
  expect(tab).toHaveTextContent('Deploy')
})

test('Escape cancels a tab rename without saving', async () => {
  renderApp()
  const user = userEvent.setup()
  const tab = screen.getByRole('tab')

  await user.dblClick(within(tab).getByText('Tabs'))
  await user.keyboard('Should not stick{Escape}')

  expect(screen.queryByTestId('tab-title-input')).not.toBeInTheDocument()
  expect(tab).toHaveTextContent('Tabs')
})

test('clicking outside the tab textbox saves the change', async () => {
  renderApp()
  const user = userEvent.setup()
  const tab = screen.getByRole('tab')

  await user.dblClick(within(tab).getByText('Tabs'))
  await user.keyboard('Blurred save')
  await user.click(document.body)

  expect(screen.queryByTestId('tab-title-input')).not.toBeInTheDocument()
  expect(tab).toHaveTextContent('Blurred save')
})

test('right-click on a tab offers Edit title, reaching the same editing state', async () => {
  renderApp()
  const user = userEvent.setup()
  const tab = screen.getByRole('tab')

  fireEvent.contextMenu(tab, { clientX: 40, clientY: 40 })
  await user.click(screen.getByRole('menuitem', { name: 'Edit title' }))
  const input = screen.getByTestId('tab-title-input')
  expect(input).toHaveFocus()
  await user.keyboard('Via menu{Enter}')

  expect(tab).toHaveTextContent('Via menu')
})

test('double-clicking a pane header title, typing, and Enter renames it', async () => {
  renderApp()
  const user = userEvent.setup()
  const header = screen.getByTestId('pane-header')
  expect(header).toHaveTextContent('Empty pane')

  await user.dblClick(within(header).getByText('Empty pane'))
  await user.keyboard('Scratch{Enter}')

  expect(header).toHaveTextContent('Scratch')
})

test('clearing a pane title and saving reverts to the derived label', async () => {
  renderApp()
  const user = userEvent.setup()
  const header = screen.getByTestId('pane-header')

  await user.dblClick(within(header).getByText('Empty pane'))
  await user.keyboard('Temp title{Enter}')
  expect(header).toHaveTextContent('Temp title')

  await user.dblClick(within(header).getByText('Temp title'))
  // The editor mounts with the current title selected; Delete empties it.
  await user.keyboard('{Delete}{Enter}')

  expect(header).toHaveTextContent('Empty pane')
})

test('right-click on a pane header offers Edit title', async () => {
  renderApp()
  const user = userEvent.setup()
  const header = screen.getByTestId('pane-header')

  fireEvent.contextMenu(header, { clientX: 40, clientY: 40 })
  await user.click(screen.getByRole('menuitem', { name: 'Edit title' }))
  const input = screen.getByTestId('pane-title-input')
  expect(input).toHaveFocus()
  await user.keyboard('Via menu{Enter}')

  expect(header).toHaveTextContent('Via menu')
})
