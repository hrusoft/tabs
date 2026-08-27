import type { BrowserWindow, WebPreferences } from 'electron'
import type { ContentTypeId } from '../shared/content/registry'
import { resolvePluginEntries } from '../shared/plugin/entries'
import type { MainPluginContext, MainPluginModule } from './plugin/api'
import { createMainPluginContext } from './plugin/context'

/**
 * Main's activation point: every package's main entry, discovered by glob and
 * reconciled against the manifests (shared/plugin/entries.ts). Each entry's
 * `activate` registers the package's IPC and verbs against a type-bound
 * context (plugin/context.ts) and hands back the MainPluginModule record the
 * lifecycle helpers below iterate — so a package's whole main-process surface
 * arrives through one discovered call, and this file names no package.
 *
 * This glob must stay per-boundary: these entries pull in node-pty and
 * Electron, so no renderer may import this file (see
 * shared/content/registry.ts for the rule and the other boundaries).
 *
 * Order is PLUGIN_PACKAGES order — the same order every other boundary
 * activates in, and the order every hook below runs in.
 */
const mainEntries = import.meta.glob<{ activate: (ctx: MainPluginContext) => MainPluginModule }>(
  '../plugins/*/main/index.ts',
  { eager: true }
)

/**
 * The activated packages paired with their type name, in activation order.
 * Populated once by registerContentModules; every helper below iterates it,
 * and whenReady's own ordering keeps them all after the population.
 */
const activated: [ContentTypeId, MainPluginModule][] = []

/**
 * Activates every package: each registers its IPC and core-registry entries
 * inside its `activate`, and its returned lifecycle record joins the list the
 * helpers below iterate. Called from whenReady after registerSettingsIpc (so
 * a package may read settings) and before registerExternalControlServer (so
 * every control verb is claimed before the socket accepts a request for one).
 *
 * A package missing a piece here is not a silent gap: the census and the
 * entry resolver throw at module evaluation on any declaration mismatch, and
 * the e2e gate over unhandledMainControlVerbs covers the half nothing static
 * can see — an activation that runs but registers less than its manifest
 * declares.
 */
export function registerContentModules(): void {
  for (const [type, entry] of resolvePluginEntries('main', mainEntries)) {
    activated.push([type, entry.activate(createMainPluginContext(type))])
  }
}

/**
 * Every type's construction-time `webPreferences`, merged. Called from
 * createWindow only — never for the Settings window, which hosts no panes and
 * should be granted no pane capability.
 *
 * Later packages win a contested key, which is activation order (above);
 * nothing contests one today, and core layers its own settings over the result
 * regardless (see createWindow).
 */
export function contentModuleWindowPreferences(): WebPreferences {
  const merged: WebPreferences = {}
  for (const [, module] of activated) Object.assign(merged, module.windowPreferences)
  return merged
}

/** Wires every type into the pane-tree window. Called from createWindow only — never for the Settings window. */
export function wireContentModulesInto(window: BrowserWindow): void {
  for (const [, module] of activated) module.wireWindow?.(window)
}

/**
 * Runs every type's quit work, synchronously.
 *
 * Each hook is wrapped, for the same reason closeBlockers.ts wraps each
 * provider in the same handler: a throw escaping here would skip the remaining
 * packages' teardown — leaving ptys orphaned because some unrelated type failed
 * — and an uncaught throw inside before-quit can reach node-addon-api's unsafe
 * rethrow path and abort the process (see CLAUDE.md). Failing open is strictly
 * better than either.
 *
 * The thenable check is the runtime half of the synchronous contract, which
 * the type system cannot enforce: an `async` function is perfectly assignable
 * to `onQuitSync?(): void`, and one slipping in would reintroduce precisely
 * the async-work-in-before-quit pattern that made shutdown hang. It logs
 * rather than throwing — this is a diagnostic, and this handler is the last
 * place that should start raising exceptions.
 */
export function runContentModuleQuitHooks(): void {
  forEachPackageQuietly('quit', (type, module) => {
    const returned: unknown = module.onQuitSync?.()
    if (typeof (returned as PromiseLike<unknown> | undefined)?.then === 'function') {
      console.error(
        `[tabs] content package "${type}" returned a promise from onQuitSync; ` +
          'quit work must be fully synchronous — see CLAUDE.md'
      )
    }
  })
}

/**
 * e2e only: resets every type's mutable main-process state. See main/e2e.ts.
 * This runs first in the e2e reset, and an unguarded throw would skip every
 * core reset after it — leaked state that lands on an innocent later test.
 */
export function resetContentModulesForTests(): void {
  forEachPackageQuietly('test reset', (_type, module) => module.resetForTests?.())
}

/** One package's failure must not skip the others: each hook runs in its own guard, logged by package. */
function forEachPackageQuietly(
  during: string,
  fn: (type: string, module: MainPluginModule) => void
): void {
  for (const [type, module] of activated) {
    try {
      fn(type, module)
    } catch (error) {
      console.error(`[tabs] content package "${type}" failed during ${during}:`, error)
    }
  }
}
