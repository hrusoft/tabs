import type { ContentNode, LeafContent } from '@shared/model/types'
import type { ComponentType } from 'react'
import { createObservableRegistry } from './observableRegistry'

export interface ContentRendererProps<N extends ContentNode = ContentNode> {
  node: N
  /**
   * Whether *some* descendant of this node — however deeply nested through
   * tabs and splits — sits at the window's true bottom-left/bottom-right
   * corner and should carry OS-radius rounding there once it's actually
   * rendered as a `.pane` (see `Pane`'s corresponding props, and
   * `--pane-corner-radius-left/-right` in global.css). Only `TabsRenderer`
   * and `SplitRenderer` read these — every other content type ignores them.
   *
   * Threaded top-down, computed once in `SplitRenderer` per child (`TabsRenderer` passes both straight through
   * unchanged, since a tabs-group's revealed content is always exactly as
   * wide as its bar) rather than left for CSS to reconstruct: a plain CSS
   * inheritance/selector chain has no way to *reset* a value it never had a
   * `.pane` to reset it at — a split node has none of its own (see
   * `ContentView`'s `if (node.type === 'split') return content`) — so a
   * value could ride unreset through an arbitrary depth of nested splits
   * and land on a geometrically wrong corner. Measured directly: an
   * L-shaped layout (one pane filling the left column, the right column
   * split top/bottom) rounded *both* bottom corners of the bottom-right
   * pane, not just its own.
   */
  cornerLeft?: boolean | undefined
  cornerRight?: boolean | undefined
  /**
   * Whether this node's own eventual `.pane` should suppress its border on
   * that side because it sits flush against an ancestor tabs-group's own
   * border, with no split having introduced a real seam there yet. Starts
   * as all three `true` at a `TabsRenderer`'s tab content — set there for
   * every tab, whatever the content's type: suppression is positional, never
   * by node type — and must be threaded through a `split` the same way
   * cornerLeft/cornerRight are — a split
   * contributes no `.pane` of its own to reset a value at, so `SplitRenderer`
   * derives each child's flags from its own (per axis: the side(s) that
   * child's edge doesn't actually touch flip to `false`, since that's now a
   * real seam against a sibling). Getting this wrong either direction is
   * visible: never deriving it (the bug this fixed — a lone pane's content
   * shifted a pixel the moment it was split, because the surviving pane
   * suddenly drew a border on sides that used to be flush with its tabs-
   * group's own) or deriving it unconditionally (double-suppressing a real
   * seam between two split siblings, collapsing their divider to 0px).
   */
  suppressBorderLeft?: boolean | undefined
  suppressBorderRight?: boolean | undefined
  suppressBorderBottom?: boolean | undefined
}

