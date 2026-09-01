import type { ContentNode, DockZone } from '@shared/model/types'
import { isTabs } from '@shared/model/types'
import { paneAttr } from '@shared/paneDomAttrs'
import {
  type CSSProperties,
  type ReactNode,
  type PointerEvent as ReactPointerEvent,
  useState
} from 'react'
import { paneTitleForContent } from '../core/registry/titles'
import { useBellStore } from '../core/store/bellStore'
import { useContextMenuStore } from '../core/store/contextMenuStore'
import { useControlStore } from '../core/store/controlStore'
import { useDragStore } from '../core/store/dragStore'
import { useLayoutStore } from '../core/store/layoutStore'
import { useSettingsStore } from '../core/store/settingsStore'
import { CueIcon } from './CueIcon'
import { useTabDepth } from './depth'
import { chromePointerDown, pinOrUnpinItem } from './floating/chrome'
import { useFloatingWindow } from './floating/floatingContext'
import { InlineTitleEditor } from './InlineTitleEditor'
import { BellIcon, RobotIcon } from './icons'
import { PaneGrip, PaneHeaderControls } from './PaneHeaderControls'

// All four properties stay explicit so a zone change transitions smoothly and
// the inline style wins over the pane's flex layout.
const DOCK_PREVIEW_RECTS: Record<DockZone, CSSProperties> = {
  left: { left: 0, top: 0, width: '50%', height: '100%' },
  right: { left: '50%', top: 0, width: '50%', height: '100%' },
  top: { left: 0, top: 0, width: '100%', height: '50%' },
  bottom: { left: 0, top: '50%', width: '100%', height: '50%' },
  center: { left: 0, top: 0, width: '100%', height: '100%' }
}

/**
 * Marks its children as one independently clickable/splittable pane, dressed
 * like a small window: a title bar with the pane's own controls above the
 * content, and a thin border around both. A tab-group pane skips the
 * separate title bar — its tab strip IS its chrome, and `TabBar` hosts the
 * same grip and controls. Clicking anywhere inside makes this the active
 * pane, which just gets a visual highlight — every header control acts on
 * its own pane directly, regardless of which one is active; the highlight
 * is a 1px accent outline around the pane's *content*, stopping short of
 * its chrome bar (see `.pane-active::after` in global.css — no bar is ever
 * filled with the accent and no border recolored). `stopPropagation`
 * keeps a click on a nested
 * pane (e.g. a split inside a tab) from also activating the pane it's
 * nested in.
 *
 * The chrome is also the pane's drag handle. A pane travels alone,
 * independent of any tab that holds it — the tab closes behind it, and a
 * group emptied by the departure goes away entirely (dragging the tab
 * itself still moves tab and content together). The docked root has nowhere
 * else to go, but it is always a tab group (see `ensureTabsRoot`) and a tab
 * group renders no separate header — its bar is its chrome, and TabBar's own
 * `isRoot` branch handles the root's no-drag/no-grip case. A header rendered
 * here therefore never belongs to the docked root.
 */
