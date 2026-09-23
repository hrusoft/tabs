import { act, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, test } from 'vitest'
import { renderApp } from '../testing/renderApp'

// The real spawn/exit/kill wiring is main-process (main/caffeinate.ts,
// main/caffeinateProcess.ts) and covered against the real /usr/bin/caffeinate
// in e2e/caffeinate.spec.ts; this covers the renderer's own wiring against
// the fake bridge — the button's visibility and DOM position, the dialog's
// field-to-flags mapping, and the menu-forwarded open path (installCaffeinate.ts).

test('the cup button is absent while not running, and appears immediately before the Settings button once it is', () => {
  renderApp()
  expect(screen.queryByTestId('caffeinate-decaf-button')).not.toBeInTheDocument()

  act(() => {
    window.__fakeApi?.emitCaffeinateRunningChanged(true)
  })

  const cup = screen.getByTestId('caffeinate-decaf-button')
  const settings = screen.getByTestId('settings-open-button')
  expect(cup).toBeInTheDocument()
  // DOCUMENT_POSITION_FOLLOWING: settings comes after cup in tree order.
  expect(cup.compareDocumentPosition(settings) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
})

test('clicking the cup button does the same thing as Decaf: calls caffeinate.stop', async () => {
  renderApp()
  const user = userEvent.setup()
  act(() => {
    window.__fakeApi?.emitCaffeinateRunningChanged(true)
  })

  await user.click(screen.getByTestId('caffeinate-decaf-button'))

  expect(window.__fakeApi?.caffeinateStops()).toBe(1)
  // The fake's own stop() flips running back to false synchronously, the
  // same way main's broadcastRunning does once the real kill lands.
  expect(screen.queryByTestId('caffeinate-decaf-button')).not.toBeInTheDocument()
})

test('the menu-forwarded open-dialog event opens the real dialog, and Start sends the toggled flags', async () => {
  renderApp()
  const user = userEvent.setup()

  act(() => {
    window.__fakeApi?.fireCaffeinateOpenDialog()
  })
  expect(await screen.findByTestId('caffeinate-dialog')).toBeInTheDocument()

  // Defaults: idle system sleep + system sleep on, display/disk/active off.
  expect(screen.getByTestId('caffeinate-field-idle')).toBeChecked()
  expect(screen.getByTestId('caffeinate-field-system')).toBeChecked()
  expect(screen.getByTestId('caffeinate-field-display')).not.toBeChecked()
  expect(screen.getByTestId('caffeinate-field-disk')).not.toBeChecked()
  expect(screen.getByTestId('caffeinate-field-active')).not.toBeChecked()

  await user.click(screen.getByTestId('caffeinate-field-display'))
  await user.click(screen.getByTestId('caffeinate-field-idle'))
  await user.type(screen.getByTestId('caffeinate-field-timer'), '5')
  await user.click(screen.getByTestId('caffeinate-start-button'))

  expect(screen.queryByTestId('caffeinate-dialog')).not.toBeInTheDocument()
  expect(window.__fakeApi?.caffeinateStarts()).toEqual([
    {
      preventDisplaySleep: true,
      preventIdleSleep: false,
      preventDiskSleep: false,
      preventSystemSleep: true,
      declareUserActive: false,
      timerSeconds: 300
    }
  ])
  // The fake's start() flips running synchronously; the button reflects it
  // with no separate emit needed, same as clicking Decaf reflects a stop.
  expect(screen.getByTestId('caffeinate-decaf-button')).toBeInTheDocument()
})

test('leaving the timer empty means "run until Decaf" — no timerSeconds at all', async () => {
  renderApp()
  const user = userEvent.setup()
  act(() => {
    window.__fakeApi?.fireCaffeinateOpenDialog()
  })
  await screen.findByTestId('caffeinate-dialog')

  await user.click(screen.getByTestId('caffeinate-start-button'))

  const [flags] = window.__fakeApi?.caffeinateStarts() ?? []
  expect(flags).not.toHaveProperty('timerSeconds')
})

test('Cancel and Escape both dismiss the dialog without starting anything', async () => {
  renderApp()
  const user = userEvent.setup()

  act(() => {
    window.__fakeApi?.fireCaffeinateOpenDialog()
  })
  await screen.findByTestId('caffeinate-dialog')
  await user.click(screen.getByTestId('caffeinate-cancel-button'))
  expect(screen.queryByTestId('caffeinate-dialog')).not.toBeInTheDocument()

  act(() => {
    window.__fakeApi?.fireCaffeinateOpenDialog()
  })
  await screen.findByTestId('caffeinate-dialog')
  await user.keyboard('{Escape}')
  expect(screen.queryByTestId('caffeinate-dialog')).not.toBeInTheDocument()

  expect(window.__fakeApi?.caffeinateStarts()).toEqual([])
})