/**
 * A content type's "create one of me" action — offered by an empty pane's
 * own toolbar (content/empty/EmptyPaneRenderer.tsx) and the Cmd+P command
 * palette (content/CommandPalette.tsx). Types that shouldn't offer one
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
  /** Human-readable name — titles the tabs/panes holding this content (see titles.ts). */
  displayName: string
  Component: ComponentType<ContentRendererProps<N>>
  /**
   * Closing this content may destroy live work: before closing a subtree with
   * leaves of this type, core asks the main process whether any of them
   * currently block a close (see content/closeConfirmation.ts and
   * main/closeBlockers.ts). Absent means closes of this type are always
   * silent.
   */
  mayBlockClose?: boolean | undefined
  /** Offer a creation action (empty-pane toolbar, command palette) for this type. */
  createAction?: PaneCreationAction
  /**
   * An extra control this content type contributes to its own pane's chrome
   * — rendered leftmost inside PaneHeaderControls' `.pane-header-controls`
   * row, ahead of the always-present "Split horizontally" group (see
   * content/PaneHeaderControls.tsx). Absent means that row starts with that
   * group exactly as it does today — declaring this costs every other type
   * nothing.
   *
   * Two things hold for both header hooks, this one and `HeaderTitle` below.
   *
   * `leaf` is the hook's own pane's content, and the pane's live state is
   * reached through the declaring package's own machinery — never a new
   * cross-type lookup added to core: its context's `panes.getHandle`
   * narrowed to its own extension (the terminal's ClearScrollbackControl
   * reads the very `clear` Cmd/Ctrl+K dispatches), or a
   * `createPaneValueStore` its body publishes into (the browser's
   * `<webview>` instance, the git tree's HEAD). Mind mount order for the
   * latter: Pane.tsx renders the header slot before `{children}`, so a
   * hook's own mount effect runs *before* the body's — a one-time read at
   * mount will not see anything the body creates lazily; a subscription
   * will.
   *
   * Both render inside `.pane-header`, whose own `pointerdown` arms a pane
   * drag. The header ignores a press that lands on an interactive element (a
   * button, an input, a select — see Pane's `onHeaderPointerDown`), so a
   * control needs no handlers of its own for that; `HeaderButton`
   * (PaneHeaderMenuGroup.tsx, re-exported from plugin/api.ts) is the
   * primitive for a plain button, the same one every built-in header button
   * is made of.
   */
  HeaderControl?: ComponentType<{ leaf: LeafContent }>
  /**
   * Replaces the pane header's entire title slot — the `.pane-title` span
   * and its `InlineTitleEditor` swap (see DefaultPaneTitle.tsx) — with this
   * content type's own interactive chrome. The browser's back/forward/
   * refresh/address bar is the reference implementation
   * (BrowserHeaderTitle.tsx): it used to be the pane body's own separate
   * toolbar and now *is* the header, with nothing left in the body but the
   * `<webview>`. Absent means the slot renders through `DefaultPaneTitle`
   * exactly as it always has, and the header's right-click "Edit title"
   * entry keeps working.
   *
   * Declaring `HeaderTitle` takes over both: `DefaultPaneTitle`'s rename
   * affordances (double-click, the "Edit title" context-menu entry) do not
   * apply once a type supplies its own title chrome, since this component
   * now occupies that slot and no assumption is made about what "renaming"
   * would even mean for it (see Pane.tsx, which drops the menu entry
   * whenever this hook is present).
   *
   * Rendered directly inside `.pane-header`'s own flex row (unlike
   * `HeaderControl`, which lands inside `PaneHeaderControls`' own row) — a
   * single element or a fragment of several are both fine, since either way
   * its children become flex items of that row alongside the grip/icons/
   * controls. Whichever piece is meant to fill the remaining space needs
   * `flex: 1; min-width: 0` (`.pane-title`'s own rule, global.css) —
   * `DefaultPaneTitle` puts it on its one root; `BrowserHeaderTitle` puts it
   * on the address bar alone, leaving its three nav buttons fixed-size
   * siblings ahead of it. Nothing else in `.pane-header`'s flex row claims
   * that space on its own.
   *
   * Pane-header only: a tab group's own chrome is TabBar, not Pane, and has
   * no title slot of any kind to replace (a tab chip's inline-rename is
   * unrelated, driven by `renameTab`/`tab.title`) — this hook is never read
   * there.
   */
  HeaderTitle?: ComponentType<{ leaf: LeafContent }>
  /**
   * Refine the config of content **of this type** that core is creating from
   * some origin pane — a split, a new tab, Cmd/Ctrl+T (content/contentLike.ts),
   * or a press of another type's creation button (content/createFrom.ts). A
   * non-undefined result is merged over the config already assembled;
   * undefined keeps it as-is. A rejection propagates and aborts the creation.
   *
   * **The hook belongs to the type being created, not to the origin**, and
   * that distinction is the whole reason `exposeCwd` below exists. Through
   * `createContentLike` the two are the same type by construction (it clones
   * the origin), which made this look like an origin-side hook for a long
   * time — long enough for a ticket to be written against that reading. It
   * isn't: through a creation button the origin can be any type at all, and
   * `applyDerivedConfig` resolves the hook off the *created* content either
   * way.
   *
   * So a hook that wants something from an origin of an unknown type must ask
   * for it through a capability the origin's own def declares, rather than
   * reaching into `originLeaf.config` and hoping.
   */
  deriveConfig?:
    | ((originLeaf: LeafContent) => Promise<Record<string, unknown> | undefined>)
    | undefined
  /**
   * The working directory a pane of this type is currently showing, if the
   * notion means anything for it — **for a pane of a *different* type being
   * created from it**.
   *
   * This is the cross-type counterpart to `deriveConfig`: that one is asked of
   * the type being *created*, this one of the type being created *from*. A git
   * tree opened from a terminal reads the shell's live cwd through here, and a
   * terminal opened from a git tree lands in that repository, without either
   * type importing the other or core naming a single type.
   *
   * Implementations answer for the leaf they are handed, which is not
   * necessarily mounted — the terminal asks main for the pty's live directory
   * (`config.cwd` is a stale snapshot after any `cd`), while a git tree simply
   * reports its configured one. Undefined means "no directory to offer", which
   * is also what every type that declares nothing here answers; a caller must
   * degrade rather than treat it as an error. Read it through
   * `content/exposedCwd.ts` rather than reaching into the registry directly.
   */
  exposeCwd?(leaf: LeafContent): Promise<string | undefined>
}

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
   * Every def in registration order. Order is a contract: pane-header
   * creation buttons render in this order, so registerBuiltins' sequence is
   * the button order. (Unregister + re-register moves a def to the end.)
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
 * down and re-establishing it each time — for every mounted pane
 * (PaneHeaderControls.tsx) and every node in the layout tree
 * (ContentView.tsx). They live here rather than in either consumer because
 * both need them and a second hand-written copy would only be a second thing
 * to keep stable. The arrow wrappers are what bind `this`, which is why a bare
 * method reference can't be passed instead — the settings-side sibling
 * (settings/settingsPageRegistry.ts) is a module rather than a class, so its
 * exported functions are already stable and need no equivalent.
 */
export const subscribeToRegistry = (onChange: () => void): (() => void) =>
  contentRegistry.subscribe(onChange)

export const registryVersion = (): number => contentRegistry.getVersion()
