import { PLUGIN_PACKAGES, type PluginPackageName } from '../../plugins/index'
import type { ContentTypeSettingsDescriptor } from './settingsDescriptor'

/**
 * ## The content-type census, discovered rather than listed
 *
 * `CONTENT_TYPE_MANIFESTS` below names every content type and can be read
 * from anywhere: it depends on no DOM, no React and no Electron, so the
 * Settings window, main's settings loader and the renderer all see the same
 * records, and `CONTENT_TYPE_SETTINGS` is derived from it rather than listed
 * again.
 *
 * It is populated by globbing every package's manifest
 * (`src/plugins/<name>/shared/manifest.ts`) and ordering by `PLUGIN_PACKAGES` —
 * the one hand-written list, which owns order, intent and the literal
 * `ContentTypeId` union (src/plugins/index.ts says why those three cannot be
 * discovered). The other aggregation points do the same per import-graph
 * boundary: registerBuiltins globs renderer entries, contentTypes.ts main
 * entries, registerBuiltinPages settings entries, the fake bridge testing
 * pieces. One glob per boundary, never one glob for everything — a single
 * list holding real imports would drag xterm into the Settings window's
 * sidebar, `<webview>` into the jsdom tier and node-pty into the renderer,
 * which is the constraint this architecture has defended from the start.
 *
 * The mismatches a hand-written list turned into compile errors are runtime
 * errors here, thrown at module evaluation — before any window exists, naming
 * the package and the problem — and the reconciliation test beside the
 * boundary ledger (src/shared/plugin/__tests__/) checks the same agreements
 * against the filesystem, so a mismatch fails the unit tier before it can
 * fail a boot.
 */

/** The entry kinds a package may ship, one per import-graph boundary. `shared/` always exists (the manifest lives there). */
export type PluginEntryKind = 'main' | 'renderer' | 'settings' | 'testing'

export interface ContentTypeManifest {
  /** The content-type id: matches ContentNode.type AND the package's folder name (enforced at load). */
  type: string
  /** Human-readable name — titles panes holding this content, and labels it wherever it is listed. */
  displayName: string
  /**
   * Whether a user may turn this type off.
   *
   * Read by `togglableContentTypes()` (./enablement.ts), which is what the
   * Settings window renders a checkbox from — so a new type appears in that UI
   * with no edit there. Note this governs only what the UI *offers*: the gate
   * itself honours plain membership of `disabledContentTypes` for any type at
   * all, for the reasons enablement.ts sets out. Structural types
   * (tabs/split/empty) are layout rather than content and are absent from the
   * census entirely, which is what excludes them.
   */
  canDisable: boolean
  /**
   * Which entry files this package ships — what each boundary's glob is
   * reconciled against, in both directions: a declared entry whose file the
   * glob didn't find is an error, and so is a file nothing declared. The
   * "you registered what you declared" gate, running against
   * built-ins today.
   */
  entries: readonly PluginEntryKind[]
  /**
   * The external-control verbs this package *adds to the wire protocol* — the
   * names of its own request union, declared so the protocol surface is
   * readable off the manifest. Reconciled three ways: declared here, typed in
   * the union, answered by the activations (the reconciliation gate plus the
   * two verb-coverage gates name whichever copy drifts). Core verbs a package
   * merely answers (the browser handles four of core's) are deliberately not
   * declared — which module answers a verb is a separate question from which
   * union declares it.
   */
  controlVerbs?: readonly string[]
  /**
   * What this type contributes to the persisted Settings shape, if anything.
   * Optional: a type with no user-facing settings declares none.
   * `CONTENT_TYPE_SETTINGS` in src/shared/settings.ts is derived from these,
   * so this census stays the single source. A package that declares settings
   * must also ship a `settings` entry, and vice versa — reconciled with the
   * rest.
   */
  settings?: ContentTypeSettingsDescriptor
}

/**
 * Every content type's `type` string as a literal union — `'terminal' |
 * 'browser' | 'gitTree'`, derived from the one hand-written list rather than
 * from the globbed manifests (which arrive as `ContentTypeManifest[]` and
 * could only offer `string`).
 */
