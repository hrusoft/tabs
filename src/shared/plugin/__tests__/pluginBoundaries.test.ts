import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { builtinModules } from 'node:module'
import path from 'node:path'
import { expect, test } from 'vitest'

/**
 * The plugin boundary, enforced. Content-type packages live in their own
 * npm workspace packages (packages/plugin-<name>/, issue #18), and that
 * physical separation already stops a package reaching into core: core is
 * not a package, so there is no specifier that resolves into it, and a
 * relative reach out of a package's composite project fails `tsc -b`
 * (TS6059/TS6307). What the package boundary does *not* stop is a package
 * reaching past the SDK's barrels into its internals — @tabs/plugin-sdk's
 * `package.json#exports` are wildcards, so every SDK file resolves — nor a
 * package importing or depending on a sibling package, nor core reaching
 * into a package from somewhere other than an aggregation point. Those are
 * this ledger's job, and each list below is a deliberate edit rather than
 * something a stray import does silently:
 *
 * - a package imports only the SDK's sanctioned entry modules
 *   (PLUGIN_IMPORTABLE);
 * - a package neither imports nor declares a dependency on another content
 *   type (checked against its source *and* its package.json);
 * - a package declares every npm package its shipped code imports (so its
 *   package.json is the truth about what it needs — and Biome, which only
 *   applies its React-hooks rules to a package that declares react, sees
 *   what it should);
 * - core reaches into a package only from CORE_AGGREGATION_FILES, including
 *   through `import.meta.glob`, which the walk expands to the files matched.
 *
 * Scope: shipped code only. Test files (__tests__/, *.test.*) are exempt —
 * a package's tests legitimately use core's test harness, and a core test
 * may exercise a package fragment directly (e.g. guest-activation.test.tsx).
 * The tsconfig import-graph hazards those files could cause are covered by
 * the tiers that compile them.
 *
 * Resolution is deliberately dumb — the same relative/@shared/SDK resolution
 * the bundler performs, reimplemented in a few lines — so the test needs no
 * TypeScript machinery and runs in the plain node tier.
 */

const root = path.resolve(import.meta.dirname, '../../../..')

/**
 * What a package file may import from the SDK, by repo-relative path — the
 * sanctioned entry modules. Every entry is a decision, not a convenience:
 * the barrels are the contract itself, one per process boundary; the shared
 * surface is the process-agnostic data model and pure utilities a content
 * type is *expected* to speak in (the layout model's node types, the wire protocol's
 * plugin-facing types, the settings-descriptor and manifest contracts, the
 * chord/ring-log/url helpers). Nothing stateful and nothing process-bound is
 * on it — stores, registries and Electron services arrive on the activation
 * contexts instead.
 */
const PLUGIN_IMPORTABLE = new Set([
  // One barrel per process boundary. Each re-exports its boundary's whole
  // plugin-facing contract *by name* — never `export *` over a sibling — so
  // an SDK-internal implementation file stays unreachable: a package gets
  // HeaderButton through renderer/api, never PaneHeaderMenuGroup.tsx; the
  // process probes through main/api, never processProbe.ts (whose parsers
  // and timeouts are test surface); the setting rows through settings/api,
  // never rows.tsx (whose RowText is a shared internal). Tooltip.tsx,
  // IconButton.tsx, paneDom.ts, paneValueStore.ts, typedSettings.ts and the
  // main-side leaves are deliberately absent — naming one fails this test.
  'packages/plugin-sdk/renderer/api.ts',
  'packages/plugin-sdk/main/api.ts',
  'packages/plugin-sdk/settings/api.ts',
  // The two contract types a package's own entry files must name: its
  // manifest's shape (shared/manifest.ts) and its fake-bridge host
  // (testing/fakeApi.ts).
  'packages/plugin-sdk/shared/content/manifest.ts',
  'packages/plugin-sdk/renderer/fakeContentHost.ts',
  // The process-agnostic shared surface a content type speaks in. The
  // shared layer has no barrel: each module is small and self-contained, and
  // everything in it is meant for plugin use. Of the layout model that means
  // the node types, their guards and factories — not the tree operations,
  // floating-pane geometry or spatial navigation, which are core's and live
  // in src/shared/model/. (content/enablement.ts, the census and the
  // assembled ControlRequest union stay core-only in src/shared too — no
  // plugin imports them.)
  'packages/plugin-sdk/shared/plugin/contextHolder.ts',
  'packages/plugin-sdk/shared/model/types.ts',
  'packages/plugin-sdk/shared/model/factories.ts',
  'packages/plugin-sdk/shared/model/ids.ts',
  'packages/plugin-sdk/shared/externalControl.ts',
  'packages/plugin-sdk/shared/shortcuts.ts',
  'packages/plugin-sdk/shared/ringLog.ts',
  'packages/plugin-sdk/shared/url.ts',
  'packages/plugin-sdk/shared/content/settingsDescriptor.ts',
  'packages/plugin-sdk/shared/content/controlSpec.ts',
  'packages/plugin-sdk/shared/jsonSchema.ts'
])