export function Pane({
  node,
  children,
  border = 'full',
  cornerLeft,
  cornerRight
}: {
  node: ContentNode
  children: ReactNode
  /** See ContentView's `insideTabsContent` doc — 'top-only' for any node reached directly as another tabs-group's tab content (no split in between). */
  border?: 'full' | 'top-only'
  /** See ContentRendererProps — whether *this* pane sits at the window's true bottom-left/bottom-right corner. */
  cornerLeft?: boolean | undefined
  cornerRight?: boolean | undefined
}) {
  const nodeId = node.id
  const isActive = useLayoutStore((state) => state.activePaneId === nodeId)
  const setActivePane = useLayoutStore((state) => state.setActivePane)
  const renamePane = useLayoutStore((state) => state.renamePane)
  const dockZone = useDragStore((state) =>
    state.drag?.target?.kind === 'dock' && state.drag.target.targetId === nodeId
      ? state.drag.target.zone
      : null
  )
  const isDragSource = useDragStore(
    (state) => state.drag?.subject.kind === 'pane' && state.drag.subject.paneId === nodeId
  )
  const dimInactivePanes = useSettingsStore((state) => state.dimInactivePanes)
  const dimInactivePanesIntensity = useSettingsStore((state) => state.dimInactivePanesIntensity)
  const enableBellIndicator = useSettingsStore((state) => state.enableBellIndicator)
  const hasBell = useBellStore((state) => state.ringing.has(nodeId))
  const enableControlIndicator = useSettingsStore((state) => state.enableControlIndicator)
  const isControlled = useControlStore((state) => state.controlled.has(nodeId))
  const openContextMenu = useContextMenuStore((state) => state.open)
  const [isEditingTitle, setIsEditingTitle] = useState(false)
  // Non-null for everything inside a floating window; the chrome helpers
  // treat only the one pane the window is built around as window chrome.
  const floating = useFloatingWindow()
  // How many tab groups enclose this pane — see content/depth.ts. Published
  // to CSS in two forms because the two things it drives need different
  // arithmetic: the indent grows without bound (`--depth` feeds a calc), the
  // shade only alternates (`data-depth-parity` picks one of two rules). CSS
  // can't take a modulo of a custom property portably, and doing the split
  // here keeps every actual color and length in the stylesheet.
  const depth = useTabDepth()

  // Clamped at the read site, the resolveSpawnPosition contract: settings.json
  // is hand-editable, migrateSettings deliberately validates only the shapes
  // that could throw, and an out-of-range value here lands in a CSS
  // brightness() where it silently invalidates the whole filter. A non-number
  // isn't clamped to some default but dropped below — the property stays
  // unset, and the stylesheet's own `var(--dim-intensity, 0.5)` fallback is
  // the single authority for what "no usable value" looks like.
  const dimIntensity = Math.min(1, Math.max(0, dimInactivePanesIntensity))

  const isDimmed = !isActive && dimInactivePanes

  const classNames = ['pane']
  if (isActive) classNames.push('pane-active')
  if (enableBellIndicator && hasBell) classNames.push('pane-alert')
  if (enableControlIndicator && isControlled) classNames.push('pane-controlled')
  if (isDragSource) classNames.push('pane-dragging')
  if (isDimmed) classNames.push('pane-dimmed')
  if (border === 'top-only') classNames.push('pane-border-top-only')
  // `--dim-intensity` is only set while dimmed — the CSS falls back to a
  // default when absent, and there's no reason to spend the property on every
  // non-dimmed pane. The docked root's taller chrome bar is not set here:
  // it's a stylesheet rule keyed off the shell's `data-fullscreen` and the
  // root pane's structural position (see the `--chrome-bottom` override in
  // global.css), so the length lives beside the values it must match.
  const style = {
    '--depth': depth,
    ...(isDimmed && Number.isFinite(dimIntensity) ? { '--dim-intensity': dimIntensity } : {}),
    // Explicit on every pane, unconditionally — never left to inherit or
    // fall back to a CSS default. That's the whole fix: an inherited or
    // selector-matched value has no way to be reset for a subtree with no
    // `.pane` of its own to reset it at (a split's own node, in particular),
    // so a value could ride an arbitrary depth of nesting onto the wrong
    // pane. See ContentRendererProps.cornerLeft/cornerRight and
    // SplitRenderer, which is the only place either one is ever computed as
    // anything other than a straight pass-through.
    '--pane-corner-radius-left': cornerLeft ? 'var(--os-corner-radius)' : '0px',
    '--pane-corner-radius-right': cornerRight ? 'var(--os-corner-radius)' : '0px'
  } as CSSProperties

  const onHeaderPointerDown = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if (isEditingTitle) return
    // Never the docked root — see the component comment — so always draggable.
    chromePointerDown(event, floating, nodeId, false, paneTitleForContent(node))
  }

  return (
    // A pane is a spatial focus target, like clicking a window to bring it
    // forward — not a discrete widget. It can't take an interactive role
    // (button/tab/...) because it wraps real interactive descendants
    // (tab strips, buttons), and nesting those inside one is invalid.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    // biome-ignore lint/a11y/useKeyWithClickEvents: see above
    <div
      className={classNames.join(' ')}
      data-testid="pane"
      {...paneAttr('dock', nodeId)}
      data-depth-parity={depth % 2}
      style={style}
      onClick={(event) => {
        event.stopPropagation()
        setActivePane(nodeId)
      }}
    >
      {/* The header is the drag handle for the pane, not a discrete widget:
          its buttons are the interactive elements — except right-click,
          which opens the header's own "Edit title" menu. */}
      {!isTabs(node) && (
        // biome-ignore lint/a11y/noStaticElementInteractions: see above
        <div
          className="pane-header"
          data-testid="pane-header"
          {...paneAttr('paneDrag', nodeId)}
          onPointerDown={onHeaderPointerDown}
          onContextMenu={(event) => {
            if (isEditingTitle) return
            event.preventDefault()
            event.stopPropagation()
            const pin = pinOrUnpinItem(floating, nodeId)
            openContextMenu(event.clientX, event.clientY, [
              { label: 'Edit title', onSelect: () => setIsEditingTitle(true) },
              ...(pin ? [pin] : [])
            ])
          }}
        >
          <PaneGrip />
          {enableBellIndicator && hasBell && (
            <CueIcon className="bell-icon" testId="pane-bell-icon" label="Bell">
              <BellIcon />
            </CueIcon>
          )}
          {enableControlIndicator && isControlled && (
            <CueIcon
              className="control-icon"
              testId="pane-control-icon"
              label="Controlled by another pane"
              title="Controlled by another pane"
            >
              <RobotIcon />
            </CueIcon>
          )}
          {isEditingTitle ? (
            <InlineTitleEditor
              initialValue={paneTitleForContent(node)}
              className="pane-title-input"
              ariaLabel="Pane title"
              // Saving an emptied box reverts to the derived content-type
              // label rather than being rejected — unlike a tab's title, a
              // pane's is an optional override.
              onSave={(trimmed) => renamePane(nodeId, trimmed === '' ? undefined : trimmed)}
              onDone={() => setIsEditingTitle(false)}
            />
          ) : (
            // Double-click to rename — the header above already carries the
            // equivalent right-click "Edit title" entry point.
            // biome-ignore lint/a11y/noStaticElementInteractions: see above
            <span className="pane-title" onDoubleClick={() => setIsEditingTitle(true)}>
              {paneTitleForContent(node)}
            </span>
          )}
          <PaneHeaderControls node={node} />
        </div>
      )}
      <div className="pane-body">{children}</div>
      {dockZone && (
        <div
          className="dock-preview"
          data-testid="dock-preview"
          style={DOCK_PREVIEW_RECTS[dockZone]}
        />
      )}
    </div>
  )
}
