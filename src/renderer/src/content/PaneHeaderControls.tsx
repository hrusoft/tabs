import type { ContentNode, SplitDirection } from '@shared/model/types'
import { isEmpty } from '@shared/model/types'
import { PANE_BUTTON } from '@shared/paneDomAttrs'
import type { PaneCreationAction } from '../core/registry/registry'
import { closeTargetNode, useLayoutStore } from '../core/store/layoutStore'
import { confirmClosingContent } from './closeConfirmation'
import { createContentLike } from './contentLike'
import { createContentFor } from './createFrom'
import { useCreationActions } from './creationActions'
import {
  ClearPaneIcon,
  ClosePaneIcon,
  NewTabIcon,
  NewUnpinnedTabIcon,
  SplitHorizontalIcon,
  SplitVerticalIcon,
  WrapWindowIcon
} from './icons'
import { PaneHeaderMenuGroup } from './PaneHeaderMenuGroup'
import { placeNewPaneLike, placeNewUnpinnedPane } from './placement'

/**
 * The grab affordance at the left edge of a pane's chrome — the one spot
 * guaranteed to stay grabbable on a tab strip however many tabs fill it.
 * Purely visual: the chrome itself is the drag handle.
 */
export function PaneGrip() {
  return (
    <span className="pane-grip" aria-hidden="true">
      ⠿
    </span>
  )
}

/**
 * The controls every pane's chrome carries, all acting on `node` directly —
 * three hover-expand groups, roughly increasing destructiveness left to
 * right: split/tab actions (rooted on Split horizontally), content-type
 * creation (rooted on the first registered type), then close/clear. Each
 * root button is always visible once the chrome itself is hovered; hovering
 * a root in turn reveals its own dropdown of related actions — see
 * PaneHeaderMenuGroup.
 */
export function PaneHeaderControls({ node }: { node: ContentNode }) {
  const openContent = useLayoutStore((state) => state.openContent)
  const closePane = useLayoutStore((state) => state.closePane)
  const clearPane = useLayoutStore((state) => state.clearPane)
  const wrapPaneInTabs = useLayoutStore((state) => state.wrapPaneInTabs)
  // The docked root is always a tab group (see ensureTabsRoot in
  // layoutStore.ts) and stays that way forever, so its own controls drop
  // Split and Wrap in tab group: splitting it would bury the whole tab strip
  // inside one new tab beside a blank pane, and wrapping it would nest a
  // pointless single-tab group around it — neither has a sensible target to
  // fall back on the way `redirectFromDockedRoot` gives the keyboard-shortcut
  // path one. New Tab, already the obvious top-level action, takes over as
  // this group's own root button.
  const isDockedRoot = useLayoutStore((state) => state.root.id === node.id)
  const creationActions = useCreationActions()

  /**
   * Split horizontally/vertically and New tab — one call, because they differ
   * only in the direction they hand `placeNewPane`, which is where "no
   * direction means a new tab" is decided. Same helper the keyboard shortcuts
   * use (paneShortcuts.ts), aimed at this pane instead of the active one.
   */
  const handleNewPane = (direction?: SplitDirection): Promise<void> =>
    placeNewPaneLike(node.id, node, direction)

  const handleNewUnpinnedTab = async (): Promise<void> => {
    placeNewUnpinnedPane(node.id, await createContentLike(node))
  }

  /**
   * A content type's own creation button, aimed at this pane — and told which
   * pane it was pressed on, which is what lets the new content pick something
   * up from it (a git tree opening on the directory this terminal is in). The
   * origin was always available here; it simply used not to be passed.
   */
  const handleCreate = async (action: PaneCreationAction): Promise<void> => {
    openContent(node.id, await createContentFor(action, node))
  }

  // Both ask about `closeTargetNode` rather than about `node` itself, because
  // on the docked root's own bar the two differ: the store redirects a close
  // there onto the top-level tab being shown (see redirectFromDockedRoot), so
  // confirming against `node` would warn about every pane in the window and
  // then close one tab. Identical to `node` everywhere else.
  const handleClose = async (): Promise<void> => {
    if (await confirmClosingContent(closeTargetNode(useLayoutStore.getState(), node.id)))
      closePane(node.id)
  }

  const handleClear = async (): Promise<void> => {
    if (await confirmClosingContent(closeTargetNode(useLayoutStore.getState(), node.id)))
      clearPane(node.id)
  }

  const [rootCreationAction, ...restCreationActions] = creationActions

  const newTabItem = {
    testId: PANE_BUTTON.newTab,
    label: 'New tab',
    icon: <NewTabIcon />,
    onPress: () => handleNewPane()
  }

  const newUnpinnedTabItem = {
    testId: PANE_BUTTON.newUnpinnedTab,
    label: 'New unpinned tab',
    icon: <NewUnpinnedTabIcon />,
    onPress: handleNewUnpinnedTab
  }

  return (
    <div className="pane-header-controls">
      {isDockedRoot ? (
        <PaneHeaderMenuGroup root={newTabItem} items={[newUnpinnedTabItem]} />
      ) : (
        <PaneHeaderMenuGroup
          root={{
            testId: PANE_BUTTON.splitHorizontal,
            label: 'Split horizontally',
            onPress: () => handleNewPane('horizontal'),
            icon: <SplitHorizontalIcon />
          }}
          items={[
            {
              testId: PANE_BUTTON.splitVertical,
              label: 'Split vertically',
              icon: <SplitVerticalIcon />,
              onPress: () => handleNewPane('vertical')
            },
            newTabItem,
            newUnpinnedTabItem,
            {
              testId: PANE_BUTTON.wrapInTabGroup,
              label: 'Wrap in tab group',
              icon: <WrapWindowIcon />,
              onPress: () => wrapPaneInTabs(node.id)
            }
          ]}
        />
      )}
      {rootCreationAction && (
        <PaneHeaderMenuGroup
          root={{
            testId: rootCreationAction.testId,
            label: rootCreationAction.label,
            onPress: () => handleCreate(rootCreationAction),
            icon: <rootCreationAction.Icon />
          }}
          items={restCreationActions.map((createAction) => ({
            testId: createAction.testId,
            label: createAction.label,
            icon: <createAction.Icon />,
            onPress: () => handleCreate(createAction)
          }))}
        />
      )}
      <span className="pane-header-separator" aria-hidden="true" />
      <PaneHeaderMenuGroup
        root={{
          testId: PANE_BUTTON.close,
          label: 'Close pane',
          onPress: handleClose,
          icon: <ClosePaneIcon />
        }}
        items={[
          {
            testId: PANE_BUTTON.clear,
            label: 'Clear pane',
            icon: <ClearPaneIcon />,
            disabled: isEmpty(node),
            onPress: handleClear
          }
        ]}
      />
    </div>
  )
}
