export type NodeId = string

export type SplitDirection = 'horizontal' | 'vertical'

/**
 * Where a dragged tab docks relative to a pane: an edge zone splits the pane
 * and the tab lands in the new half; `center` merges it into the pane's tabs.
 */
export type DockZone = 'left' | 'right' | 'top' | 'bottom' | 'center'

/** A single tab: a title plus the content it displays. */
export interface Tab {
  id: NodeId
  title: string
  content: ContentNode
}

/** Built-in content type: a group of tabs, one of which is active. */
export interface TabsContent {
  id: NodeId
  type: 'tabs'
  tabs: Tab[]
  activeTabId: NodeId | null
}

/**
 * Built-in content type: a container split into resizable sections.
 * `sizes` are fractions of the container that sum to 1, one per child.
 */
export interface SplitContent {
  id: NodeId
  type: 'split'
  direction: SplitDirection
  children: ContentNode[]
  sizes: number[]
}

/**
 * Any other registered content type. `config` is an opaque payload
 * interpreted by the renderer registered for `type`. `title`, when set, is
 * shown as the pane header label instead of the derived content-type label
 * (see `paneTitleForContent`) — unset means "use the derived content-type
 * label". It can come from two sources: a user-chosen override, or (for a
 * terminal leaf) the running process's own reported title. `titleIsManual`
 * tells them apart — true means the user set it explicitly and it should
 * stick regardless of what the process reports next.
 */
export interface LeafContent {
  id: NodeId
  type: string
  config: Record<string, unknown>
  // `| undefined` is deliberate under exactOptionalPropertyTypes: an explicit
  // undefined is how renamePane/setLiveTitle store "cleared" in memory, and
  // JSON persistence drops the key either way.
  title?: string | undefined
  titleIsManual?: boolean
  /**
   * Set on panes an external agent created (see the renderer's
   * externalControl createBrowserPane handler). Read by
   * core/registry/paneHandles.ts to exempt the pane from the mount-time
   * auto-focus a newly active pane otherwise gets, so an agent opening a
   * pane never yanks the keyboard away from the terminal the user is typing
   * in. The live "is this pane currently controlled" signal shown in pane
   * chrome (see controlStore.ts) is a separate, dynamic concept tracked by
   * main's ownership ledger, not this flag — this one is permanent, set once
   * at creation. First-class rather than a key in `config` because it's
   * cross-type metadata like `title` — `config` stays an opaque payload for
   * the type's own renderer.
   */
  agentCreated?: boolean
}

export type ContentNode = TabsContent | SplitContent | LeafContent

/**
 * A pane holding nothing yet. The model knows this one leaf type because it is
 * the structural fallback every operation collapses to — an emptied tab group,
 * a removed root — and because opening content into a placeholder is a fill
 * rather than a conflict (see `openContent`).
 */
export const EMPTY_TYPE = 'empty'

export function isTabs(node: ContentNode): node is TabsContent {
  return node.type === 'tabs'
}

export function isSplit(node: ContentNode): node is SplitContent {
  return node.type === 'split'
}

export function isEmpty(node: ContentNode): node is LeafContent {
  return node.type === EMPTY_TYPE
}

/**
 * True when `value` is plausibly a ContentNode: enough to hand to `normalize`
 * without it throwing on a `null`/non-object/missing-`type` shape. Anything
 * more specific is `normalize`'s job to repair. The one shape check the
 * deserialization paths share — main's `loadLayout` on the docked root, and
 * `sanitizeFloating` on each floating window's content.
 */
export function isPlausibleNode(value: unknown): value is ContentNode {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { type?: unknown }).type === 'string'
  )
}
