/**
 * A keyed store of live UI instances kept alive outside React, so a quick
 * unmount/remount (a drag-and-drop move, a tab promoting/collapsing into or
 * out of a group, a sibling split pane changing) reattaches to the same
 * instance instead of building a fresh one. See terminalRegistry.ts and
 * browserRegistry.ts for what each instance type preserves by surviving.
 */
export interface ReattachRegistry<T> {
  /** Returns the live instance for `id`, creating it via `create` on first use. */
  acquire(id: string, create: () => T): T
  /** Schedules `id`'s instance for real disposal after the grace period, unless re-acquired first. */
  release(id: string, dispose: (instance: T) => void): void
  /**
   * Forgets `id`'s instance at once, no grace period, and runs `cleanup` on
   * it — for a resource moving to another window rather than ending.
   * `cleanup` tears down local state only (the xterm object, its DOM, its
   * listeners); unlike `release`'s `dispose` it must not reach the remote
   * resource, which now belongs to whoever reattaches it.
   */
  abandon(id: string, cleanup: (instance: T) => void): void
}

// The grace period both registries pass in — see @shared/reattach for the
// number and why it lives there.
export { REATTACH_GRACE_MS } from '@shared/reattach'

export function createReattachRegistry<T>(graceMs: number): ReattachRegistry<T> {
  interface Entry {
    instance: T
    disposeTimer: ReturnType<typeof setTimeout> | null
  }
  const instances = new Map<string, Entry>()

  return {
    acquire(id, create) {
      const existing = instances.get(id)
      if (existing) {
        if (existing.disposeTimer !== null) {
          clearTimeout(existing.disposeTimer)
          existing.disposeTimer = null
        }
        return existing.instance
      }
      const instance = create()
      instances.set(id, { instance, disposeTimer: null })
      return instance
    },

    release(id, dispose) {
      const entry = instances.get(id)
      if (!entry) return
      // Idempotent: a second release without a re-acquire keeps the first
      // timer rather than scheduling another. acquire clears only the
      // recorded timer, so an extra one would become an orphan that later
      // fires and disposes a live, re-acquired instance.
      if (entry.disposeTimer !== null) return
      entry.disposeTimer = setTimeout(() => {
        instances.delete(id)
        dispose(entry.instance)
      }, graceMs)
    },

    abandon(id, cleanup) {
      const entry = instances.get(id)
      if (!entry) return
      if (entry.disposeTimer !== null) clearTimeout(entry.disposeTimer)
      instances.delete(id)
      cleanup(entry.instance)
    }
  }
}
