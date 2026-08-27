import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { expect, test } from 'vitest'

/**
 * The plugin boundary, enforced: content-type packages under src/plugins/
 * reach core only through the plugin API modules (plus a short, deliberate
 * shared surface), and core reaches into a package only from the named
 * aggregation files. The compiler cannot check either direction — an import
 * of a core internal typechecks fine, which is exactly the problem — so the
 * ledger lives here, and growing either list is a deliberate edit to this
 * file rather than something a stray import does silently.
 *
 * Scope: shipped code only. Test files (__tests__/, *.test.*) are exempt in
 * both directions — a package's tests legitimately use core's test harness,
 * and a core test may exercise a package fragment directly (e.g.
 * guest-activation.test.tsx). The tsconfig import-graph hazards those files
 * could cause are covered by the tiers that compile them.
 *
 * Resolution is deliberately dumb — the same relative/@shared resolution the
 * bundler and tsconfig paths perform, reimplemented in a few lines — so the
 * test needs no TypeScript machinery and runs in the plain node tier.
 */

const root = path.resolve(import.meta.dirname, '../../../..')

/**
 * Core modules a package file may import, by absolute repo-relative path.
 * Every entry is a decision, not a convenience:
 *
 * - The five plugin API modules are the contract itself, one per import-graph
 *   boundary (pane window, Settings window, main, preload, plus the
 *   process-agnostic context holder).
 * - The shared surface is the process-agnostic data model and pure utilities
 *   a content type is *expected* to speak in: the layout model, the wire
 *   protocol's core types, the settings-descriptor contract, the census
 *   record type its manifest satisfies, and the chord/ring-log/url helpers.
 *   Nothing stateful and nothing process-bound is on it — stores, registries
 *   and Electron services arrive on the activation contexts instead.
 */
const PLUGIN_IMPORTABLE = new Set([
  // the plugin API, one module per boundary (preload's is gone — packages
  // ship no preload code since the generic content bridge)
  'src/renderer/src/plugin/api.ts',
  'src/renderer/src/plugin/settingsApi.ts',
  'src/main/plugin/api.ts',
  'src/shared/plugin/contextHolder.ts',
  // the process-agnostic shared surface
  'src/shared/model/types.ts',
  'src/shared/model/factories.ts',
  'src/shared/model/tree.ts',
  'src/shared/model/navigation.ts',
  'src/shared/model/floating.ts',
  'src/shared/model/ids.ts',
  'src/shared/model/separatorSnap.ts',
  'src/shared/externalControl.ts',
  'src/shared/shortcuts.ts',
  'src/shared/ringLog.ts',
  'src/shared/url.ts',
  'src/shared/content/registry.ts',
  'src/shared/content/settingsDescriptor.ts',
  'src/shared/content/enablement.ts',
  // testing surface: the emitter behind a package's fake-bridge piece
  'src/renderer/src/testing/emitter.ts',
  'src/shared/testing/fakeApiHandle.ts'
])

/**
 * Core files that may reach into src/plugins/ — the aggregation points. Most
 * now reach by `import.meta.glob` (which this walker expands to the files it
 * matches, so discovery is held to the same ledger as a static import); the
 * two type-only aggregations (the verb union, the fake-handle union) still
 * import statically because TypeScript cannot glob types.
 * registerTestContent.ts is the documented exception: the non-Electron tiers
 * install the browser's two guest forwarders directly, because those few
 * lines are safe to import where the package's renderer entry (xterm,
 * `<webview>`) is not — the reasoning lives in that file.
 */
const CORE_AGGREGATION_FILES = new Set([
  'src/shared/content/registry.ts',
  'src/shared/content/externalControl.ts',
  'src/shared/testing/content/api.ts',
  'src/main/contentTypes.ts',
  'src/renderer/src/content/registerBuiltins.ts',
  'src/renderer/src/settings/registerBuiltinPages.ts',
  'src/renderer/src/testing/content/index.ts',
  'src/renderer/src/testing/registerTestContent.ts'
])

const IMPORT_RE = /(?:from|import)\s*\(?\s*'([^']+)'/g
// A glob is an import edge to every file it matches. The lazy window after
// `import.meta.glob` skips the generic type argument (which may itself
// contain `>` inside a function type) to the pattern string.
const GLOB_RE = /import\.meta\.glob[\s\S]{0,300}?'([^']+)'/g

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (/\.(ts|tsx)$/.test(name)) out.push(p)
  }
  return out
}

const isTestFile = (rel: string): boolean => rel.includes('__tests__') || /\.test\.tsx?$/.test(rel)

/**
 * The one file directly under src/plugins/ is the names list — core-facing
 * data with no package imports, the spine every aggregation orders by — so it
 * is neither "inside a package" nor "reaching into one". Package files are
 * the ones under src/plugins/<name>/.
 */
const isPackageFile = (rel: string): boolean => /^src\/plugins\/[^/]+\//.test(rel)

/** Every file a single-`*` glob pattern matches, resolved from `fromDir`, as repo-relative paths. */
function expandGlob(fromDir: string, pattern: string): string[] {
  const starIndex = pattern.indexOf('*')
  if (starIndex === -1) return []
  const prefix = pattern.slice(0, starIndex)
  const suffix = pattern.slice(starIndex + 1)
  const baseDir = path.resolve(fromDir, prefix)
  if (!existsSync(baseDir)) return []
  const hits: string[] = []
  for (const name of readdirSync(baseDir)) {
    const candidate = path.join(baseDir, name + suffix)
    if (existsSync(candidate) && statSync(candidate).isFile()) {
      hits.push(path.relative(root, candidate))
    }
  }
  return hits
}

