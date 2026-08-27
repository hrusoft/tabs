import { ATTRIBUTIONS, RUNTIME_COMPONENTS } from '@shared/attributions'
import { CRYPTO_ADDRESSES, DONATION_TIERS, formatDonationAmount } from '@shared/donations'
import { useEffect, useRef, useState } from 'react'
import appIcon from '../../../../resources/icon.png'
import './about.css'

/**
 * The About window's whole tree (see createAboutWindow in
 * src/main/windows.ts): who made the app, what it is built on, and how to
 * support it.
 *
 * The attributions half is a license obligation rather than a courtesy — Tabs
 * ships proprietary while everything under it is MIT or BSD, whose one
 * substantive condition is that the notice travels with the binary. What goes
 * in the list is not decided here: it comes from @shared/attributions, which a
 * test reconciles against package.json so a new dependency cannot ship
 * uncredited.
 *
 * Nothing on this page is a link element. Every outbound URL goes through
 * `appWindow.openExternal`, which hands it to the OS browser after main vets
 * the protocol (see openExternalUrl in src/main/openExternal.ts). An `<a
 * href>` would navigate *this* window instead — replacing the About page with
 * a web page inside a chromeless, non-resizable window the user cannot
 * navigate back out of.
 *
 * Like the Settings window it draws its own title bar, since both hide the
 * native one (see `hiddenTitleBar` in windows.ts); `.about-titlebar` is
 * `.settings-titlebar`'s twin so the three windows read as one app.
 */
export function AboutWindow() {
  const info = useAppInfo()
  return (
    <div className="about-shell">
      <header className="about-titlebar" data-testid="about-titlebar">
        About
      </header>
      <div className="about-body" data-testid="about-window">
        <section className="about-identity">
          {/* Decorative: the app's name is stated in the <h1> directly below,
              so announcing the icon too would just repeat it. */}
          <img className="about-icon" src={appIcon} alt="" width={72} height={72} />
          <h1 className="about-name">Tabs</h1>
          <p className="about-version" data-testid="about-version">
            Version {info.version}
          </p>
          {/* Echoes README.md's own opening line rather than inventing a
              second description, so the two cannot drift into describing
              different products. Terminal-only on purpose: the other content
              types are experimental and this is the app's front door. */}
          <p className="about-tagline">A fancy terminal with tabs, splits, and nested layouts.</p>
          <p className="about-copyright">Copyright © 2026 Hrusoft. All rights reserved.</p>
        </section>

        {/* Support first, credits last. The credit list is fourteen rows of
            reference material nobody scrolls *to*, and putting it above the
            donation ask pushed that ask entirely below the fold of a window
            that does not resize. Acknowledgements at the bottom is also where
            every other About window puts them. */}
        <DonationsSection />
        <CryptoSection />
        <AttributionsSection info={info} />
      </div>
    </div>
  )
}

/**
 * The app's version and the runtimes under it, read once at mount.
 *
 * `getAppInfoSync` is synchronous for the same reason the layout and settings
 * reads are — it feeds the first painted frame — but unlike those it is not
 * store-backed, because none of it can change while the window is open: a
 * version bump means a new build. Read in state rather than at module scope so
 * the jsdom tier can re-seed the fake bridge between tests.
 */
function useAppInfo() {
  const [info] = useState(() => window.api.appWindow.getAppInfoSync())
  return info
}

function AttributionsSection({ info }: { info: ReturnType<typeof useAppInfo> }) {
  return (
    <section className="about-section" data-testid="about-attributions">
      <h2 className="about-section-title">Built with</h2>
      <p className="about-section-desc">
        Tabs stands on these projects. Each is used under its own license, with my thanks to the
        maintainers who keep them going.
      </p>
      <ul className="about-credits">
        {RUNTIME_COMPONENTS.map((component) => (
          <li className="about-credit" key={component.name}>
            <button
              type="button"
              className="about-credit-name"
              data-testid={`about-credit-${component.name}`}
              onClick={() => window.api.appWindow.openExternal(component.url)}
            >
              {component.name}
            </button>
            <span className="about-credit-version">{info[component.versionKey]}</span>
            <span className="about-credit-license">{component.license}</span>
          </li>
        ))}
        {ATTRIBUTIONS.map((entry) => (
          <li className="about-credit" key={entry.name}>
            <button
              type="button"
              className="about-credit-name"
              data-testid={`about-credit-${entry.name}`}
              onClick={() => window.api.appWindow.openExternal(entry.url)}
            >
              {entry.name}
            </button>
            <span className="about-credit-license">{entry.license}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}

function DonationsSection() {
  return (
    <section className="about-section" data-testid="about-donations">
      <h2 className="about-section-title">Buy me a coffee</h2>
      <p className="about-section-desc">
        Like this app? You can buy me a coffee to fuel future development.
      </p>
      <div className="about-tiers">
        {DONATION_TIERS.map((tier) => (
          <button
            type="button"
            className="about-tier"
            key={tier.id}
            data-testid={`about-tier-${tier.id}`}
            onClick={() => window.api.appWindow.openExternal(tier.url)}
          >
            <span className="about-tier-amount">{formatDonationAmount(tier)}</span>
            <span className="about-tier-label">{tier.label}</span>
            <span className="about-tier-flavor">{tier.flavor}</span>
          </button>
        ))}
      </div>
    </section>
  )
}

function CryptoSection() {
  return (
    <section className="about-section" data-testid="about-crypto">
      <h2 className="about-section-title">Or in crypto</h2>
      <p className="about-section-desc">
        Same idea, no card involved. Copy an address and send whatever you like.
      </p>
      <ul className="about-addresses">
        {CRYPTO_ADDRESSES.map((entry) => (
          <li className="about-address" key={entry.id}>
            <span className="about-address-label">
              {entry.label} <span className="about-address-symbol">{entry.symbol}</span>
            </span>
            <code className="about-address-value" data-testid={`about-address-${entry.id}`}>
              {entry.address}
            </code>
            <CopyButton
              text={entry.address}
              testId={`about-copy-${entry.id}`}
              label={`Copy ${entry.label} address`}
            />
          </li>
        ))}
      </ul>
    </section>
  )
}

/**
 * A copy button that says so for a moment after being pressed.
 *
 * The confirmation is the whole point: `copyText` is fire-and-forget across
 * the bridge (main writes the clipboard — see AppWindowApi.copyText), so
 * nothing comes back to render, and a button that looks identical before and
 * after leaves the user unsure whether a long unreadable string was actually
 * taken. The timer is cleared on unmount so a press immediately before the
 * window closes can't set state on a gone component.
 */
function CopyButton({ text, testId, label }: { text: string; testId: string; label: string }) {
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(
    () => () => {
      if (timer.current !== null) clearTimeout(timer.current)
    },
    []
  )

  return (
    <button
      type="button"
      className="about-copy"
      data-testid={testId}
      aria-label={label}
      data-copied={copied || undefined}
      onClick={() => {
        window.api.appWindow.copyText(text)
        setCopied(true)
        if (timer.current !== null) clearTimeout(timer.current)
        timer.current = setTimeout(() => setCopied(false), 1500)
      }}
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  )
}