export type ContentTypeId = PluginPackageName

type ManifestModule = { manifest: ContentTypeManifest }

/**
 * The manifest modules, keyed by their glob path. Discovery exists only
 * inside Vite-built contexts — which is every context that actually runs app
 * code: electron-vite's three builds, vitest (both projects), the browser
 * harness. The one consumer of src/shared outside Vite is Playwright's own
 * transform of e2e specs, and there this file must not be reachable at all:
 * an e2e spec importing something whose graph lands here (shared/settings.ts
 * was the case that existed, via DEFAULT_SETTINGS) gets this throw at load,
 * naming the rule. That is a fence, not a limitation to engineer around —
 * the alternatives were all worse: `import.meta.glob` cannot be aliased
 * around (Vite replaces the literal call form only), Playwright's transform
 * hooks don't reach a `createRequire`'d `.ts`, and a silently-empty census
 * would turn "spec imported too much" into wrong answers three files away. A
 * spec that wants a shipped default states it as a literal — the launched
 * app under test is the real value anyway (see e2e/theme.spec.ts).
 *
 * The branch tests `import.meta.env` rather than `import.meta.glob` because
 * the glob must stay in literal call form for Vite's static replacement, and
 * the env object exists in every Vite context and in no other.
 */
function loadManifestModules(): Record<string, ManifestModule> {
  if ((import.meta as { env?: unknown }).env) {
    return import.meta.glob<ManifestModule>('../../plugins/*/shared/manifest.ts', { eager: true })
  }
  throw new Error(
    'the content-type census is only available inside Vite-built contexts; ' +
      'an e2e spec must not import modules that reach it (src/shared/settings.ts does) — ' +
      'state the value the test needs as a literal instead'
  )
}

const manifestModules = loadManifestModules()

/** The folder name a globbed manifest path belongs to — `../../plugins/<name>/shared/manifest.ts`. */
function packageNameOf(path: string): string {
  const match = /\/plugins\/([^/]+)\/shared\/manifest\.ts$/.exec(path)
  if (!match) throw new Error(`unexpected manifest glob path: ${path}`)
  return match[1]!
}

/**
 * Builds the ordered census, reconciling the glob against PLUGIN_PACKAGES in
 * both directions. Throws at module evaluation — in main that is before any
 * window exists, and the message names the package and the fix, which is the
 * closest a statically-bundled loader gets to refusing a bad install.
 */
function buildCensus(): readonly ContentTypeManifest[] {
  const byName = new Map<string, ContentTypeManifest>()
  for (const [path, module] of Object.entries(manifestModules)) {
    const name = packageNameOf(path)
    const manifest = module.manifest
    if (!manifest) {
      throw new Error(
        `content-type package "${name}" exports no \`manifest\` from shared/manifest.ts`
      )
    }
    if (manifest.type !== name) {
      throw new Error(
        `content-type package folder "src/plugins/${name}" declares type "${manifest.type}" — a package's folder name is its type id`
      )
    }
    if (!(PLUGIN_PACKAGES as readonly string[]).includes(name)) {
      throw new Error(
        `content-type package "${name}" exists under src/plugins/ but is not named in PLUGIN_PACKAGES (src/plugins/index.ts) — add it there to ship it, or remove the folder`
      )
    }
    byName.set(name, manifest)
  }
  return PLUGIN_PACKAGES.map((name) => {
    const manifest = byName.get(name)
    if (!manifest) {
      throw new Error(
        `PLUGIN_PACKAGES names "${name}" but src/plugins/${name}/shared/manifest.ts does not exist`
      )
    }
    return manifest
  })
}

/** The census consumers read — every package's manifest, in PLUGIN_PACKAGES order. */
export const CONTENT_TYPE_MANIFESTS: readonly ContentTypeManifest[] = buildCensus()

/** The manifest for `type`, or undefined for a name no package claims. */
export function manifestFor(type: string): ContentTypeManifest | undefined {
  return CONTENT_TYPE_MANIFESTS.find((manifest) => manifest.type === type)
}
