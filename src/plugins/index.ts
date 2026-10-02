/**
 * The one list of content-type packages — names only, no imports, and the
 * only file anywhere that enumerates them. Everything else is discovered:
 * each aggregation point globs `packages/plugin-<name>/<its entry>` at build time
 * and reconciles what it finds against this list and each package's manifest
 * (see shared/content/registry.ts and the reconciliation test beside the
 * boundary ledger).
 *
 * The list survives discovery because it carries three things a glob cannot:
 *
 * - **Order.** Glob order is path-alphabetical; this order is a UI contract —
 *   activation order is the creation-action order (the empty-pane toolbar,
 *   the Cmd+P palette), and the census, the
 *   behaviour registrations and the settings sidebar all follow it.
 * - **The literal type union.** `ContentTypeId` derives from this tuple, so
 *   it stays `'terminal' | 'browser' | 'gitTree'` instead of collapsing to
 *   `string` the moment manifests arrive through a glob.
 * - **Intent.** A folder existing under packages/ does not make a package
 *   ship; a name here says "on purpose", and the reconciliation gate fails
 *   loudly on any mismatch between the two — in both directions.
 *
 * A package's folder is `packages/plugin-<id>/`, and that `<id>` IS its
 * content-type id (enforced by the census at load), so adding a type is:
 *
 * 1. create the folder with its own package.json, tsconfigs, manifest and
 *    entries;
 * 2. add `<id>` here;
 * 3. reference its projects from the three root tsconfigs — `references`
 *    cannot glob, so this is the one hand-kept list, and the reconciliation
 *    test fails naming any project left out;
 * 4. `npm install`, which links the package into node_modules.
 *
 * No aggregation point changes. A native runtime dependency also needs
 * electron-builder.yml and the root `rebuild` script (CLAUDE.md, "Plugins
 * and packages").
 */
export const PLUGIN_PACKAGES = ['terminal', 'browser', 'gitTree'] as const

export type PluginPackageName = (typeof PLUGIN_PACKAGES)[number]
