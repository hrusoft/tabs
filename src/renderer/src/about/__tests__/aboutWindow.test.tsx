import { ATTRIBUTIONS, RUNTIME_COMPONENTS } from '@shared/attributions'
import { CRYPTO_ADDRESSES, DONATION_TIERS } from '@shared/donations'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, expect, test } from 'vitest'
import { AboutWindow } from '../AboutWindow'

/**
 * The About window's behaviour over the fake bridge. Mounted directly, like
 * the Settings pages — it is its own entry point (about-main.tsx) and there
 * is no `renderApp` equivalent to reach it through.
 *
 * What this tier can hold honest is the wiring: that every credit, tier and
 * address in the shared data reaches the screen, and that pressing one sends
 * the right value across the bridge. What it cannot see is the window itself
 * — that it opens from the menu at all, that its stylesheet loaded, that the
 * clipboard really received the text — all of which lives in
 * e2e/about.spec.ts against real Electron.
 */

beforeEach(() => {
  window.__fakeApi?.reset()
})

/** URLs the app handed to appWindow.openExternal, in order. */
function opened(): string[] {
  return window.__fakeApi?.openedExternalUrls() ?? []
}

test('shows the app identity, using the version the bridge reports', () => {
  render(<AboutWindow />)

  expect(screen.getByRole('heading', { level: 1, name: 'Tabs' })).toBeInTheDocument()
  // The fake's fixed answer, so this asserts the window renders what it was
  // given rather than whatever the test host happens to be running.
  expect(screen.getByTestId('about-version')).toHaveTextContent('Version 0.0.0-test')
  expect(screen.getByText(/Copyright © 2026 Hrusoft/)).toBeInTheDocument()
})

test('credits every shipped package and every runtime', () => {
  render(<AboutWindow />)

  // Not vacuous — the reconciled list really does have entries.
  expect(ATTRIBUTIONS.length).toBeGreaterThan(0)
  for (const entry of ATTRIBUTIONS) {
    expect(screen.getByTestId(`about-credit-${entry.name}`)).toHaveTextContent(entry.name)
  }
  for (const component of RUNTIME_COMPONENTS) {
    expect(screen.getByTestId(`about-credit-${component.name}`)).toBeInTheDocument()
  }
  // A license beside each is the whole point of the section: an uncredited
  // license is the compliance failure this window exists to prevent.
  for (const entry of ATTRIBUTIONS) {
    expect(screen.getByTestId(`about-credit-${entry.name}`).parentElement).toHaveTextContent(
      entry.license
    )
  }
})

test('shows each runtime with the version the bridge reported for it', () => {
  render(<AboutWindow />)

  for (const component of RUNTIME_COMPONENTS) {
    // '0.0.0' for all three from the fake — what matters is that the value is
    // read from `info[versionKey]` rather than restated in the component.
    expect(screen.getByTestId(`about-credit-${component.name}`).parentElement).toHaveTextContent(
      '0.0.0'
    )
  }
})

test('opens a credit through the bridge rather than navigating the window', async () => {
  const user = userEvent.setup()
  render(<AboutWindow />)

  const entry = ATTRIBUTIONS[0]!
  await user.click(screen.getByTestId(`about-credit-${entry.name}`))

  expect(opened()).toEqual([entry.url])
})

test('offers the three tiers with their amounts and flavor text', () => {
  render(<AboutWindow />)

  expect(screen.getByText(/buy me a coffee to fuel future development/i)).toBeInTheDocument()
  for (const tier of DONATION_TIERS) {
    const button = screen.getByTestId(`about-tier-${tier.id}`)
    expect(button).toHaveTextContent(tier.label)
    expect(button).toHaveTextContent(tier.flavor)
    expect(button).toHaveTextContent(`$${tier.amount}`)
  }
})

test('sends each tier its own payment link', async () => {
  const user = userEvent.setup()
  render(<AboutWindow />)

  for (const tier of DONATION_TIERS) {
    await user.click(screen.getByTestId(`about-tier-${tier.id}`))
  }

  expect(opened()).toEqual(DONATION_TIERS.map((tier) => tier.url))
})

test('shows every crypto address in full and copies it through the bridge', async () => {
  const user = userEvent.setup()
  render(<AboutWindow />)

  expect(CRYPTO_ADDRESSES.length).toBeGreaterThan(0)
  for (const entry of CRYPTO_ADDRESSES) {
    // In full, not truncated: a clipped address gives the user no way to
    // check what the copy button actually took.
    expect(screen.getByTestId(`about-address-${entry.id}`)).toHaveTextContent(entry.address)
    await user.click(screen.getByTestId(`about-copy-${entry.id}`))
  }

  expect(window.__fakeApi?.copiedText()).toEqual(CRYPTO_ADDRESSES.map((entry) => entry.address))
})

test('a copy button confirms it copied, and only for the address pressed', async () => {
  const user = userEvent.setup()
  render(<AboutWindow />)

  const [first, second] = CRYPTO_ADDRESSES
  await user.click(screen.getByTestId(`about-copy-${first!.id}`))

  expect(screen.getByTestId(`about-copy-${first!.id}`)).toHaveTextContent('Copied')
  // Each button owns its own confirmation state — a shared one would flash
  // "Copied" under an address the user never pressed.
  expect(screen.getByTestId(`about-copy-${second!.id}`)).toHaveTextContent('Copy')
})
