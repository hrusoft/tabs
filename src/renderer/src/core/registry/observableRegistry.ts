/**
 * The Map + subscribers + version machinery both id-keyed registries share:
 * `contentRegistry` (./registry.ts) and the Settings window's page registry
 * (settings/settingsPageRegistry.ts).
 *
 * The two *instances* stay separate on purpose — they sit on opposite sides
 * of an import-graph boundary, which settingsPageRegistry.ts's module doc
 * explains — but the mechanics used to be hand-copied, so a fix to one (a
 * notify rule, the duplicate-id check) could silently miss the other. Only
 * the mechanics live here; what each registry *means* stays with it.
 */
export interface ObservableRegistry<T> {
  /** Claims `id`. A duplicate is a conflict, not a remount — it throws. */
  add(id: string, value: T): void
  /** Removes `id`, notifying only if it was actually present. */
  remove(id: string): void
  get(id: string): T | undefined
  has(id: string): boolean
  /** Every value, in insertion order. */
  values(): T[]
  /** Monotonic counter bumped on every add/remove; a useSyncExternalStore snapshot. */
  version(): number
  subscribe(listener: () => void): () => void
}

export function createObservableRegistry<T>(
  duplicateMessage: (id: string) => string
): ObservableRegistry<T> {
  const entries = new Map<string, T>()
  const listeners = new Set<() => void>()
  let version = 0

  function notify(): void {
    version++
    for (const listener of listeners) listener()
  }

  return {
    add(id, value) {
      if (entries.has(id)) throw new Error(duplicateMessage(id))
      entries.set(id, value)
      notify()
    },
    remove(id) {
      if (entries.delete(id)) notify()
    },
    get: (id) => entries.get(id),
    has: (id) => entries.has(id),
    values: () => [...entries.values()],
    version: () => version,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
