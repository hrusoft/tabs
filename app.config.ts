/**
 * ┌───────────────────────────────────────────────────────────────────────┐
 * │  EVERY VALUE IN THIS FILE DECIDES WHERE SOMEONE'S MONEY GOES.         │
 * │  Do not edit it in passing, and do not let an agent edit it for you.  │
 * └───────────────────────────────────────────────────────────────────────┘
 *
 * The operator's own configuration, kept apart from the code that renders it
 * (src/shared/donations.ts holds the tier structure, the copy and the
 * platform research; this holds only the values that have to be *right*).
 *
 * The separation exists because these values fail differently from everything
 * else in the repo. A wrong colour is visible. A wrong layout is visible. A
 * wrong receiving address is **invisible** — the About window renders it
 * perfectly, the copy button works perfectly, and the money goes to a
 * stranger, irreversibly, with nothing anywhere reporting a problem. No test
 * can tell a correct address from an incorrect one; only the person who owns
 * the wallet can. So the defence is to make this file small, obvious, and
 * rarely touched, rather than to try to validate it.
 *
 * Nothing here is a secret. A receiving address and a Payment Link are both
 * meant to be handed out — they are printed in the shipped app. The risk is
 * integrity, not disclosure, which is why this file is committed in the clear
 * rather than gitignored or encrypted: hiding it would protect nothing and
 * would only make a silent change harder to spot in review.
 *
 * Agents are denied Edit and Write on this path (see .claude/settings.json).
 * That is a guard rail, not a wall — it cannot stop a shell command, and it
 * cannot stop a human. Treat any diff touching this file as needing the same
 * care as sending the money by hand.
 *
 * ── Replacing the placeholders ──
 *
 * Payment Links: create one per amount in the Stripe dashboard (Payments →
 * Payment Links), priced in DONATION_CURRENCY (src/shared/donations.ts), and
 * paste each below. A real one looks like `https://buy.stripe.com/<opaque id>`.
 *
 * Crypto: paste receiving addresses from wallets whose keys you control. Send
 * a trivial amount to each and confirm it arrives *before* shipping a build —
 * that round trip is the only real verification that exists for these.
 */
export const appConfig = {
  donations: {
    /**
     * Keyed by donation tier id — see DONATION_TIERS in
     * src/shared/donations.ts, which reads each by name, so a key renamed
     * here is a compile error there rather than a silently missing link.
     */
    paymentLinks: {
      coffee: 'https://donate.stripe.com/test_cNicMY4x3gvJ2cY8tmcIE00',
      beans: 'https://donate.stripe.com/test_4gMfZa3sZ0wLeZK7picIE01',
      grinder: 'https://donate.stripe.com/test_8x26oAd3zdjxg3O5hacIE02'
    },
    /**
     * Keyed by chain id, read the same way. The placeholders are not valid
     * addresses on either chain — deliberately, so a wallet refuses them
     * rather than a transaction succeeding into nothing.
     */
    cryptoAddresses: {
      btc: 'bc1qfj8yps3equmypd6kzlje8knxdhnw7pe8psqk50',
      eth: '0x022A23E510e6d5Cd5e2F2F7cEf6A1f19Da57Ac43'
    }
  }
} as const
