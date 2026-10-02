import type {
  ContentNode,
  LeafContent,
  NavDirection,
  NodeId,
  SplitDirection
} from '../shared/model/types'
import type { ContextMenuItem } from './contextMenu'
import type { ControlVerbHandler, RendererControlVerbTable } from './controlVerbTable'
import type { AlertDialogOptions, ChooseDialogOptions, ConfirmDialogOptions } from './dialogs'
import type { PaneCapabilities, PaneHandle } from './paneHandles'
import type { ContentRendererDef } from './registry'

/**
 * The renderer-process plugin API — the one core module a content-type
 * package may import in a pane window, and the complete statement of what a
 * package may do there.
 *
 * A package receives a `RendererPluginContext` through its renderer
 * `activate` entry (called by content/registerBuiltins.ts) and reaches core
 * exclusively through it: the registries, the stores and the layout
 * operations stay core-internal, and what a plugin can touch is exactly
 * what this file names. The types are re-exports where core already had the
 * right shape — the contract is the surface, not a parallel copy of it.
 *
 * Values arrive on the context; this module exports only types and
 * stateless helpers (pure components and factories whose state is the
 * package's own). That split is what keeps the boundary auditable: a
 * plugin file's imports from core are type-only or stateless, and
 * everything stateful is handed over at activation, in one place, by core.
 *
 * Deliberately unversioned: the built-in packages update with core in the
 * same commit, and a compatibility story before an external loader exists
 * would be ceremony with no consumer.
 */

/**
 * A verb handler as a package registers it: receives its own narrowed
 * request, returns the answer, never touches the transport (a throw becomes
 * the error response — core's content dispatch owns transport).
 */
export type PluginControlVerbHandler<V extends string> = ControlVerbHandler<V>
// The config key a `captureTransferState` snapshot rides under across windows.
export { CROSS_WINDOW_TRANSFER_STATE_KEY } from '../shared/crossWindowTransferKey'
// The pane-header button primitive — pure and core-stateless, and the
// required building block for a ContentRendererDef.HeaderControl/HeaderTitle:
// it already carries the stopPropagation contract those need to avoid
// arming a pane drag.
export { HeaderButton } from './PaneHeaderMenuGroup'
/**
 * Whether focus is inside a pane's own chrome bar — what a content type's
 * `PaneHandle.focus` checks before taking the keyboard, so a click on its
 * own header control (an address bar, a path input) isn't undone by the
 * activation that click also causes.
 */
export { focusIsInPaneChrome } from './paneDom'
/**
 * Per-pane published values — how a type's `HeaderTitle` reads state its
 * body `Component` owns, across the mount-order gap `Pane.tsx` puts between
 * them. Pure and core-stateless like the reattach registry below: each
 * package instantiates its own.
 */
export { createPaneValueStore, type PaneValueStore } from './paneValueStore'
// Pure and core-stateless, so it needs no context ride: the instances a
// reattach registry holds are the package's own.
export {
  createReattachRegistry,
  REATTACH_GRACE_MS,
  type ReattachRegistry
} from './reattachRegistry'
export type {
  ContentRendererDef,
  ContentRendererProps,
  ControlDescribeResult,
  PaneCreationAction
} from './registry'
// A package's typed view of its own settings blob. A stateless factory, like
// createReattachRegistry above — the state it makes is the package's own.
export { createTypedSettingsAccess, type TypedSettingsAccess } from './typedSettings'
/** The three dialog shapes behind `RendererPluginContext.dialogs`. */
/** One right-click menu item (see `RendererPluginContext.contextMenu`). */
export type {
  AlertDialogOptions,
  ChooseDialogOptions,
  ConfirmDialogOptions,
  ContextMenuItem,
  PaneCapabilities,
  PaneHandle,
  RendererControlVerbTable
}

/**
 * The layout operations a package may perform, phrased as actions on the
 * current layout rather than access to the store: no plugin sees the
 * zustand store, subscribes to it, or learns that floating panes live
 * outside `root`.
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
 * call lands on a `plugin:<own type>:` channel, so a package can neither
 * reach core channels nor another package's.
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
 * is served raw (`unknown`) on purpose.
 */
