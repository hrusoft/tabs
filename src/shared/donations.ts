/**
 * The About window's donation offer: three fixed tiers and two crypto
 * addresses.
 *
 * ┌─ Why Stripe Payment Links ─────────────────────────────────────────────┐
 *
 * The binding requirement is one *direct link per fixed amount*, and that is
 * what separates the candidates far more than their fees do:
 *
 *   Stripe Payment Links  no platform cut; one link per fixed price, natively
 *   Ko-fi                 0% on one-time tips, but no `?amount=` parameter —
 *                         three preset amounts means three shop items, which
 *                         reads as a purchase rather than a tip
 *   GitHub Sponsors       0% (GitHub absorbs processing) and `?frequency=
 *                         one-time&amount=N` works, but it is framed for open
 *                         source maintainers and Tabs is proprietary
 *   Buy Me a Coffee       5% of every transaction with no tier that removes
 *                         it, and an "N coffees × unit price" model that does
 *                         not deep-link a specific total cleanly
 *
 * Stripe's own processing, for a Canadian account: 2.9% + CA$0.30 on domestic
 * cards, +0.8% for international cards, +2% when currency conversion is
 * required. Payment Links themselves add nothing.
 *
 * Two consequences worth knowing before changing the numbers below. The fixed
 * CA$0.30 dominates a small tip — it is ~10% of the coffee tier and ~0.2% of
 * the top one — so lowering the entry tier costs proportionally more than it
 * looks. And the conversion fee applies whenever the tiers are priced in
 * something other than the payout currency, which is why DONATION_CURRENCY
 * exists as a constant rather than being spelled into each label: the tier
 * amounts, the currency they are collected in, and the currency the UI claims
 * all have to move together.
 *
 * └────────────────────────────────────────────────────────────────────────┘
 *
 * The values themselves are not here. Every Payment Link and receiving
 * address lives in app.config.ts at the repo root, because they fail
 * differently from the rest of this module: a wrong one is invisible, renders
 * perfectly and sends the money to a stranger. This file owns the structure,
 * the copy and the reasoning — all of it safe to edit — and reads the money
 * out of that one small file, which agents are denied write access to (see
 * .claude/settings.json).
 */

import { appConfig } from '../../app.config'

/**
 * The currency shown beside each tier — and it must be the currency the
 * Payment Links in app.config.ts are actually priced in. Nothing can check
 * that: the label is a string here and the price lives in Stripe, so a
 * mismatch renders perfectly and only shows up when a donor clicks "$4 USD"
 * and lands on a page asking for CA$4.
 *
 * USD against a Canadian payout account also means Stripe converts on every
 * donation, at the 2% noted above — roughly 8¢ on the coffee tier. That is a
 * knowing trade for pricing in the currency most donors think in, not an
 * oversight: pricing in the payout currency is what avoids the fee.
 */
export const DONATION_CURRENCY = 'USD'

export interface DonationTier {
  /** Stable id — the test id suffix, and the React key. */
  id: string
  /** The tier's name, as shown on its button. */
  label: string
  /** The bit of flavor text under the label. */
  flavor: string
  /** Whole units of DONATION_CURRENCY. */
  amount: number
  /** The tier's own Stripe Payment Link, opened via appWindow.openExternal. */
  url: string
}

/**
 * The three tiers. Amounts, names and flavor text are ordinary copy; each
 * `url` is read out of app.config.ts by tier id, so renaming a tier here
 * without renaming its key there is a compile error rather than a tier that
 * silently links nowhere.
 */
export const DONATION_TIERS: readonly DonationTier[] = [
  {
    id: 'coffee',
    label: 'Coffee',
    flavor: 'One cup, one bug fixed. Roughly.',
    amount: 4,
    url: appConfig.donations.paymentLinks.coffee
  },
  {
    id: 'beans',
    label: 'A pack of roasted beans',
    flavor: 'Enough to get through a whole feature.',
    amount: 20,
    url: appConfig.donations.paymentLinks.beans
  },
  {
    id: 'grinder',
    label: "I'm rich, I'll buy you a nice grinder",
    flavor: 'Burr, not blade. You have excellent taste.',
    amount: 200,
    url: appConfig.donations.paymentLinks.grinder
  }
] as const

export interface CryptoAddress {
  /** Stable id — the test id suffix, and the React key. */
  id: string
  /** Ticker, as shown in the UI. */
  symbol: string
  /** Full chain name, so the ticker is never the only label. */
  label: string
  /** The receiving address, copied via appWindow.copyText. */
  address: string
}

/**
 * The chains offered. Names are copy; each `address` is read out of
 * app.config.ts by chain id, on the same terms as the tier links above.
 */
export const CRYPTO_ADDRESSES: readonly CryptoAddress[] = [
  {
    id: 'btc',
    symbol: 'BTC',
    label: 'Bitcoin',
    address: appConfig.donations.cryptoAddresses.btc
  },
  {
    id: 'eth',
    symbol: 'ETH',
    label: 'Ethereum',
    address: appConfig.donations.cryptoAddresses.eth
  }
] as const

/** The tier's amount as it appears on screen, e.g. `$4 CAD`. */
export function formatDonationAmount(tier: DonationTier): string {
  return `$${tier.amount} ${DONATION_CURRENCY}`
}
