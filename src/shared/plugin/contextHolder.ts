/**
 * Module-scope keeper for the context a package's `activate` receives — the
 * standard shape for code that runs outside activation scope (a component
 * deep in the package, a def's hook) to reach the plugin API.
 *
 * A factory rather than each package hand-writing the two functions, so the
 * error a mis-ordered call produces is uniform and names the package. The
 * held value is the package's own state, created by the package at its own
 * module scope; nothing here is shared between packages or with core.
 *
 * `get` throwing on an unset context is deliberate: it means either activation
 * never ran (a wiring bug in the tier that mounted this content) or a module
 * read the context at import time instead of first use — both bugs worth a
 * loud, named failure over an undefined that surfaces three calls later.
 */
interface PluginContextHolder<T> {
  set(context: T): void
  get(): T
}

export function createPluginContextHolder<T>(packageName: string): PluginContextHolder<T> {
  let held: T | undefined
  return {
    set(context) {
      held = context
    },
    get() {
      if (held === undefined) {
        throw new Error(
          `content-type package "${packageName}" read its plugin context before activate() ran`
        )
      }
      return held
    }
  }
}
