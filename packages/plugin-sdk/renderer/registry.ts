import type { ComponentType } from 'react'
import type { ContentNode, LeafContent } from '../shared/model/types'
import type { PaneHandle } from './paneHandles'

/**
 * The content-renderer contract a package's `registerContent` call must
 * satisfy — pure types. The registry itself (`ContentRegistry`,
 * `contentRegistry`, `subscribeToRegistry`/`registryVersion`) is stateful
 * and stays core-owned, in `src/renderer/src/core/registry/registry.ts`,
 * which imports these types back.
 */

export interface ContentRendererProps<N extends ContentNode = ContentNode> {
  node: N
  /**
   * Whether *some* descendant of this node — however deeply nested through
   * tabs and splits — sits at the window's true bottom-left/bottom-right
   * corner and should carry OS-radius rounding there once it's actually
   * rendered as a `.pane`. Only `TabsRenderer` and `SplitRenderer` read
   * these — every other content type ignores them.
   */
  cornerLeft?: boolean | undefined
  cornerRight?: boolean | undefined
  /**
   * Whether this node's own eventual `.pane` should suppress its border on
   * that side because it sits flush against an ancestor tabs-group's own
   * border, with no split having introduced a real seam there yet.
   */
  suppressBorderLeft?: boolean | undefined
  suppressBorderRight?: boolean | undefined
  suppressBorderBottom?: boolean | undefined
}

/**
 * A content type's "create one of me" action — offered by an empty pane's
 * own toolbar and the Cmd+P command palette. Types that shouldn't offer one
 * (empty, tabs, split) simply don't contribute an action.
 */
export interface PaneCreationAction {
  /** Stable id for the creation button/list item — an e2e contract (e.g. 'pane-new-terminal-button'). */
  testId: string
  /** Accessible label and tooltip, e.g. 'New terminal'. */
  label: string
  Icon: ComponentType
  /** Fresh default content for a press of the creation button. */
  createContent(): ContentNode
}

export interface ContentRendererDef<N extends ContentNode = ContentNode> {
  /** Content type this renderer handles (matches ContentNode.type). */
  type: string
  /** Human-readable name — titles the tabs/panes holding this content. */
  displayName: string
  /**
   * Rendered once per leaf of this type (by core's ContentView). Core's DOM
   * guarantee: a mounted leaf's DOM stays where it is for as long as the
   * leaf itself does. Creating, closing, reordering, switching, resizing or
   * raising *other* panes never moves it — short of a close that collapses
   * its container into it, below — and an inactive tab stays mounted, just
   * `hidden`, so it has no layout: size-dependent work (fitting, measuring)
   * must wait until it is shown. Content whose state is bound to its DOM
   * node relies on this; any structural move of a `<webview>` destroys its
   * guest and reloads the page.
   *
   * The component is unmounted and remounted, by construction, when the
   * leaf itself changes place: dragged to another split or tab group,
   * wrapped into a tab group, unpinned or pinned back, or promoted when its
   * split or tab group collapses into it after its only sibling closes. The
   * remount follows at once, so an instance kept outside React in a
   * `createReattachRegistry` store survives it (the terminal's xterm does);
   * state bound to the DOM node does not. A move to another window mounts a
   * fresh component in that window's renderer, from the leaf's `config` plus
   * whatever the `captureTransferState` capability carried; an app restart
   * mounts one from the persisted `config` alone.
   *
   * Core keeps this by never reordering or re-keying siblings that may hold
   * a leaf: TabsRenderer renders panels in first-seen order, FloatingLayer
   * renders windows in a stable order stacked by `z-index`, and
   * SplitRenderer's panel group is unkeyed. Pinned by
   * e2e/external-control.spec.ts ("creating and closing split-placed panes
   * leaves an existing browser pane untouched").
   */
  Component: ComponentType<ContentRendererProps<N>>
  /**
   * Closing this content may destroy live work: before closing a subtree
   * with leaves of this type, core asks the main process whether any of
   * them currently block a close. Absent means closes of this type are
   * always silent.
   */
  mayBlockClose?: boolean | undefined
  /** Offer a creation action (empty-pane toolbar, command palette) for this type. */
  createAction?: PaneCreationAction
  /**
   * An extra control this content type contributes to its own pane's
   * chrome — rendered leftmost inside the pane header's controls row.
   * `leaf` is the hook's own pane's content.
   */
  HeaderControl?: ComponentType<{ leaf: LeafContent }>
  /**
   * Replaces the pane header's entire title slot with this content type's
   * own interactive chrome. Absent means the slot renders through the
   * default title component exactly as it always has.
   */
  HeaderTitle?: ComponentType<{ leaf: LeafContent }>
  /**
   * Refine the config of content **of this type** that core is creating
   * from some origin pane. A non-undefined result is merged over the config
   * already assembled; undefined keeps it as-is. A rejection propagates and
   * aborts the creation.
   *
   * The hook belongs to the type being created, not to the origin — see
   * `exposeCwd` below for the cross-type counterpart.
   */
  deriveConfig?:
    | ((originLeaf: LeafContent) => Promise<Record<string, unknown> | undefined>)
    | undefined
  /**
   * The working directory a pane of this type is currently showing, if the
   * notion means anything for it — for a pane of a *different* type being
   * created from it. Undefined means "no directory to offer".
   */
  exposeCwd?(leaf: LeafContent): Promise<string | undefined>
  /**
   * This type's contribution to `listOwnedPanes`'s per-pane summary —
   * cheap, synchronous, and read off the leaf's persisted `config` alone.
   * Undefined omits the pane from the list entirely.
   */
  listSummaryForControl?(leaf: LeafContent): Record<string, unknown> | undefined
  /**
   * This type's contribution to `getPaneInfo`'s full, live-read response.
   * `handle` is the pane's current `PaneHandle`, or undefined if nothing is
   * currently mounted for this leaf.
   */
  describeForControl?(
    leaf: LeafContent,
    handle: PaneHandle | undefined
  ): ControlDescribeResult | Promise<ControlDescribeResult> | undefined
}

/** `ContentRendererDef.describeForControl`'s return shape — see its doc for what each case means. */
export type ControlDescribeResult = { fields: Record<string, unknown> } | { error: string }
