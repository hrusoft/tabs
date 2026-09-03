import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import type { NavDirection } from '@shared/model/navigation'
import type { ContentNode, LeafContent, NodeId, SplitDirection } from '@shared/model/types'
import type { PaneHandle } from '../core/registry/paneHandles'
import type { ContentRendererDef } from '../core/registry/registry'

/**
 * The renderer-process plugin API — the one core module a content-type package
 * may import in a pane window, and the complete statement of what a package
 * may do there.
 *
 * A package receives a `RendererPluginContext` through its renderer `activate`
 * entry (called by content/registerBuiltins.ts) and reaches core exclusively
 * through it: the registries, the stores and the layout operations stay
 * core-internal, and what a plugin can touch is exactly what this file names.
 * The types are re-exports where core already had the right shape — the
 * contract is the surface, not a parallel copy of it.
 *
 * Values arrive on the context; this module exports only types plus one pure
 * helper. That split is what keeps the boundary auditable: a plugin file's
 * imports from core are type-only or stateless, and everything stateful is
 * handed over at activation, in one place, by core.
 *
 * Deliberately unversioned: the built-in packages update with core in the same
 * commit, and a compatibility story before an external loader exists would be
 * ceremony with no consumer.
 */

// Pure and core-stateless, so it needs no context ride: the instances a
// reattach registry holds are the package's own.
export {
  createReattachRegistry,
  REATTACH_GRACE_MS,
  type ReattachRegistry
} from '../content/reattachRegistry'
export type { PaneCapabilities, PaneHandle } from '../core/registry/paneHandles'
export type {
  ContentRendererDef,
  ContentRendererProps,
  PaneCreationAction
} from '../core/registry/registry'
// The labeled icon-only button (see IconButton.tsx) — pure and core-stateless
// like the exports above, so it rides the same rule: a package's icon-only
// buttons are IconButtons exactly as core's are, rather than a second
// implementation or a bare `title` (see Tooltip.tsx for why that alone is
// not enough on this app's pinned Electron version).
export { IconButton } from '../IconButton'
// A package's typed view of its own settings blob. A stateless factory, like
// createReattachRegistry above — the state it makes is the package's own.
export { createTypedSettingsAccess, type TypedSettingsAccess } from './typedSettings'

/**
 * A verb handler as a package registers it: receives its own narrowed
 * request, returns the answer, never touches the transport (a throw becomes
 * the error response — content/externalControl.ts owns dispatch).
 */
export type PluginControlVerbHandler<V extends ControlRequest['type']> = (
  request: Extract<ControlRequest, { type: V }>
) => ControlResponse | Promise<ControlResponse>

/**
 * The layout operations a package may perform, phrased as actions on the
 * current layout rather than access to the store: no plugin sees the zustand
 * store, subscribes to it, or learns that floating panes live outside `root`.
 * Reads go through `findNode`/`allRoots`, which already walk the whole forest
 * (docked root plus every floating tree) — the CLAUDE.md trap about
 * `findNode(state.root, …)` missing unpinned panes cannot be reintroduced
 * through this surface.
 */
export interface PluginLayoutAccess {
  /** Merges `config` keys onto the leaf's config (e.g. the browser tracking its live URL). */
  setLeafConfig(nodeId: NodeId, config: Record<string, unknown>): void
  /** Live title for the pane's tab/header (e.g. a shell's OSC title, a page's <title>). */
  setLiveTitle(nodeId: NodeId, title: string): void
  /** Activates the pane — the same action a user click performs, focus-follows-active included. */
  setActivePane(id: NodeId): void
  closePane(nodeId: NodeId): void
  /** The node for `id`, searched across the docked tree and every floating window. */
  findNode(id: NodeId): ContentNode | null
  /** Every layout root: the docked tree first, then each floating window's own tree. */
  allRoots(): ContentNode[]
  /**
   * Places fresh content at `targetId` — a new tab (direction omitted) or a
   * split (direction given) — the docking path agent creation shares.
   */
  placeNewPane(targetId: NodeId, content: ContentNode, direction?: SplitDirection): void
  /** Places fresh content in its own floating (unpinned) window, spawned near `originId`. */
  placeNewUnpinnedPane(originId: NodeId, content: ContentNode): void
  /** Makes an existing pane visible (ancestor tabs, float raise) without taking focus. */
  revealPane(paneId: NodeId): void
}