/**
 * Core files that may reach into a content-type package — the aggregation
 * points, every one of which reaches by `import.meta.glob` (which this
 * walker expands to the files it matches, so discovery is held to the same
 * ledger as a static import). No type-only aggregation is left: the
 * fake-handle union went in issue #18 (each package types its own slice of
 * the fake driver), and the external-control verb union before it
 * (`ControlRequest`'s plugin half is a generic shape read from the runtime
 * census). registerTestContent.ts is the one static exception: the non-Electron tiers
 * install the browser's two guest forwarders directly, because those few
 * lines are safe to import where the package's renderer entry (xterm,
 * `<webview>`) is not — the reasoning lives in that file.
 */
const CORE_AGGREGATION_FILES = new Set([
  'src/shared/content/registry.ts',
  'src/main/contentTypes.ts',
  'src/renderer/src/content/registerBuiltins.ts',
  'src/renderer/src/settings/registerBuiltinPages.ts',
  'src/renderer/src/testing/content/index.ts',
  'src/renderer/src/testing/registerTestContent.ts'
])

const IMPORT_RE = /(?:from|import)\s*\(?\s*'([^']+)'/g
// A glob is an import edge to every file it matches. Captures the whole call
// — type argument through the trailing `{ eager: true })` every call site in
// this codebase uses — rather than just the first quoted string, because
// issue #18's move to real workspace packages left several call sites
// passing an *array* of two patterns (one per package-location shape) during
// the transition; every quoted string inside the captured span is a pattern,
// since the type argument itself (a function-type literal, which is why this
// can't just stop at the first `(`) never contains a quote. It starts only at
// a real call — `import.meta.glob` directly followed by `<` or `(` — because
// prose mentions of it (in backticks) sit right above real calls, and a
// match starting at one swallowed the comment's apostrophes ("Vite's") into
// the span, mis-pairing quotes and silently dropping the census glob.
const GLOB_RE = /import\.meta\.glob[<(][\s\S]{0,400}?\{\s*eager:\s*true\s*\}\s*\)/g
const PATTERN_RE = /'([^']+)'/g

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
 * A content-type package's own files are the ones under
 * packages/plugin-<name>/ — deliberately excluding packages/plugin-sdk/,
 * the core-owned SDK a package reaches through the sanctioned-entry
 * allowlist above, not a content type subject to these boundary rules.
 * (src/plugins/index.ts, the names list, is core-facing data: neither inside
 * a package nor reaching into one.)
 */
const CONTENT_PACKAGE_RE = /^(packages\/plugin-(?!sdk\/)[^/]+)\//
const isPackageFile = (rel: string): boolean => CONTENT_PACKAGE_RE.test(rel)

/** The `packages/plugin-<name>` root a package file belongs to. */
function packageRootOf(rel: string): string {
  const pkgRoot = CONTENT_PACKAGE_RE.exec(rel)?.[1]
  if (!pkgRoot) throw new Error(`packageRootOf called on a non-package file: ${rel}`)
  return pkgRoot
}

/** Every file of every content-type package (the SDK's own files excluded). */
const packageSourceFiles = (): string[] =>
  walk(path.join(root, 'packages')).filter((f) => isPackageFile(path.relative(root, f)))

/**
 * Every file a single-`*` glob pattern matches, resolved from `fromDir`, as
 * repo-relative paths. The `*` may sit inside a path segment
 * (`packages/plugin-*` + `/main/index.ts`): the segment's literal prefix
 * filters the directory listing. An earlier version assumed `*` was a whole
 * segment and resolved `packages/plugin-` as a directory — which silently
 * expanded every aggregation glob to nothing, a pass over zero edges that
 * only the sanity test below noticed.
 */
function expandGlob(fromDir: string, pattern: string): string[] {
  const starIndex = pattern.indexOf('*')
  if (starIndex === -1) return []
  const prefix = pattern.slice(0, starIndex)
  const suffix = pattern.slice(starIndex + 1)
  const slash = prefix.lastIndexOf('/')
  const baseDir = path.resolve(fromDir, prefix.slice(0, slash + 1))
  const namePrefix = prefix.slice(slash + 1)
  if (!existsSync(baseDir)) return []
  const hits: string[] = []
  for (const name of readdirSync(baseDir)) {
    if (!name.startsWith(namePrefix)) continue
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
  else if (bare.startsWith('@tabs/plugin-sdk/'))
    candidate = path.join(root, 'packages/plugin-sdk', bare.slice('@tabs/plugin-sdk/'.length))
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
      const pkg = packageRootOf(rel)
      if (!target.startsWith(`${pkg}/`)) fromPlugins.push({ importer: rel, target })
    } else if (isPackageFile(target)) {
      intoPlugins.push({ importer: rel, target })
    }
  }
  // Core (src/) and every content-type package. The SDK is not walked as a
  // source: it is not a "package" to these rules (see isPackageFile), and its
  // own internal imports would otherwise register as spurious edges.
  const files = [...walk(path.join(root, 'src')), ...packageSourceFiles()]
  for (const file of files) {
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
      for (const patMatch of match[0].matchAll(PATTERN_RE)) {
        for (const target of expandGlob(path.dirname(file), patMatch[1]!)) {
          record(rel, target)
        }
      }
    }
  }
  return { fromPlugins, intoPlugins }
}

