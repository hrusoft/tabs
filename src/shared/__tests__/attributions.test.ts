import { readFileSync } from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { ATTRIBUTIONS, RUNTIME_COMPONENTS } from '../attributions'
import { CRYPTO_ADDRESSES, DONATION_TIERS } from '../donations'
import { isSafeExternalUrl } from '../url'

/**
 * The attributions reconciliation gate — the mechanism behind "should be easy
 * to keep up to date as dependencies change" (issue #3).
 *
 * Attributing a dependency is a license obligation (see attributions.ts), and
 * the failure mode it guards is silent by nature: adding a package is a normal
 * day's work, nothing about it prompts you to also credit it, and nobody
 * notices the missing notice until it matters legally. So the list is
 * reconciled against package.json here rather than trusted to memory — in both
 * directions, since a stale entry crediting something the app no longer ships
 * is its own (smaller) kind of wrong.
 *
 * Same idea as plugin/__tests__/manifestReconciliation.test.ts: declare once,
 * let a test name the mismatch.
 */

const root = path.resolve(import.meta.dirname, '../../..')

interface PackageJson {
  dependencies?: Record<string, string>
  devDependencies?: Record<string, string>
}

const packageJson = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')) as PackageJson

/**
 * devDependencies that nonetheless ship inside the built app, so "is it in
 * `dependencies`?" is the wrong question to reconcile against.
 *
 * Every one of these is bundled rather than resolved at runtime — vite inlines
 * the renderer's React/zustand/react-resizable-panels into the entry chunks and
 * electron-vite inlines @electron-toolkit/utils into main, while `electron` is
 * the runtime the whole thing executes in. They live in devDependencies
 * because nothing needs to `npm install` them beside the app, not because they
 * are absent from it.
 *
 * Adding a bundled dependency means adding it here as well as to ATTRIBUTIONS.
 * That is the one manual step this gate cannot take for you — deriving it
 * would mean parsing the built bundles, which is fragile in exactly the
 * direction that matters (a miss reads as "nothing to credit").
 */
const BUNDLED_DEV_DEPENDENCIES = [
  '@electron-toolkit/utils',
  'electron',
  'react',
  'react-dom',
  'react-resizable-panels',
  'zustand'
]

/** Every npm package that ends up inside the shipped app. */
function shippedPackages(): string[] {
  return [...Object.keys(packageJson.dependencies ?? {}), ...BUNDLED_DEV_DEPENDENCIES].sort()
}

/**
 * Every npm package name the About window credits — the plain list, plus the
 * runtime entries that double as a package's credit (Electron). Without that
 * second half, crediting a package under RUNTIME_COMPONENTS would read here
 * as not crediting it at all.
 */
function attributedPackages(): string[] {
  return [
    ...ATTRIBUTIONS.map((entry) => entry.name),
    ...RUNTIME_COMPONENTS.flatMap((component) =>
      component.packageName === undefined ? [] : [component.packageName]
    )
  ].sort()
}

describe('attributions', () => {
  it('credits exactly the npm packages that ship in the app', () => {
    const attributed = attributedPackages()
    // One assertion rather than two set-difference checks: a diff of the two
    // sorted lists names the offender in both directions at once, and reads
    // as "here is what it should be" rather than "here is a count".
    expect(attributed).toEqual(shippedPackages())
  })

  it('lists every bundled devDependency under a name package.json actually has', () => {
    // Guards the manual half above: a renamed or dropped devDependency would
    // otherwise sit in BUNDLED_DEV_DEPENDENCIES forever, keeping a stale
    // ATTRIBUTIONS entry green.
    const declared = Object.keys(packageJson.devDependencies ?? {})
    for (const name of BUNDLED_DEV_DEPENDENCIES) {
      expect(declared, `${name} is no longer a devDependency — update this list`).toContain(name)
    }
  })

  it('names no package twice', () => {
    // Across both lists, not just within ATTRIBUTIONS: crediting `electron`
    // in each printed it twice in the window, which is the mistake this
    // guards rather than a hypothetical one.
    const names = attributedPackages()
    expect(new Set(names).size).toBe(names.length)
  })

  it('gives every entry a license and a reachable-looking URL', () => {
    for (const entry of [...ATTRIBUTIONS, ...RUNTIME_COMPONENTS]) {
      expect(entry.license, `${entry.name} has no license`).not.toBe('')
      // Not decoration: the About window hands these to
      // appWindow.openExternal, which silently drops anything that isn't
      // http(s)/mailto (see openExternal.ts) — so a bad URL here is a link
      // that does nothing at all rather than one that errors.
      expect(isSafeExternalUrl(entry.url), `${entry.name}: ${entry.url}`).toBe(true)
    }
  })

  it('reads each runtime version off a distinct process.versions field', () => {
    const keys = RUNTIME_COMPONENTS.map((component) => component.versionKey)
    expect(new Set(keys).size, 'two runtimes share a version field').toBe(keys.length)
    // That each key is one process.versions actually *has* can only be
    // checked where those versions exist: this tier runs in plain Node, which
    // has `node` but neither `electron` nor `chrome`. e2e/about.spec.ts
    // asserts the rendered versions against the real Electron process.
  })
})

describe('donations', () => {
  it('offers the three tiers, cheapest first', () => {
    const amounts = DONATION_TIERS.map((tier) => tier.amount)
    expect(amounts).toEqual([4, 20, 200])
  })

  it('gives every tier a distinct id and its own link', () => {
    const ids = DONATION_TIERS.map((tier) => tier.id)
    expect(new Set(ids).size).toBe(ids.length)
    const urls = DONATION_TIERS.map((tier) => tier.url)
    expect(new Set(urls).size, 'two tiers share a payment link').toBe(urls.length)
  })

  it('keeps every tier link openable', () => {
    // The placeholders below are https URLs precisely so this stays honest
    // once they are replaced: the check that survives the replacement is the
    // one worth having, since a mistyped real link fails silently otherwise.
    for (const tier of DONATION_TIERS) {
      expect(isSafeExternalUrl(tier.url), `${tier.id}: ${tier.url}`).toBe(true)
    }
  })

  it('gives every crypto address a distinct id and a non-empty value', () => {
    const ids = CRYPTO_ADDRESSES.map((entry) => entry.id)
    expect(new Set(ids).size).toBe(ids.length)
    for (const entry of CRYPTO_ADDRESSES) {
      expect(entry.address.trim(), `${entry.id} has no address`).not.toBe('')
    }
  })
})