/** Repo-relative path of `spec` imported from `fromDir`, or null for npm/electron/node/asset imports. */
function resolveImport(fromDir: string, spec: string): string | null {
  // electron-vite asset imports carry a query (`?asset`); the file behind
  // them is a resource, not a module, so they are outside this ledger.
  const bare = spec.split('?')[0]!
  let candidate: string
  if (bare.startsWith('@shared/')) candidate = path.join(root, 'src/shared', bare.slice(8))
  else if (bare.startsWith('.')) candidate = path.resolve(fromDir, bare)
  else return null
  for (const tried of [
    `${candidate}.ts`,
    `${candidate}.tsx`,
    path.join(candidate, 'index.ts'),
    candidate
  ]) {
    if (existsSync(tried) && statSync(tried).isFile()) {
      return /\.(ts|tsx)$/.test(tried) ? path.relative(root, tried) : null
    }
  }
  // An unresolvable specifier is a bug in this test's resolver, not in the
  // code — typecheck would have failed first. Fail loudly rather than skip.
  throw new Error(`pluginBoundaries could not resolve "${spec}" from ${fromDir}`)
}

interface Edge {
  importer: string
  target: string
}

function collectEdges(): { fromPlugins: Edge[]; intoPlugins: Edge[] } {
  const fromPlugins: Edge[] = []
  const intoPlugins: Edge[] = []
  const record = (rel: string, target: string): void => {
    // src/plugins/index.ts (the names list) is core-facing on both sides —
    // see isPackageFile. Edges to it are unrestricted; it imports nothing.
    if (isPackageFile(rel)) {
      const pkg = rel.split('/').slice(0, 3).join('/')
      if (!target.startsWith(`${pkg}/`)) fromPlugins.push({ importer: rel, target })
    } else if (isPackageFile(target)) {
      intoPlugins.push({ importer: rel, target })
    }
  }
  for (const file of walk(path.join(root, 'src'))) {
    const rel = path.relative(root, file)
    if (isTestFile(rel)) continue
    const source = readFileSync(file, 'utf8')
    for (const match of source.matchAll(IMPORT_RE)) {
      if (match[1]!.endsWith('.css')) continue
      if (match[1]!.includes('*')) continue // a glob pattern, handled below
      const target = resolveImport(path.dirname(file), match[1]!)
      if (target === null) continue
      record(rel, target)
    }
    for (const match of source.matchAll(GLOB_RE)) {
      for (const target of expandGlob(path.dirname(file), match[1]!)) {
        record(rel, target)
      }
    }
  }
  return { fromPlugins, intoPlugins }
}

const edges = collectEdges()

test('a package imports core only through the plugin API and the sanctioned shared surface', () => {
  const violations = edges.fromPlugins.filter(
    (edge) => !PLUGIN_IMPORTABLE.has(edge.target) && !edge.target.startsWith('src/plugins/')
  )
  expect(
    violations.map((edge) => `${edge.importer} -> ${edge.target}`),
    'a plugin file imported a core internal; go through the activation context, or add the module to the API ledger deliberately'
  ).toEqual([])
})

test('no package imports another package', () => {
  const crossPackage = edges.fromPlugins.filter((edge) => edge.target.startsWith('src/plugins/'))
  expect(
    crossPackage.map((edge) => `${edge.importer} -> ${edge.target}`),
    'content types must not know each other — cross-type behaviour goes through a core capability (deriveConfig/exposeCwd are the worked example)'
  ).toEqual([])
})

test('core reaches into packages only from the aggregation files', () => {
  const violations = edges.intoPlugins.filter((edge) => !CORE_AGGREGATION_FILES.has(edge.importer))
  expect(
    violations.map((edge) => `${edge.importer} -> ${edge.target}`),
    'core imported a package internal from outside the aggregation points; either the capability belongs on a plugin API context, or the importer is a new aggregation point to add here deliberately'
  ).toEqual([])
})

test('no package file touches the preload bridge directly', () => {
  // `window.api` is an ambient global with no import edge — exactly how a
  // core capability would slip past the import ledger above. Packages reach
  // preload through their activation context instead (the generic content
  // bridge arrives on it as `ipc`, already scoped to the package's type; a
  // capability a package misses belongs on the context, not on the global).
  // Comment lines are exempt: prose may name the bridge, code may not.
  const offenders: string[] = []
  for (const file of walk(path.join(root, 'src/plugins'))) {
    const rel = path.relative(root, file)
    if (isTestFile(rel)) continue
    readFileSync(file, 'utf8')
      .split('\n')
      .forEach((line, index) => {
        const trimmed = line.trim()
        if (trimmed.startsWith('*') || trimmed.startsWith('//') || trimmed.startsWith('/*')) return
        if (trimmed.includes('window.api')) offenders.push(`${rel}:${index + 1}`)
      })
  }
  expect(
    offenders,
    'a package reached window.api directly; the capability belongs on its activation context'
  ).toEqual([])
})

test('the sanity premise holds: the walk saw real edges on both sides', () => {
  // Guards this suite against a refactor that moves the trees and leaves the
  // walker staring at empty directories — three green boundary tests over
  // zero edges would be the worst kind of pass.
  expect(edges.fromPlugins.length).toBeGreaterThan(20)
  expect(edges.intoPlugins.length).toBeGreaterThan(10)
})
