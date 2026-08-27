import { PLUGIN_PACKAGES } from '../../plugins/index'
import { type ContentTypeId, manifestFor, type PluginEntryKind } from '../content/registry'

/**
 * Resolves one boundary's entry glob against the list and the manifests — the
 * shared half of every aggregation point (registerBuiltins, contentTypes,
 * registerBuiltinPages, the fake bridge). Each site passes the record its own
 * `import.meta.glob` produced; this orders the hits by PLUGIN_PACKAGES and
 * reconciles them against each package's declared `entries`, in both
 * directions:
 *
 * - declared but not found → the package promised an entry it doesn't ship;
 * - found but not declared → a file exists that the manifest doesn't own up
 *   to (or a folder exists that PLUGIN_PACKAGES never named — the census
 *   throws for that case before this can run, but a folder with an entry and
 *   no manifest at all lands here);
 *
 * and throws naming the package, the entry kind and the fix. At module
 * evaluation in main that is a refused boot with a readable message; in the
 * unit tier the reconciliation test hits the same checks against the
 * filesystem first.
 */
export function resolvePluginEntries<T>(
  kind: PluginEntryKind,
  modules: Record<string, T>
): [ContentTypeId, T][] {
  const byName = new Map<string, T>()
  for (const [path, module] of Object.entries(modules)) {
    const match = /\/plugins\/([^/]+)\//.exec(path)
    if (!match) throw new Error(`unexpected plugin entry glob path: ${path}`)
    const name = match[1]!
    if (!(PLUGIN_PACKAGES as readonly string[]).includes(name)) {
      throw new Error(
        `src/plugins/${name} ships a ${kind} entry but is not named in PLUGIN_PACKAGES (src/plugins/index.ts)`
      )
    }
    byName.set(name, module)
  }

  const resolved: [ContentTypeId, T][] = []
  for (const name of PLUGIN_PACKAGES) {
    const declared = manifestFor(name)?.entries.includes(kind) ?? false
    const module = byName.get(name)
    if (declared && module === undefined) {
      throw new Error(
        `content-type package "${name}" declares a "${kind}" entry in its manifest but ships no such file`
      )
    }
    if (!declared && module !== undefined) {
      throw new Error(
        `content-type package "${name}" ships a "${kind}" entry its manifest does not declare — add "${kind}" to the manifest's entries`
      )
    }
    if (module !== undefined) resolved.push([name, module])
  }
  return resolved
}
