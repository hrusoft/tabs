import { entryPaneId } from '@shared/model/navigation'
import { collectLeaves } from '@shared/model/tree'
import type { NodeId, Tab, TabsContent } from '@shared/model/types'
import { paneAttr } from '@shared/paneDomAttrs'
import { Fragment, useState } from 'react'
import { paneTitleForContent } from '../../core/registry/titles'
import { useBellStore } from '../../core/store/bellStore'
import { useContextMenuStore } from '../../core/store/contextMenuStore'
import { useDragStore } from '../../core/store/dragStore'
import { useLayoutStore } from '../../core/store/layoutStore'
import { useSettingsStore } from '../../core/store/settingsStore'
import { IconButton } from '../../IconButton'
import { CueIcon } from '../CueIcon'
import { confirmClosingContent } from '../closeConfirmation'
import { startTabDrag } from '../dragController'
import { fireAndReport } from '../fireAndReport'
import { chromePointerDown, pinOrUnpinItem } from '../floating/chrome'
import { useFloatingWindow } from '../floating/floatingContext'
import { InlineTitleEditor } from '../InlineTitleEditor'
import { BellIcon, PlusIcon, SettingsIcon } from '../icons'
import { PaneGrip, PaneHeaderControls } from '../PaneHeaderControls'
import { HeaderButton } from '../PaneHeaderMenuGroup'
import { placeNewPaneLike } from '../placement'

/**
 * The window's own Settings button — the one action left over from the old
 * separate WindowHeader that isn't scoped to any pane. Lives only on the
 * docked root's own bar (see `isRoot` below); nested and floating tab groups
 * never render it. HeaderButton supplies the press-isolation contract every
 * chrome button needs; the modifier class carves it out of the bar's native
 * drag region and sizes it up slightly (see global.css).
 */
function RootSettingsButton() {
  return (
    <HeaderButton
      testId="settings-open-button"
      label="Settings"
      className="tab-bar-settings-button"
      onPress={() => window.api.appWindow.openSettings()}
    >
      <SettingsIcon />
    </HeaderButton>
  )
}

/**
 * The tab strip for a tab group — and the group pane's chrome: no separate
 * title bar sits above it, so the bar hosts the pane's grip and controls,
 * and its own background (grip, the space after the tabs, the controls row)
 * is the drag handle for the whole group. Tabs keep their own drag; a press
 * on one must not fall through to the group handle beneath it. New-tab and
 * split actions live in the controls row too, acting on the group itself.
 *
 * The docked root's bar carries extra duty on top of that: with no separate
 * window chrome any more (see App.tsx), it doubles as the window's own title
 * bar — its background is the native drag region, it reserves the
 * traffic-light gutter, and it's the one place the Settings button lives.
 * `isRoot`'s existing no-grip/no-pane-drag behavior (this bar has nowhere to
 * dock, being the whole window) already made this bar different from every
 * nested one; this just gives that difference a real place to hang chrome.
 */
