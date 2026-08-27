import type { ReactNode } from 'react'
import { useRef, useState } from 'react'
import { clampOverlay } from '../core/overlayPosition'
import { fireAndReport, type UiAction } from './fireAndReport'

/**
 * One control in the chrome row — a group's root button, or a row of its
 * dropdown (`role="menuitem"`), which are the same control in two places.
 * Presses stay local: pointerdown must not grab the drag handle beneath the
 * button, and the click must not bubble into activating a pane that may no
 * longer exist. Exported for the odd chrome button that lives outside a
 * group (the root tab bar's Settings button), which needs exactly this
 * press-isolation contract; `className` adds that caller's modifier on top
 * of the shared base styling.
 */
export function HeaderButton({
  testId,
  label,
  disabled,
  role,
  className,
  onPress,
  children
}: {
  testId: string
  label: string
  disabled?: boolean | undefined
  role?: string
  className?: string
  /** Sync or async — a rejection is reported, never dropped (see fireAndReport). */
  onPress: UiAction
  children: ReactNode
}) {
  return (
    <button
      type="button"
      className={className ? `pane-header-button ${className}` : 'pane-header-button'}
      data-testid={testId}
      aria-label={label}
      title={label}
      disabled={disabled}
      role={role}
      onPointerDown={(event) => event.stopPropagation()}
      onClick={(event) => {
        event.stopPropagation()
        fireAndReport(onPress)
        // A click leaves the button focused, which — for a group with a
        // dropdown — would keep it revealed via :focus-within long after
        // the mouse moves on (focus isn't affected by mouse position at
        // all). Blurring on press is what makes "select an action" close
        // the menu, matching a native menu's own selection behavior.
        event.currentTarget.blur()
      }}
    >
      {children}
    </button>
  )
}

interface PaneHeaderMenuItem {
  testId: string
  label: string
  icon: ReactNode
  disabled?: boolean | undefined
  onPress: UiAction
}

interface PaneHeaderMenuGroupProps {
  root: Omit<PaneHeaderMenuItem, 'disabled'>
  items: PaneHeaderMenuItem[]
}

/**
 * A root chrome button — plain, always-visible, behaves exactly like
 * `HeaderButton` on its own — plus, when it has more than one related
 * action, a menu revealed on hover/focus one level deeper than the outer
 * chrome-row reveal (`.pane-header-controls:hover`).
 *
 * *Opening* stays driven by real, synchronous `:hover`/`:focus-within` in
 * CSS, deliberately — not by the JS state below. A helper like
 * `clickPaneRoot` (e2e/helpers/pane.ts) clicks this root button directly,
 * relying on hover-reveal being instantaneous so the click's mousedown and
 * mouseup land on the same element even though the reveal covers that
 * element with a duplicate of itself (see the dropdown's own comment).
 * Gating the reveal on a React state update instead — set from
 * `onMouseEnter`, applied on the next render — opens a real window where
 * mousedown lands on the root button (not yet covered) and mouseup, a few
 * milliseconds later, lands on the now-revealed menu covering it instead:
 * two different elements, so the browser fires no click on either. Confirmed
 * directly (measured via the DOM, not guessed): that version silently ate
 * every content-type creation click in this exact spot. Only *closing* is
 * lagged, and that lives entirely in the stylesheet too — a transition
 * delay on the dropdown's own rule (see `.pane-header-dropdown` in
 * global.css) — which doesn't affect a click, since one only ever happens
 * while the pointer is stationary and already hovering.
 *
 * The menu is a genuine, simple, self-contained panel — no attempt to
 * visually fuse it with the root button (matching its exact width, faking a
 * shared border, squaring off corners to hide a seam), which only ever
 * produced new edge cases to chase. Instead it's positioned flush over the
 * root button rather than below it (`top: 0`, not `top: 100%`): opening it
 * covers the root, so the root's own action — repeated as the menu's first
 * row (its own testid, not a second copy of the button) — reads as the one
 * and only thing on screen at that spot, not a duplicate sitting next to
 * it. The cursor ends up over the menu itself once it opens, which keeps
 * the group's hover/focus satisfied (the menu is still a descendant of it)
 * — so covering the trigger doesn't cause the menu to immediately close
 * under its own reveal.
 *
 * With zero extra items it renders as a bare root button and no hover
 * affordance, which is what keeps a content-type group correct when only
 * one content type is registered.
 */
export function PaneHeaderMenuGroup({ root, items }: PaneHeaderMenuGroupProps) {
  const groupRef = useRef<HTMLSpanElement>(null)
  const dropdownRef = useRef<HTMLDivElement>(null)
  // Pixel nudge off the dropdown's default position (flush with the group's
  // own left edge), measured against the real viewport on each hover/focus
  // rather than guessed statically per group — a pane's on-screen position
  // depends on the layout (including a split dragged down near
  // MIN_PANE_SIZE), not on which group this is. Clamping to an explicit
  // offset — not just a left/right anchor flip — is what keeps this correct
  // even when the dropdown is wider than the pane hosting it: a flip alone
  // can only move the overflow from one edge to the other.
  const [offsetX, setOffsetX] = useState(0)

  // Re-measured on every hover/focus rather than once: the group can be at a
  // new on-screen position between opens (a resize, a split drag).
  const measure = (): void => {
    const group = groupRef.current
    const dropdown = dropdownRef.current
    if (!group || !dropdown) return
    const groupRect = group.getBoundingClientRect()
    setOffsetX(
      clampOverlay(groupRect.left, dropdown.offsetWidth, window.innerWidth) - groupRect.left
    )
  }

  const hasMenu = items.length > 0

  return (
    // Not itself interactive — no click/keyboard handler, just a hover/focus
    // probe that re-measures the dropdown's fit against the viewport. The
    // real interactive elements are the button and menu items inside it.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    <span
      ref={groupRef}
      className="pane-header-group"
      onMouseEnter={hasMenu ? measure : undefined}
      onFocus={hasMenu ? measure : undefined}
    >
      <HeaderButton testId={root.testId} label={root.label} onPress={root.onPress}>
        {root.icon}
      </HeaderButton>
      {hasMenu && (
        <div
          ref={dropdownRef}
          className="pane-header-dropdown"
          role="menu"
          aria-label={`${root.label} — more`}
          style={offsetX ? { transform: `translateX(${offsetX}px)` } : undefined}
        >
          {[{ ...root, testId: `${root.testId}-menu-item` }, ...items].map((item) => (
            <HeaderButton
              key={item.testId}
              testId={item.testId}
              label={item.label}
              disabled={item.disabled}
              role="menuitem"
              onPress={item.onPress}
            >
              {item.icon}
            </HeaderButton>
          ))}
        </div>
      )}
    </span>
  )
}