export interface PluginSettingsAccess {
  /** Snapshot for non-reactive reads (event handlers). */
  get(): unknown
  /**
   * Reactive read for components — a React hook, subject to the rules of
   * hooks. Takes a selector rather than returning the blob so re-renders
   * key on the selected value.
   */
  use<T>(select: (blob: unknown) => T): T
  /** Replaces the blob wholesale and persists it — always pass a COMPLETE blob. */
  update(blob: unknown): void
}

/**
 * What core lends a content-type package in a pane window. Handed to the
 * package's renderer `activate` once, before the first render; a package
 * that needs it outside activation scope holds it in its own module state.
 */
export interface RendererPluginContext {
  /**
   * Registers the package's renderer. The def's `type` must be the
   * package's own — a context is bound to one content type at creation.
   */
  registerContent<N extends ContentNode>(def: ContentRendererDef<N>): void
  /**
   * Claims an external-control verb for this window. Names are global to
   * the protocol and a duplicate throws — one owner per verb.
   */
  registerControlVerb<V extends string>(verb: V, handler: PluginControlVerbHandler<V>): void
  /**
   * Claims every verb of a package's own request union in one call, typed
   * against that union rather than against a generic catch-all shape.
   */
  registerControlVerbs<R extends { type: string }>(table: RendererControlVerbTable<R>): void
  /**
   * Resolves a control verb's `targetPaneId` to the live node, for a
   * package whose verbs act on panes of its own type. `ownType` is the
   * caller's own content-type id; the three answers are: the node (still
   * exists and matches `ownType`), a "pane gone" error (no node at all —
   * the user closed it by hand), or a "wrong type" error.
   */
  resolveControlTarget(
    targetPaneId: string,
    ownType: string
  ): { node: ContentNode } | { error: string }
  /**
   * The working directory some other pane is showing, asked of whichever
   * type owns it — the read side of `ContentRendererDef.exposeCwd`.
   */
  exposedCwdOf(leaf: LeafContent): Promise<string | undefined>
  /** Feeds core's spatial navigation a press core structurally cannot hear (see guestNavKeys.ts). */
  dispatchNavChord(direction: NavDirection): void
  /**
   * Opens a URL in the OS browser. A request, not a capability: main
   * re-validates through openExternalUrl.
   */
  openExternal(url: string): void
  /**
   * Puts `text` on the user's system clipboard, for the package's own UI
   * acting on the user's own click. Goes through main, not
   * `navigator.clipboard`.
   */
  copyText(text: string): void
  /** Whether this package's content type is currently enabled (Settings → General → Content types). */
  isEnabled(): boolean
  /** Mounted-instance handles: focus/blur plumbing and per-type extensions. */
  panes: {
    /** Registers the mounted handle for a pane; returns the unregister function. */
    registerHandle(id: NodeId, handle: PaneHandle): () => void
    /** The mounted handle, or undefined if no renderer currently holds that pane. */
    getHandle(id: NodeId): PaneHandle | undefined
    /**
     * A core capability the mounted pane offers (`clear`, `refresh`), or
     * undefined — the same lookup core's own shortcuts dispatch through.
     */
    getCapability<K extends keyof PaneCapabilities>(
      id: NodeId,
      capability: K
    ): PaneCapabilities[K] | undefined
  }
  layout: PluginLayoutAccess
  /**
   * Reports a bell in a pane. Core owns every gate and surfacing.
   */
  bell: {
    ring(id: NodeId): void
    clear(id: NodeId): void
  }
  /**
   * The app's single right-click context menu, usable by any package's own
   * right-click affordance. Opens at `(x, y)`; a second call replaces
   * whatever menu is already open.
   */
  contextMenu: {
    open(x: number, y: number, items: ContextMenuItem[]): void
  }
  /**
   * Three dialog shapes built on the app's one reusable modal shell: a
   * plain confirm, a one-button alert, and a single-select choose.
   */
  dialogs: {
    confirm(options: ConfirmDialogOptions): Promise<boolean>
    alert(options: AlertDialogOptions): Promise<void>
    choose(options: ChooseDialogOptions): Promise<string | null>
  }
  ipc: PluginIpc
  settings: PluginSettingsAccess
}
