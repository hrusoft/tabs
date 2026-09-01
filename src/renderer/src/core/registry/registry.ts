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
   * Threaded top-down like `insideTabsContent`, computed once in
   * `SplitRenderer` per child (`TabsRenderer` passes both straight through
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
}

/**
 * A content type's "create one of me" button in every pane's chrome (see
 * content/PaneHeaderControls.tsx). Types that shouldn't offer one (empty,
 * tabs, split) simply don't contribute an action.
 */
export interface PaneCreationAction {
  /** Stable id for the header button — an e2e contract (e.g. 'pane-new-terminal-button'). */
  testId: string
  /** Accessible label and tooltip, e.g. 'New terminal'. */
  label: string
  Icon: ComponentType
  /** Fresh default content for a press of the header button. */
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
  /** Offer a pane-header button that creates fresh content of this type. */
  createAction?: PaneCreationAction
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
