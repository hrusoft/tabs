/**
 * The one list of content-type packages — names only, no imports, and the
 * only file anywhere that enumerates them. Everything else is discovered:
 * each aggregation point globs `src/plugins/<name>/<its entry>` at build time
 * and reconciles what it finds against this list and each package's manifest
 * (see shared/content/registry.ts and the reconciliation test beside the
 * boundary ledger).
 *
 * The list survives discovery because it carries three things a glob cannot:
 *
 * - **Order.** Glob order is path-alphabetical; this order is a UI contract —
 *   activation order is the pane-header button order, and the census, the
 *   behaviour registrations and the settings sidebar all follow it.
 * - **The literal type union.** `ContentTypeId` derives from this tuple, so
 *   it stays `'terminal' | 'browser' | 'gitTree'` instead of collapsing to
 *   `string` the moment manifests arrive through a glob.
 * - **Intent.** A folder existing under src/plugins/ does not make a package
 *   ship; a name here says "on purpose", and the reconciliation gate fails
 *   loudly on any mismatch between the two — in both directions.
 *
 * A package's folder name IS its content-type id (enforced by the census at
 * load), so adding a type is: create `src/plugins/<id>/` with a manifest and
 * entries, then add `<id>` here. Nothing else to edit anywhere.
 */
export const PLUGIN_PACKAGES = ['terminal', 'browser', 'gitTree'] as const

export type PluginPackageName = (typeof PLUGIN_PACKAGES)[number]
