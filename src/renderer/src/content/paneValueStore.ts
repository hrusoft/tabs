import type { NodeId } from '@shared/model/types'
import { useCallback, useSyncExternalStore } from 'react'

/**
 * A per-pane value that one component publishes and another reads reactively
 * — what a content type needs when its `HeaderTitle` and its body `Component`
 * are two independently mounted components for one pane (the browser's live
 * `<webview>` instance, the git tree's HEAD).
 *
 * A subscription rather than a one-time read at mount, because of mount
 * order: `Pane.tsx` renders the header slot before `{children}`, so the
 * header's own mount effect runs *before* the body's and would see nothing
 * the body publishes lazily. `use` re-renders once the body's first `set`
 * lands, whichever order the two effects actually ran in.
 *
 * Pure and core-stateless — each package instantiates its own, the way it
 * does a reattach registry — so it rides the plugin API without a context.
 * Not a reattach registry: nothing here outlives an unmount, there is no
 * acquire/release lifecycle, just "publish the latest value, notify readers".
 */
export interface PaneValueStore<T> {
  set(id: NodeId, value: T): void
  delete(id: NodeId): void
  get(id: NodeId): T | undefined
  /** This pane's current value, reactively — a React hook, subject to the rules of hooks. */
  use(id: NodeId): T | undefined
}

export function createPaneValueStore<T>(): PaneValueStore<T> {
  const values = new Map<NodeId, T>()
  const subscribers = new Map<NodeId, Set<() => void>>()

  const notify = (id: NodeId): void => {
    for (const listener of subscribers.get(id) ?? []) listener()
  }

  const subscribe = (id: NodeId, listener: () => void): (() => void) => {
    let set = subscribers.get(id)
    if (!set) {
      set = new Set()
      subscribers.set(id, set)
    }
    set.add(listener)
    return () => {
      set.delete(listener)
      if (set.size === 0) subscribers.delete(id)
    }
  }

  return {
    set: (id, value) => {
      values.set(id, value)
      notify(id)
    },
    delete: (id) => {
      values.delete(id)
      notify(id)
    },
    get: (id) => values.get(id),
    use: (id) => {
      // Stable per id: useSyncExternalStore re-subscribes whenever the
      // subscribe function's identity changes, and a header re-renders on
      // every keystroke in its own input.
      const subscribeTo = useCallback((listener: () => void) => subscribe(id, listener), [id])
      return useSyncExternalStore(subscribeTo, () => values.get(id))
    }
  }
}
