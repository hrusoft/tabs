import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { PLUGIN_PACKAGES } from '../../../plugins/index'
import { CONTENT_TYPE_MANIFESTS, type PluginEntryKind } from '../../content/registry'
import { ALL_CONTROL_VERB_SPECS } from '../../controlSpecRegistry'

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
 * Together with the coverage gates this closes the loop for verbs: the
 * manifests' declared names are unique across the whole census (here), each
 * package's own request union stays exhaustive against its own verb table at
 * compile time (`MainControlVerbTable<FooRequest>`,
 * `RendererControlVerbTable<FooRequest>` — there is no longer a hand-written
 * cross-package union to compare declared names against; TypeScript cannot
 * glob types, which is why `CONTROL_REQUEST_TYPES` is now read from this same
 * census at runtime instead), the renderer must answer every protocol verb
 * once activated (content/__tests__/externalControlVerbs.test.tsx), and main
 * must claim them all before the socket opens (the unhandledMainControlVerbs
 * e2e gate).
 */

const root = path.resolve(import.meta.dirname, '../../../..')
const packagesDir = path.join(root, 'packages')

/** A content-type package's own folder — `packages/plugin-<name>/`. */
const packageDir = (name: string): string => path.join(packagesDir, `plugin-${name}`)

/** Where each declarable entry kind lives inside a package. */
const ENTRY_FILES: Record<PluginEntryKind, string> = {
  main: 'main/index.ts',
  renderer: 'renderer/index.ts',
  settings: 'settings/index.ts',
  testing: 'testing/fakeApi.ts'
}

const ENTRY_KINDS = Object.keys(ENTRY_FILES) as PluginEntryKind[]

describe('plugin manifest reconciliation', () => {
  it('PLUGIN_PACKAGES and the packages/plugin-<name>/ folders agree in both directions', () => {
    // packages/plugin-sdk is the SDK every package depends on, not a content
    // type, so it is the one plugin-* folder the list does not name.
    const folders = readdirSync(packagesDir)
      .filter((name) => name.startsWith('plugin-') && name !== 'plugin-sdk')
      .filter((name) => statSync(path.join(packagesDir, name)).isDirectory())
      .map((name) => name.slice('plugin-'.length))
    expect([...folders].sort()).toEqual([...PLUGIN_PACKAGES].sort())
  })

  it('src/plugins/ holds only the names list — no package lives there any more', () => {
    // Every discovery glob looks under packages/ only, so a package folder
    // left (or re-created) under src/plugins/ would not ship and nothing else
    // would say so: the census never sees it, and its entries are never
    // activated.
    expect(readdirSync(path.join(root, 'src/plugins'))).toEqual(['index.ts'])
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
        const file = path.join(packageDir(manifest.type), ENTRY_FILES[kind])
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

  it('every package that declares control verbs also ships a guide', () => {
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      if (!manifest.controlVerbs || manifest.controlVerbs.length === 0) continue
      expect(
        manifest.guide,
        `${manifest.type}: declares control verbs but no guide — describe would answer with nothing to say how to use them`
      ).toMatch(/\S/)
    }
  })

  it('no two packages declare the same control verb', () => {
    // One owner per verb name is the registries' own rule (both throw on a
    // duplicate); this catches it before either registry runs, with every
    // colliding name named rather than just the first one found.
    const seen = new Map<string, string>()
    const collisions: string[] = []
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      for (const spec of manifest.controlVerbs ?? []) {
        const owner = seen.get(spec.verb)
        if (owner) collisions.push(`"${spec.verb}" declared by both ${owner} and ${manifest.type}`)
        else seen.set(spec.verb, manifest.type)
      }
    }
    expect(collisions).toEqual([])
  })

  /**
   * `ALL_CONTROL_VERB_SPECS` is core's own six plus every package's declared
   * specs (src/shared/controlSpecRegistry.ts) — process-agnostic, so this
   * checks core and every plugin together without importing Electron, unlike
   * the e2e `unhandledMainControlVerbs` gate (which needs a running app) or
   * the jsdom coverage gate (which needs a mounted renderer).
   */
  describe('control verb spec integrity', () => {
    it('names every verb and every CLI command exactly once', () => {
      const verbs = ALL_CONTROL_VERB_SPECS.map((spec) => spec.verb)
      const commands = ALL_CONTROL_VERB_SPECS.map((spec) => spec.command)
      expect(new Set(verbs).size).toBe(verbs.length)
      expect(new Set(commands).size).toBe(commands.length)
    })

    it('has a self-consistent wire schema for every verb', () => {
      for (const spec of ALL_CONTROL_VERB_SPECS) {
        expect(spec.wire.properties?.type, `${spec.verb}: wire.properties.type`).toEqual({
          const: spec.verb
        })
        // The app fills paneId in from the caller's environment — a schema
        // that named it would let a caller forge whose pane a request is
        // from.
        expect(
          Object.keys(spec.wire.properties ?? {}),
          `${spec.verb}: wire.properties must not include paneId`
        ).not.toContain('paneId')
        for (const field of spec.wire.required ?? []) {
          expect(
            Object.keys(spec.wire.properties ?? {}),
            `${spec.verb}: requires "${field}" but does not declare it in properties`
          ).toContain(field)
        }
      }
    })
  })
})