const edges = collectEdges()

test("a package imports only the SDK's sanctioned entry modules", () => {
  const violations = edges.fromPlugins.filter(
    (edge) => !PLUGIN_IMPORTABLE.has(edge.target) && !isPackageFile(edge.target)
  )
  expect(
    violations.map((edge) => `${edge.importer} -> ${edge.target}`),
    "a package imported something outside the SDK's sanctioned entry modules — an SDK internal (reach it through the barrel that re-exports it) or a core module (go through the activation context); or add the module to PLUGIN_IMPORTABLE deliberately"
  ).toEqual([])
})

test('no package imports another package', () => {
  const crossPackage = edges.fromPlugins.filter((edge) => isPackageFile(edge.target))
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
  const packageFiles = packageSourceFiles()
  for (const file of packageFiles) {
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

interface WorkspacePackage {
  /** Repo-relative, e.g. `packages/plugin-terminal`. */
  dir: string
  json: Record<string, unknown>
}

/** Every workspace package (the SDK included) with its parsed package.json. */
function workspacePackages(): WorkspacePackage[] {
  const packagesDir = path.join(root, 'packages')
  return readdirSync(packagesDir)
    .filter((name) => existsSync(path.join(packagesDir, name, 'package.json')))
    .map((name) => ({
      dir: path.join('packages', name),
      json: JSON.parse(
        readFileSync(path.join(packagesDir, name, 'package.json'), 'utf8')
      ) as Record<string, unknown>
    }))
}

const DEPENDENCY_FIELDS = [
  'dependencies',
  'peerDependencies',
  'optionalDependencies',
  'devDependencies'
] as const

function namesIn(pkg: WorkspacePackage, fields: readonly string[]): [string, string][] {
  return fields.flatMap((field) =>
    Object.keys((pkg.json[field] as Record<string, string> | undefined) ?? {}).map(
      (name): [string, string] => [field, name]
    )
  )
}

test('no package.json names a sibling content-type package', () => {
  // The source-level check above catches an import; this catches the
  // declaration, which is what npm acts on — a dependency named here gets
  // linked in and hoisted whether or not anything imports it yet. The one
  // @tabs/* name a content type may depend on is the SDK; the SDK depends on
  // no workspace package at all.
  const offenders = workspacePackages().flatMap((pkg) => {
    const isSdk = pkg.dir === path.join('packages', 'plugin-sdk')
    return namesIn(pkg, DEPENDENCY_FIELDS)
      .filter(([, name]) => name.startsWith('@tabs/') && (isSdk || name !== '@tabs/plugin-sdk'))
      .map(([field, name]) => `${pkg.dir}/package.json ${field} names ${name}`)
  })
  expect(
    offenders,
    'content types must not know each other — cross-type behaviour goes through a core capability (deriveConfig/exposeCwd are the worked example)'
  ).toEqual([])
})

/** The npm package a bare specifier names (`@scope/name` or `name`), or null for relative, alias and Node-builtin specifiers. */
function npmPackageOf(spec: string): string | null {
  const bare = spec.split('?')[0]!
  if (bare.startsWith('.') || bare.startsWith('@shared/') || bare.startsWith('node:')) return null
  const parts = bare.split('/')
  if (builtinModules.includes(parts[0]!)) return null
  return bare.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0]!
}

test("every package's package.json declares each npm package its shipped code imports", () => {
  // devDependencies don't count: shipped code cannot rely on something only
  // installed for development. Host-provided modules (react, electron) are
  // peerDependencies — and declaring react is also what makes Biome apply
  // its React-hooks rules inside the package at all.
  const offenders = workspacePackages().flatMap((pkg) => {
    const declared = new Set(
      namesIn(pkg, ['dependencies', 'peerDependencies', 'optionalDependencies']).map(([, n]) => n)
    )
    return walk(path.join(root, pkg.dir))
      .map((file) => path.relative(root, file))
      .filter((rel) => !isTestFile(rel))
      .flatMap((rel) =>
        [...readFileSync(path.join(root, rel), 'utf8').matchAll(IMPORT_RE)]
          .map((match) => npmPackageOf(match[1]!))
          .filter((name): name is string => name !== null && name !== pkg.json.name)
          .filter((name) => !declared.has(name))
          .map((name) => `${rel} imports '${name}', which ${pkg.dir}/package.json does not declare`)
      )
  })
  expect(
    [...new Set(offenders)],
    "declare it in the package's own dependencies (a runtime dependency it owns) or peerDependencies (one the app provides)"
  ).toEqual([])
})

test('the sanity premise holds: the walk saw real edges on both sides', () => {
  // Guards this suite against a refactor that moves the trees and leaves the
  // walker staring at empty directories — three green boundary tests over
  // zero edges would be the worst kind of pass.
  expect(edges.fromPlugins.length).toBeGreaterThan(20)
  expect(edges.intoPlugins.length).toBeGreaterThan(10)
})
