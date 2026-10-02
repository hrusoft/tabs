import type { ControlVerbSpec } from './controlSpec'
import type { ContentTypeSettingsDescriptor } from './settingsDescriptor'

/**
 * The content-type manifest contract — the pure, declarative half of
 * `src/shared/content/registry.ts`, which stays core-owned: the runtime
 * census built from every package's manifest (`CONTENT_TYPE_MANIFESTS`,
 * `buildCensus()`, `manifestFor()`) inherently depends on discovering every
 * plugin package, so it cannot live in the SDK a plugin depends on without a
 * cycle (SDK -> census -> every plugin's manifest -> a plugin importing the
 * SDK). Verified by grep during planning: no plugin file imports anything
 * from `content/registry.ts` beyond the `ContentTypeManifest` type itself
 * (every package's own `shared/manifest.ts` uses it in `satisfies
 * ContentTypeManifest`).
 *
 * `ContentTypeId` (the literal `'terminal' | 'browser' | 'gitTree'` union)
 * deliberately does NOT live here, even though it's a pure type derived from
 * `ContentTypeManifest['type']`: it's built from `PLUGIN_PACKAGES`
 * (`src/plugins/index.ts`), and a real npm workspace package's own composite
 * TypeScript project structurally refuses a relative import reaching outside
 * its `rootDir` into core's `src/` tree (confirmed: `tsc -b` on this
 * package's own tsconfig fails with TS6059/TS6307 for exactly that import) —
 * the same boundary enforcement that refuses the reverse direction (a plugin
 * reaching into core). No plugin file imports `ContentTypeId` today (only
 * `ContentTypeManifest`, verified by grep), so it stays defined in
 * `src/shared/content/registry.ts` itself, right beside `PLUGIN_PACKAGES`.
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
   * Read by `togglableContentTypes()` (core's `shared/content/enablement.ts`),
   * which is what the Settings window renders a checkbox from — so a new type
   * appears in that UI with no edit there. Note this governs only what the UI
   * *offers*: the gate itself honours plain membership of
   * `disabledContentTypes` for any type at all, for the reasons
   * enablement.ts sets out. Structural types (tabs/split/empty) are layout
   * rather than content and are absent from the census entirely, which is
   * what excludes them.
   */
  canDisable: boolean
  /**
   * Which entry files this package ships — what each boundary's glob is
   * reconciled against, in both directions: a declared entry whose file the
   * glob didn't find is an error, and so is a file nothing declared. The
   * "you registered what you declared" gate, running against built-ins today.
   */
  entries: readonly PluginEntryKind[]
  /**
   * The external-control verbs this package *adds to the wire protocol* —
   * one full `ControlVerbSpec` per verb (its CLI command name, flags, wire
   * schema, result shape), not just a name: the protocol's entire runtime
   * surface — `capabilities`/`describe` — is served from these specs, so a
   * plugin ships its whole control surface by declaring them here and
   * nowhere else. Reconciled three ways: declared here, typed in the
   * package's own request union, answered by the activations. Core verbs a
   * package merely answers (the browser handles four of core's) are
   * deliberately not declared — which module answers a verb is a separate
   * question from which union declares it.
   */
  controlVerbs?: readonly ControlVerbSpec[]
  /**
   * What this type contributes to the persisted Settings shape, if anything.
   * Optional: a type with no user-facing settings declares none.
   * `CONTENT_TYPE_SETTINGS` in core's `shared/settings.ts` is derived from
   * these, so the census stays the single source. A package that declares
   * settings must also ship a `settings` entry, and vice versa — reconciled
   * with the rest.
   */
  settings?: ContentTypeSettingsDescriptor
  /**
   * The prose that explains *when* and *how* to use this type's control
   * verbs well — the technique-level guidance a flag list alone can't carry
   * (readiness semantics, targeting rules, what to poll for). Served by the
   * `describe` verb (src/main/externalControl.ts) alongside the type's full
   * command reference. Absent for a type that declares no control verbs at
   * all — there is nothing to guide.
   */
  guide?: string
  /**
   * Named numeric constants this type's verbs are bound by (caps, defaults,
   * timeouts) — served in `describe`'s output alongside the guide, so an
   * agent can read the real ceiling rather than a doc string that might
   * drift from it.
   */
  limits?: Record<string, number>
}