/**
 * The typecheck wiring's one hand-kept list: tsconfig references cannot glob,
 * so the solution (tsconfig.json) and the two core projects name every
 * workspace package's composite projects by hand. A project missing from
 * them is not an error anywhere else — `tsc -b` simply never builds it, and
 * that package's code silently stops being typechecked — so this is where a
 * forgotten reference fails, naming it.
 */
describe('typecheck project references', () => {
  /**
   * A root tsconfig's `references`, repo-relative. tsconfig is JSONC, so this
   * drops whole-line `//` comments (the only kind these files use) and the
   * trailing commas tsc also accepts.
   */
  function referencesOf(file: string): string[] {
    const text = readFileSync(path.join(root, file), 'utf8')
      .split('\n')
      .filter((line) => !line.trim().startsWith('//'))
      .join('\n')
      .replace(/,(\s*[}\]])/g, '$1')
    let config: { references?: { path: string }[] }
    try {
      config = JSON.parse(text) as typeof config
    } catch (error) {
      throw new Error(
        `${file} no longer parses once whole-line comments are stripped — this test reads it with a deliberately simple parser (TypeScript 7 ships no JS config reader); keep its comments on their own lines (${String(error)})`
      )
    }
    return (config.references ?? []).map((ref) => path.normalize(ref.path))
  }

  /** Every workspace package's projects for the given layers, repo-relative. */
  function packageProjects(layers: string[]): string[] {
    return readdirSync(packagesDir)
      .filter((name) => existsSync(path.join(packagesDir, name, 'package.json')))
      .flatMap((name) => layers.map((layer) => path.join('packages', name, layer)))
      .filter((dir) => existsSync(path.join(root, dir, 'tsconfig.json')))
  }

  it('the solution references every package project and both core projects', () => {
    expect(referencesOf('tsconfig.json').sort()).toEqual(
      [
        ...packageProjects(['shared', 'main', 'renderer']),
        'tsconfig.node.json',
        'tsconfig.web.json'
      ].sort()
    )
  })

  it("core's node project references every package's shared and main projects", () => {
    expect(referencesOf('tsconfig.node.json').sort()).toEqual(
      packageProjects(['shared', 'main']).sort()
    )
  })

  it("core's web project references every package's shared and renderer projects", () => {
    expect(referencesOf('tsconfig.web.json').sort()).toEqual(
      packageProjects(['shared', 'renderer']).sort()
    )
  })

  it('every package has all three projects', () => {
    const missing = readdirSync(packagesDir)
      .filter((name) => existsSync(path.join(packagesDir, name, 'package.json')))
      .flatMap((name) =>
        ['shared', 'main', 'renderer']
          .map((layer) => path.join('packages', name, layer, 'tsconfig.json'))
          .filter((file) => !existsSync(path.join(root, file)))
      )
    expect(missing).toEqual([])
  })
})
