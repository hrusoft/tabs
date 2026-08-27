import { createPluginContextHolder } from '@shared/plugin/contextHolder'
import type { PluginSettingsAccess } from './api'

/**
 * A package's typed view of its own settings blob: the module-scope holder for
 * the scoped `PluginSettingsAccess` its `activate` receives, plus the four
 * operations every settings-bearing package wants over it.
 *
 * A factory for the same reason `createPluginContextHolder` is one (which this
 * builds on): the whole contract was otherwise hand-written per package, and
 * the copies were identical but for their identifiers. The part worth not
 * duplicating is the cast — `get()` hands back `unknown`, and each package's
 * narrowing to its own type is the one unchecked step in the chain. It is
 * sound because main only ever serves blobs that have been through the
 * package's descriptor merge (loadSettings runs every persisted blob through
 * it), and the `?? defaults` fallback is belt-and-braces in the same spirit as
 * settingsStore's defaults spread — an argument that should hold in one place,
 * not once per package.
 *
 * Held here rather than read off the package's pane-window context because a
 * settings-bearing package serves two windows — the pane window (its renderer)
 * and the Settings window (its page) — each activating with its own context
 * type. Both carry the same scoped settings surface, and whichever entry runs
 * in a given window installs it.
 */
export interface TypedSettingsAccess<T> {
  /** Called by each of the package's activates — the pane window's and the Settings window's. */
  install(settings: PluginSettingsAccess): void
  /** The live settings, for non-reactive reads (event handlers). */
  get(): T
  /** Reactive read for components — see PluginSettingsAccess.use for why it's selector-shaped. */
  use<S>(select: (settings: T) => S): S
  /** Merges `patch` over the current settings and persists the result as one whole blob. */
  update(patch: Partial<T>): void
}

export function createTypedSettingsAccess<T>(
  packageName: string,
  defaults: T
): TypedSettingsAccess<T> {
  const access = createPluginContextHolder<PluginSettingsAccess>(`${packageName} (settings access)`)
  const coerce = (blob: unknown): T => (blob as T | undefined) ?? defaults
  const read = (): T => coerce(access.get().get())
  return {
    install: (settings) => access.set(settings),
    get: read,
    use: (select) => access.get().use((blob) => select(coerce(blob))),
    update: (patch) => access.get().update({ ...read(), ...patch })
  }
}