export function TabBar({ group }: { group: TabsContent }) {
  const activateTab = useLayoutStore((state) => state.activateTab)
  const setActivePane = useLayoutStore((state) => state.setActivePane)
  const closeTab = useLayoutStore((state) => state.closeTab)
  const renameTab = useLayoutStore((state) => state.renameTab)
  const ungroupTabs = useLayoutStore((state) => state.ungroupTabs)
  const isRoot = useLayoutStore((state) => state.root.id === group.id)
  // Narrow primitive selectors, not the whole drag object: `setPointer`
  // replaces `drag` on every pointermove, and a whole-object subscription
  // would re-render every tab strip at pointer frequency for the entire
  // drag (same pattern as Pane's dockZone/isDragSource selectors).
  const dropIndex = useDragStore((state) =>
    state.drag?.target?.kind === 'tab-bar' && state.drag.target.groupId === group.id
      ? state.drag.target.index
      : null
  )
  const draggingTabId = useDragStore((state) =>
    state.drag?.subject.kind === 'tab' ? state.drag.subject.tabId : null
  )
  const openContextMenu = useContextMenuStore((state) => state.open)
  const enableBellIndicator = useSettingsStore((state) => state.enableBellIndicator)
  const ringing = useBellStore((state) => state.ringing)
  const [editingTabId, setEditingTabId] = useState<NodeId | null>(null)
  // A tab group pane has no separate header, so the bar is also where its
  // floating-window chrome lives: the move handle and the Pin entry.
  const floating = useFloatingWindow()

  const handleCloseTab = async (tab: Tab): Promise<void> => {
    if (await confirmClosingContent(tab.content)) closeTab(tab.id)
  }

  return (
    // Like Pane's chrome, the bar is a drag handle, not a discrete widget:
    // the tabs and buttons inside are the interactive elements — except
    // right-click, which opens the group's own menu.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    <div
      className={isRoot ? 'tab-bar tab-bar-root' : 'tab-bar'}
      {...paneAttr('dropGroup', group.id)}
      {...paneAttr('paneDrag', group.id)}
      onPointerDown={(event) => {
        chromePointerDown(event, floating, group.id, isRoot, paneTitleForContent(group))
      }}
      onContextMenu={(event) => {
        event.preventDefault()
        event.stopPropagation()
        // The root has no parent to detach from — unpinning it would lift
        // every tab in the window into one floating pane and leave a bare
        // placeholder behind — so, like Ungroup below, the entry never
        // appears on its bar; the store refuses it too (see `unpinPane`).
        const pin = isRoot ? null : pinOrUnpinItem(floating, group.id)
        const items = pin ? [pin] : []
        // Ungrouping the root would leave the window with no tab group at
        // all — its own bar has nowhere to unwrap to (see ensureTabsRoot in
        // layoutStore.ts), so the option never appears there regardless of
        // tab count.
        if (group.tabs.length === 1 && !isRoot) {
          items.push({ label: 'Ungroup', onSelect: () => ungroupTabs(group.id) })
        }
        if (items.length) openContextMenu(event.clientX, event.clientY, items)
      }}
    >
      {!isRoot && <PaneGrip />}
      <div className="tab-strip" role="tablist">
        {group.tabs.map((tab, index) => {
          const active = tab.id === group.activeTabId
          const isEditing = tab.id === editingTabId
          // Containment, not content type: does any leaf under this tab ring?
          // bellStore only ever holds leaf pane ids, so no type filter needed.
          const hasBell =
            enableBellIndicator && collectLeaves(tab.content).some((leaf) => ringing.has(leaf.id))
          const classNames = ['tab']
          if (active) classNames.push('tab-active')
          if (draggingTabId === tab.id) classNames.push('tab-dragging')

          return (
            <Fragment key={tab.id}>
              {dropIndex === index && <div className="tab-drop-indicator" />}
              <div
                role="tab"
                aria-selected={active}
                tabIndex={0}
                className={classNames.join(' ')}
                {...paneAttr('dropTab', tab.id)}
                onPointerDown={(event) => {
                  if (isEditing) return
                  event.stopPropagation()
                  startTabDrag(event, tab.id, group.id, tab.title)
                }}
                onClick={(event) => {
                  if (isEditing) return
                  const isSwitch = tab.id !== group.activeTabId
                  activateTab(group.id, tab.id)
                  if (isSwitch) {
                    // Switching content moves focus with it, down to the tab's
                    // actual leaf — stop propagation so the click doesn't also
                    // bubble to the group's own Pane and re-focus the group.
                    // Re-clicking the already-active tab (no switch) falls
                    // through unchanged, same as clicking any tab-bar chrome.
                    event.stopPropagation()
                    setActivePane(entryPaneId(tab.content))
                  }
                }}
                onContextMenu={(event) => {
                  if (isEditing) return
                  event.preventDefault()
                  event.stopPropagation()
                  // Unpins the tab's *content*, closing the tab behind it.
                  // A backgrounded tab has no rect of its own, so the
                  // window opens over the group's.
                  const unpin = pinOrUnpinItem(floating, tab.content.id, group.id)
                  openContextMenu(event.clientX, event.clientY, [
                    { label: 'Edit title', onSelect: () => setEditingTabId(tab.id) },
                    ...(unpin ? [unpin] : [])
                  ])
                }}
                onKeyDown={(event) => {
                  if (isEditing) return
                  if (event.key === 'Enter' || event.key === ' ') activateTab(group.id, tab.id)
                }}
              >
                {isEditing ? (
                  <InlineTitleEditor
                    initialValue={tab.title}
                    className="tab-title-input"
                    ariaLabel="Tab title"
                    // An emptied box is rejected: a tab always has a title.
                    onSave={(trimmed) => {
                      if (trimmed && trimmed !== tab.title) renameTab(tab.id, trimmed)
                    }}
                    onDone={() => setEditingTabId(null)}
                  />
                ) : (
                  <>
                    {hasBell && (
                      <CueIcon className="bell-icon" testId="tab-bell-icon" label="Bell">
                        <BellIcon />
                      </CueIcon>
                    )}
                    {/* Double-click to rename — the tab div above already carries the
                        equivalent right-click "Edit title" entry point. */}
                    {/* biome-ignore lint/a11y/noStaticElementInteractions: see above */}
                    <span className="tab-title" onDoubleClick={() => setEditingTabId(tab.id)}>
                      {tab.title}
                    </span>
                    <IconButton
                      label={`Close ${tab.title}`}
                      className="tab-close"
                      onPointerDown={(event) => event.stopPropagation()}
                      onClick={(event) => {
                        event.stopPropagation()
                        fireAndReport(() => handleCloseTab(tab))
                      }}
                    >
                      ×
                    </IconButton>
                  </>
                )}
              </div>
            </Fragment>
          )
        })}
        {dropIndex === group.tabs.length && <div className="tab-drop-indicator" />}
        <HeaderButton
          testId="tab-strip-new-tab-button"
          label="New tab"
          className="tab-strip-new-tab-button"
          onPress={() => placeNewPaneLike(group.id, group)}
        >
          <PlusIcon />
        </HeaderButton>
      </div>
      <PaneHeaderControls node={group} />
      {isRoot && <RootSettingsButton />}
    </div>
  )
}