/**
 * The package's IPC surface, scoped to its own type by construction: every
 * call lands on a `plugin:<own type>:` channel (see shared/plugin/bridge.ts),
 * so a package can neither reach core channels nor another package's. The
 * untyped `unknown`s are deliberate — the package's typed client is where the
 * narrowing lives, the same one-cast rule as its settings accessor.
 */
export interface PluginIpc {
  /** Calls a method the package's main entry registered with `ipc.handle`. */
  invoke(method: string, ...args: unknown[]): Promise<unknown>
  /** Fire-and-forget to a method registered with `ipc.on`. */
  send(method: string, ...args: unknown[]): void
  /** Subscribes to a main-emitted event (names may embed ids, e.g. `data:<paneId>`); returns the unsubscribe. */
  on(event: string, listener: (...args: unknown[]) => void): () => void
}

/**
 * The package's own settings blob, scoped by construction: a package can
 * reach no other type's settings and no core setting through this. The blob
 * is served raw (`unknown`) on purpose — main has already run the package's
 * own descriptor merge over anything persisted, and the package's typed
 * accessor is where the one narrowing cast lives (see the terminal's
 * terminalSettingsAccess.ts, which documents why that cast is sound).
 */
export interface PluginSettingsAccess {
  /** Snapshot for non-reactive reads (event handlers). */
  get(): unknown
  /**
   * Reactive read for components — a React hook, subject to the rules of
   * hooks. Takes a selector rather than returning the blob so re-renders key
   * on the selected value: a package's write replaces its blob wholesale, but
   * untouched sub-objects keep their identity through the spread, so a
   * component selecting `.appearance` doesn't re-render when an unrelated
   * toggle in the same blob flips.
   */
  use<T>(select: (blob: unknown) => T): T
  /** Replaces the blob wholesale and persists it — always pass a COMPLETE blob. */
  update(blob: unknown): void
}

/**
 * What core lends a content-type package in a pane window. Handed to the
 * package's renderer `activate` once, before the first render; a package that
 * needs it outside activation scope holds it in its own module state.
 */
export interface RendererPluginContext {
  /**
   * Registers the package's renderer. The def's `type` must be the package's
   * own — a context is bound to one content type at creation, which is also
   * what scopes `settings` and `isEnabled` below. Generic for the same
   * reason contentRegistry.register is: a def is typically written against
   * `LeafContent`, and the widening to the registry's stored shape is core's
   * to perform, not the package's to cast.
   */
  registerContent<N extends ContentNode>(def: ContentRendererDef<N>): void
  /**
   * Claims an external-control verb for this window. Names are global to the
   * protocol and a duplicate throws — one owner per verb, the same rule as
   * main's registry.
   */
  registerControlVerb<V extends ControlRequest['type']>(
    verb: V,
    handler: PluginControlVerbHandler<V>
  ): void
  /**
   * The working directory some other pane is showing, asked of whichever type
   * owns it — the read side of `ContentRendererDef.exposeCwd`, for
   * `deriveConfig` hooks. Undefined is the ordinary answer; degrade, don't
   * throw.
   */
  exposedCwdOf(leaf: LeafContent): Promise<string | undefined>
  /** Feeds core's spatial navigation a press core structurally cannot hear (see guestNavKeys.ts). */
  dispatchNavChord(direction: NavDirection): void
  /**
   * Opens a URL in the OS browser. A request, not a capability: main
   * re-validates through openExternalUrl, which drops anything that isn't
   * http(s)/mailto, so a package cannot launch arbitrary schemes.
   */
  openExternal(url: string): void
  /** Whether this package's content type is currently enabled (Settings → General → Content types). */
  isEnabled(): boolean
  /** Mounted-instance handles: focus/blur plumbing and per-type extensions. */
  panes: {
    /** Registers the mounted handle for a pane; returns the unregister function. */
    registerHandle(id: NodeId, handle: PaneHandle): () => void
    /** The mounted handle, or undefined if no renderer currently holds that pane. */
    getHandle(id: NodeId): PaneHandle | undefined
  }
  layout: PluginLayoutAccess
  /**
   * Reports a bell in a pane. Core owns every gate and surfacing: the in-app
   * indicator (skipped while the user is looking at that pane, or when the
   * indicator setting is off) and the OS-level Dock bounce (focus-gated in
   * main). `clear` drops the indicator once the pane is attended.
   */
  bell: {
    ring(id: NodeId): void
    clear(id: NodeId): void
  }
  ipc: PluginIpc
  settings: PluginSettingsAccess
}
