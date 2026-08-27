import { existsSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { PLUGIN_PACKAGES } from '../../../plugins/index'
import { CONTENT_CONTROL_REQUEST_MARKER } from '../../content/externalControl'
import { CONTENT_TYPE_MANIFESTS, type PluginEntryKind } from '../../content/registry'

/**
 * The manifest reconciliation gate: everything a package *declares* agrees
 * with everything that *exists* — the list, the folders, the entry files and
 * the wire protocol. The census and the entry resolver throw the same
 * mismatches at module evaluation (a refused boot with a readable message);
 * this runs the checks against the filesystem in the unit tier, so a mismatch
 * fails `npm test` before it can fail a launch — and covers the one direction
 * a boot cannot see, an entry file on disk for a boundary whose glob never
 * runs in that process.
 *
 * Together with the coverage gates this closes the loop three ways for verbs:
 * the manifests' declared union must equal the content half of the wire
 * protocol (here), the renderer must answer every protocol verb once
 * activated (content/__tests__/externalControlVerbs.test.tsx), and main must
 * claim them all before the socket opens (the unhandledMainControlVerbs e2e
 * gate). Declared ⇔ typed ⇔ registered, with the odd one out named.
 */

const root = path.resolve(import.meta.dirname, '../../../..')
const pluginsDir = path.join(root, 'src/plugins')

/** Where each declarable entry kind lives inside a package. */
const ENTRY_FILES: Record<PluginEntryKind, string> = {
  main: 'main/index.ts',
  renderer: 'renderer/index.ts',
  settings: 'settings/index.ts',
  testing: 'testing/fakeApi.ts'
}

const ENTRY_KINDS = Object.keys(ENTRY_FILES) as PluginEntryKind[]

describe('plugin manifest reconciliation', () => {
  it('PLUGIN_PACKAGES and the src/plugins/ folders agree in both directions', () => {
    const folders = readdirSync(pluginsDir).filter((name) =>
      statSync(path.join(pluginsDir, name)).isDirectory()
    )
    expect([...folders].sort()).toEqual([...PLUGIN_PACKAGES].sort())
  })

  it('every package ships a manifest whose type is its folder name', () => {
    // The census already threw before this test could run if not — what this
    // adds is the readable failure listing, and the premise the rest of the
    // file builds on.
    expect(CONTENT_TYPE_MANIFESTS.map((manifest) => manifest.type)).toEqual([...PLUGIN_PACKAGES])
  })

  it('declared entries and entry files on disk agree, in both directions, for every package', () => {
    const mismatches: string[] = []
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      for (const kind of ENTRY_KINDS) {
        const declared = manifest.entries.includes(kind)
        const file = path.join(pluginsDir, manifest.type, ENTRY_FILES[kind])
        const exists = existsSync(file)
        if (declared && !exists) {
          mismatches.push(
            `${manifest.type}: declares "${kind}" but ${ENTRY_FILES[kind]} is missing`
          )
        }
        if (!declared && exists) {
          mismatches.push(
            `${manifest.type}: ships ${ENTRY_FILES[kind]} but does not declare "${kind}"`
          )
        }
      }
    }
    expect(mismatches).toEqual([])
  })

  it('a settings descriptor and a settings entry come together or not at all', () => {
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      expect(
        manifest.entries.includes('settings'),
        `${manifest.type}: a package declares settings (the descriptor) iff it ships the Settings-window page`
      ).toBe(manifest.settings !== undefined)
    }
  })

  it('the declared control verbs are exactly the content half of the wire protocol', () => {
    const declared = CONTENT_TYPE_MANIFESTS.flatMap((manifest) => manifest.controlVerbs ?? [])
    // No verb declared twice across packages — one owner per verb name is the
    // registries' rule, enforced here before either registry can throw.
    expect(new Set(declared).size).toBe(declared.length)
    expect([...declared].sort()).toEqual(Object.keys(CONTENT_CONTROL_REQUEST_MARKER).sort())
  })
})
