import type { ContentNode, NodeId } from '@shared/model/types'
import { type ShortcutActionId, shortcutAction } from '@shared/shortcuts'
import type { ComponentType, KeyboardEvent } from 'react'
import { useEffect, useRef, useState } from 'react'
import { focusPane } from '../core/registry/paneHandles'
import { useCommandPaletteStore } from '../core/store/commandPaletteStore'
import { findNodeAnywhere, useLayoutStore } from '../core/store/layoutStore'
import { createContentFor } from './createFrom'
import { NO_CONTENT_TYPES_MESSAGE, useCreationActions } from './creationActions'
import { fireAndReport, type UiAction } from './fireAndReport'
import { NewTabIcon, NewUnpinnedTabIcon, SplitHorizontalIcon, SplitVerticalIcon } from './icons'
import { placeNewPane, placeNewUnpinnedPane } from './placement'

/**
 * The four ways to place fresh content, in the same order the File menu
 * lists them. Labels and icons are read off the shared shortcut registry and
 * the pane header's own icon set (`./icons`) rather than repeated here, so
 * neither can drift from the menu's or the header's.
 */
const PLACEMENT_STRATEGY_IDS = [
  'new-tab',
  'split-horizontal',
  'split-vertical',
  'new-unpinned-pane'
] as const satisfies readonly ShortcutActionId[]

type PlacementStrategyId = (typeof PLACEMENT_STRATEGY_IDS)[number]

const PLACEMENT_ICONS: Record<PlacementStrategyId, ComponentType> = {
  'new-tab': NewTabIcon,
  'split-horizontal': SplitHorizontalIcon,
  'split-vertical': SplitVerticalIcon,
  'new-unpinned-pane': NewUnpinnedTabIcon
}

function place(id: PlacementStrategyId, targetId: NodeId, content: ContentNode): void {
  switch (id) {
    case 'new-tab':
      placeNewPane(targetId, content)
      return
    case 'split-horizontal':
      placeNewPane(targetId, content, 'horizontal')
      return
    case 'split-vertical':
      placeNewPane(targetId, content, 'vertical')
      return
    case 'new-unpinned-pane':
      placeNewUnpinnedPane(targetId, content)
      return
  }
}

interface PaletteItem {
  key: string
  label: string
  Icon?: ComponentType
  onSelect: UiAction
}

/** The one way an item is chosen — by Enter, by digit, by click — so every route reports a failed commit. */
function select(item: PaletteItem | undefined): void {
  if (item) fireAndReport(item.onSelect)
}

/**
 * The Cmd+P overlay for creating new content: pick a content type, then pick
 * how to place it. Mounted once in App.tsx, sibling to NavFlashOverlay and
 * ContextMenu — see commandPaletteStore.ts for the step state this renders.
 *
 * Unlike ContextMenu, this steals real DOM focus onto its own container the
 * instant it opens (see the effect below). That isn't cosmetic: Cmd+P is a
 * `layer: 'menu'` action specifically so it still fires when a `<webview>`
 * browser pane's guest holds focus, but a guest is a separate `WebContents`
 * — no capture-phase listener in this window can intercept a keypress that
 * lands there first. Without moving focus out of the guest, every arrow/
 * digit/Enter press after opening would vanish into the page instead of
 * driving this list.
 */
export function CommandPalette() {
  const step = useCommandPaletteStore((state) => state.step)
  const chooseType = useCommandPaletteStore((state) => state.chooseType)
  const close = useCommandPaletteStore((state) => state.close)
  const creationActions = useCreationActions()
  const containerRef = useRef<HTMLDivElement>(null)
  const [highlighted, setHighlighted] = useState(0)

  useEffect(() => {
    setHighlighted(0)
    if (step.kind !== 'closed') containerRef.current?.focus()
  }, [step.kind])

  const items: PaletteItem[] =
    step.kind === 'type'
      ? creationActions.map((action) => ({
          key: action.testId,
          label: action.displayName,
          Icon: action.Icon,
          onSelect: () => chooseType(action)
        }))
      : step.kind === 'placement'
        ? PLACEMENT_STRATEGY_IDS.map((id) => ({
            key: id,
            // Derived from the shared label (see the module comment above)
            // rather than a plain-text literal, so it still can't drift —
            // only "New " read as noise once every row was already about
            // placing something new.
            label: shortcutAction(id).label.replace(/^New /, ''),
            Icon: PLACEMENT_ICONS[id],
            onSelect: () => commit(id)
          }))
        : []

  async function commit(strategyId: PlacementStrategyId): Promise<void> {
    if (step.kind !== 'placement') return
    const { targetPaneId, action } = step
    const origin = findNodeAnywhere(useLayoutStore.getState(), targetPaneId)
    close()
    if (!origin) return
    const content = await createContentFor(action, origin)
    place(strategyId, targetPaneId, content)
  }

  function handleDismiss(): void {
    if (step.kind === 'closed') return
    const { targetPaneId } = step
    close()
    focusPane(targetPaneId)
  }

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void {
    if (event.key === 'Escape') {
      event.preventDefault()
      handleDismiss()
      return
    }
    if (items.length === 0) return
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setHighlighted((index) => (index + 1) % items.length)
      return
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault()
      setHighlighted((index) => (index - 1 + items.length) % items.length)
      return
    }
    if (event.key === 'Enter') {
      event.preventDefault()
      select(items[highlighted])
      return
    }
    if (/^Digit[1-9]$/.test(event.code)) {
      const index = Number(event.code.slice(5)) - 1
      if (index < items.length) {
        event.preventDefault()
        select(items[index])
      }
    }
  }

  if (step.kind === 'closed') return null

  return (
    // Backdrop click-to-dismiss, same pattern as ContextMenu. Escape and
    // every other key are already handled by onKeyDown below, which is why
    // (unlike ContextMenu's backdrop) this needs no useKeyWithClickEvents
    // suppression — the element genuinely has a key handler.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    <div
      ref={containerRef}
      tabIndex={-1}
      className="command-palette-backdrop"
      data-testid="command-palette-backdrop"
      onClick={handleDismiss}
      onKeyDown={handleKeyDown}
    >
      {/* Swallows the backdrop's onClick so clicks inside the panel don't dismiss it. */}
      {/* biome-ignore lint/a11y/noStaticElementInteractions: see above */}
      {/* biome-ignore lint/a11y/useKeyWithClickEvents: see above */}
      <div
        className="command-palette"
        data-testid="command-palette"
        onClick={(event) => event.stopPropagation()}
      >
        {items.length > 0 ? (
          <div className="command-palette-list" role="menu">
            {items.map((item, index) => (
              <button
                key={item.key}
                type="button"
                role="menuitem"
                className={
                  index === highlighted
                    ? 'command-palette-item command-palette-item-highlighted'
                    : 'command-palette-item'
                }
                data-testid={`command-palette-item-${item.key}`}
                onMouseEnter={() => setHighlighted(index)}
                onClick={(event) => {
                  event.stopPropagation()
                  select(item)
                }}
              >
                {index < 9 && <span className="command-palette-badge">{index + 1}</span>}
                {item.Icon && <item.Icon />}
                <span className="command-palette-label">{item.label}</span>
              </button>
            ))}
          </div>
        ) : (
          <p className="command-palette-empty">{NO_CONTENT_TYPES_MESSAGE}</p>
        )}
      </div>
    </div>
  )
}
