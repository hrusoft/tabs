import type { ContentRendererDef } from '@tabs/plugin-sdk/renderer/registry'

export type {
  ContentRendererDef,
  ContentRendererProps,
  ControlDescribeResult,
  PaneCreationAction
} from '@tabs/plugin-sdk/renderer/registry'

import type { ContentNode } from '@tabs/plugin-sdk/shared/model/types'
import { createObservableRegistry } from './observableRegistry'

/**
 * Maps content types to renderers. Content is data ({ type, ... }); whoever
 * wants to display a new kind of content registers a renderer here — nothing
 * in the dispatch path needs to change. `subscribe` makes late registration
 * (e.g. future plugins) reactive for UI built on useSyncExternalStore. The
 * observable machinery is the shared factory's (see observableRegistry.ts);
 * this class keeps only what a *content* registry means.
 */
export class ContentRegistry {
  private store = createObservableRegistry<ContentRendererDef>(
    (type) => `Content renderer already registered for type "${type}"`
  )

  register<N extends ContentNode>(def: ContentRendererDef<N>): void {
    this.store.add(def.type, def as unknown as ContentRendererDef)
  }

  /**
   * Test isolation only — nothing in the running app unregisters a type
   * (disabling one is a creation gate, never an unregistration; see
   * shared/content/enablement.ts).
   */
  unregister(type: string): void {
    this.store.remove(type)
  }

  get(type: string): ContentRendererDef | undefined {
    return this.store.get(type)
  }

  has(type: string): boolean {
    return this.store.has(type)
  }

  /**
   * Every def in registration order. Order is a contract: the empty-pane
   * toolbar and the Cmd+P palette list creation actions in this order, so
   * registerBuiltins' sequence is that order. (Unregister + re-register moves
   * a def to the end.)
   */
  list(): ContentRendererDef[] {
    return this.store.values()
  }

  /** Monotonic counter bumped on every (un)register; a useSyncExternalStore snapshot. */
  getVersion(): number {
    return this.store.version()
  }

  subscribe(listener: () => void): () => void {
    return this.store.subscribe(listener)
  }
}

export const contentRegistry = new ContentRegistry()

/**
 * `useSyncExternalStore` arguments for the registry above, as stable identities.
 *
 * Module scope, not inline at the call site: an inline arrow is a fresh
 * identity on every render, which React answers by tearing the subscription
 * down and re-establishing it each time — for every mounted empty pane
 * (creationActions.ts) and every node in the layout tree (ContentView.tsx). They live here rather than in either consumer because
 * both need them and a second hand-written copy would only be a second thing
 * to keep stable. The arrow wrappers are what bind `this`, which is why a bare
 * method reference can't be passed instead — the settings-side sibling
 * (settings/settingsPageRegistry.ts) is a module rather than a class, so its
 * exported functions are already stable and need no equivalent.
 */
export const subscribeToRegistry = (onChange: () => void): (() => void) =>
  contentRegistry.subscribe(onChange)

export const registryVersion = (): number => contentRegistry.getVersion()
