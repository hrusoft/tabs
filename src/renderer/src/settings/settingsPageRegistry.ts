import type { ContentTypeId } from '@shared/content/registry'
import type { ComponentType } from 'react'
import { createObservableRegistry } from '../core/registry/observableRegistry'

/** One sidebar entry in the Settings window, and the page it opens. */
export interface SettingsPageDef {
  /** Feeds the `settings-tab-${id}` test id; the page component owns its own `settings-page-${id}`. */
  id: string
  label: string
  Icon: ComponentType
  Component: ComponentType
  /** Sidebar position — pages sort by this, then by label. Core pages pin the ends (General 0, Skills 100); content types sit between. */
  order: number
  /**
   * The content type this page configures, if any — set it and the page
   * disappears from the sidebar while that type is turned off (see
   * SettingsWindow.tsx). Core's own pages leave it absent.
   *
   * Declared rather than inferred from `id`. The two happen to be equal today,
   * but that is a page's choice of id, not a rule: a type that registered a
   * second page, or named its page anything else, would silently stop being
   * hidden — and inferring it would also leave the registry knowing that a page
   * id may be a content type id, which is the one thing it is otherwise careful
   * not to know.
   */
  contentType?: ContentTypeId
}

/**
 * Maps page ids to Settings-window pages — the settings-side sibling of
 * core/registry/registry.ts's contentRegistry, so a content type contributes
 * its settings page instead of core listing it in a hardcoded sidebar. A
 * separate registry rather than a field on ContentRendererDef because the
 * Settings window is its own entry point (settings-main.tsx) that never runs
 * registerBuiltins() — hanging pages off the renderer defs would make the
 * Settings window import every content renderer (xterm and all) just to
 * draw a sidebar. `subscribe`/`getVersion` make late registration (e.g.
 * future plugins) reactive for useSyncExternalStore, same as contentRegistry.
 */
const store = createObservableRegistry<SettingsPageDef>(
  (id) => `Settings page already registered for id "${id}"`
)

/**
 * Registers a page. Like contentRegistry (and unlike the reattach-tolerant
 * pane registries), a duplicate id is a conflict, not a remount — it throws.
 *
 * One-way, unlike contentRegistry's `unregister`: nothing has ever removed a
 * settings page. A disabled content type's page is *filtered at render* rather
 * than unregistered, deliberately — see SettingsWindow.tsx, which explains why
 * re-registering on every settings change would churn the store the sidebar
 * subscribes to.
 */
export function registerSettingsPage(def: SettingsPageDef): void {
  store.add(def.id, def)
}

export function hasSettingsPage(id: string): boolean {
  return store.has(id)
}

/** Every registered page in sidebar order. */
export function listSettingsPages(): SettingsPageDef[] {
  return store.values().sort((a, b) => a.order - b.order || a.label.localeCompare(b.label))
}

/** Monotonic counter bumped on every (un)register; a useSyncExternalStore snapshot. */
export function getSettingsPagesVersion(): number {
  return store.version()
}

export function subscribeSettingsPages(listener: () => void): () => void {
  return store.subscribe(listener)
}
