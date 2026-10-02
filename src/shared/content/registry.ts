import type { ContentTypeManifest } from '@tabs/plugin-sdk/shared/content/manifest'
import { PLUGIN_PACKAGES, type PluginPackageName } from '../../plugins/index'

export type { ContentTypeManifest, PluginEntryKind } from '@tabs/plugin-sdk/shared/content/manifest'

/**
 * Every content type's `type` string as a literal union — `'terminal' |
 * 'browser' | 'gitTree'`, derived from the one hand-written list rather than
 * from the globbed manifests (which arrive as `ContentTypeManifest[]` and
 * could only offer `string`). Defined here, not in the SDK's own manifest.ts,
 * because it's built from `PLUGIN_PACKAGES` (src/plugins/index.ts) and no
 * plugin file needs it (verified by grep) — and a relative reach into core
 * from inside the SDK's composite project is refused by `tsc -b` anyway
 * (TS6059/TS6307, see CLAUDE.md's plugin-SDK entry).
 */
export type ContentTypeId = PluginPackageName

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
 * (`packages/plugin-<name>/shared/manifest.ts`) and ordering by `PLUGIN_PACKAGES` —
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

/**
 * `ContentTypeManifest`/`PluginEntryKind`/`ContentTypeId` themselves now live
 * in `packages/plugin-sdk/shared/content/manifest.ts` (issue #18) — the pure, declarative
 * contract a plugin's own `shared/manifest.ts` satisfies, re-exported above
 * so nothing outside this file needs to know it moved.
 */

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
    return import.meta.glob<ManifestModule>('../../../packages/plugin-*/shared/manifest.ts', {
      eager: true
    })
  }
  throw new Error(
    'the content-type census is only available inside Vite-built contexts; ' +
      'an e2e spec must not import modules that reach it (src/shared/settings.ts does) — ' +
      'state the value the test needs as a literal instead'
  )
}

const manifestModules = loadManifestModules()

/**
 * The package name a globbed path belongs to — `<name>` in
 * `…/packages/plugin-<name>/…` — or undefined for a path that isn't shaped
 * like one. Shared with entries.ts, the other `import.meta.glob` reconciler,
 * so the two don't each hand-write this regex. Deliberately as loose as the
 * shape it names: each call site's own glob pattern already guarantees the
 * stricter shape its caller wants, so narrowing this further would only
 * duplicate that guarantee, not add one. (The glob patterns cannot reach
 * packages/plugin-sdk: it ships none of the entry files they name.)
 */
export function packageNameFromPluginPath(path: string): string | undefined {
  return /(?:^|\/)packages\/plugin-([^/]+)\//.exec(path)?.[1]
}

/** The folder name a globbed manifest path belongs to — its `shared/manifest.ts`. */
function packageNameOf(path: string): string {
  const name = packageNameFromPluginPath(path)
  if (!name) throw new Error(`unexpected manifest glob path: ${path}`)
  return name
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
        `content-type package "${name}" declares type "${manifest.type}" — a package's folder name is its type id`
      )
    }
    if (!(PLUGIN_PACKAGES as readonly string[]).includes(name)) {
      throw new Error(
        `content-type package "${name}" exists but is not named in PLUGIN_PACKAGES (src/plugins/index.ts) — add it there to ship it, or remove the folder`
      )
    }
    byName.set(name, manifest)
  }
  return PLUGIN_PACKAGES.map((name) => {
    const manifest = byName.get(name)
    if (!manifest) {
      throw new Error(
        `PLUGIN_PACKAGES names "${name}" but packages/plugin-${name}/shared/manifest.ts does not exist`
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
