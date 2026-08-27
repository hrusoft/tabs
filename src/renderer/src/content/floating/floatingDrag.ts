import type { FloatRect } from '@shared/model/floating'
import { clampRect, MIN_FLOAT_SIZE } from '@shared/model/floating'
import type { NodeId } from '@shared/model/types'
import type { PointerEvent as ReactPointerEvent } from 'react'
import { useLayoutStore, viewportSize } from '../../core/store/layoutStore'
import { armPointerGesture } from '../pointerGesture'

/** The eight frame handles, named by the edges they move. */
export type ResizeEdge = 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w' | 'nw'

export const RESIZE_EDGES: readonly ResizeEdge[] = ['n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw']

/** This module's name in the shared gesture flag — see pointerGesture.ts. */
const GESTURE_OWNER = 'floating'

interface Session {
  floatId: NodeId
  el: HTMLElement
  mode: 'move' | ResizeEdge
  startX: number
  startY: number
  /** Geometry at pointerdown — the Escape-to-cancel restore point. */
  origin: FloatRect
  /** Latest painted geometry, committed on release. */
  current: FloatRect
  /** Ends the shared gesture lifecycle — see armPointerGesture. */
  release: () => void
}

// Module-scoped, like dragController's own session: only one pointer-driven
// window gesture can be in flight at a time.
let session: Session | null = null

/** Moves the whole window — entered from its outermost pane chrome. */
export function startFloatingMove(event: ReactPointerEvent<HTMLElement>, floatId: NodeId): void {
  arm(event, floatId, 'move')
}

/** Resizes the window from one of its frame handles. */
export function startFloatingResize(
  event: ReactPointerEvent<HTMLElement>,
  floatId: NodeId,
  edge: ResizeEdge
): void {
  arm(event, floatId, edge)
}

/**
 * Unlike `dragController`, there is no engage threshold: a window move has no
 * competing click semantic to protect, and swallowing the first five pixels
 * of motion reads as lag.
 */
function arm(
  event: ReactPointerEvent<HTMLElement>,
  floatId: NodeId,
  mode: 'move' | ResizeEdge
): void {
  if (event.button !== 0) return
  if (session) return
  const el = event.currentTarget.closest<HTMLElement>('.floating-window')
  if (!el) return
  const origin = rectOf(el)
  session = {
    floatId,
    el,
    mode,
    startX: event.clientX,
    startY: event.clientY,
    origin,
    current: origin,
    release: armPointerGesture(GESTURE_OWNER, event.pointerId, {
      onMove: onPointerMove,
      onRelease: onPointerUp,
      onCancel: cancel
    })
  }
}

function rectOf(el: HTMLElement): FloatRect {
  const rect = el.getBoundingClientRect()
  return { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
}

function onPointerMove(event: PointerEvent): void {
  if (!session) return
  session.current = clampRect(nextRect(session, event.clientX, event.clientY), viewportSize())
  paint(session.el, session.current)
}

/**
 * Geometry from the gesture's origin plus the pointer delta. A resize moves
 * only the edges its handle names, each clamped against the *fixed* opposite
 * edge so dragging past it stops at the minimum size instead of inverting the
 * window.
 */
function nextRect(active: Session, x: number, y: number): FloatRect {
  const dx = x - active.startX
  const dy = y - active.startY
  const { x: originX, y: originY, width, height } = active.origin
  if (active.mode === 'move') return { x: originX + dx, y: originY + dy, width, height }

  let left = originX
  let top = originY
  let right = originX + width
  let bottom = originY + height
  if (active.mode.includes('w')) left = Math.min(left + dx, right - MIN_FLOAT_SIZE.width)
  if (active.mode.includes('e')) right = Math.max(right + dx, left + MIN_FLOAT_SIZE.width)
  if (active.mode.includes('n')) top = Math.min(top + dy, bottom - MIN_FLOAT_SIZE.height)
  if (active.mode.includes('s')) bottom = Math.max(bottom + dy, top + MIN_FLOAT_SIZE.height)
  return { x: left, y: top, width: right - left, height: bottom - top }
}

/**
 * Live geometry goes straight to the element, never through the store: a
 * store write per pointer frame would re-arm layoutStore's 400ms save timer
 * ~60 times a second and re-render the whole window subtree with it. The
 * gesture commits once, on release — the same split `dragController` makes by
 * keeping its per-frame pointer position in the ephemeral drag store, and the
 * same one `SplitRenderer` makes by staying uncontrolled during a separator
 * drag. A terminal inside still refits, because its ResizeObserver watches
 * the DOM rather than the store.
 */
function paint(el: HTMLElement, rect: FloatRect): void {
  el.style.left = `${rect.x}px`
  el.style.top = `${rect.y}px`
  el.style.width = `${rect.width}px`
  el.style.height = `${rect.height}px`
}

function onPointerUp(): void {
  if (!session) return
  const { floatId, current } = session
  session = null
  useLayoutStore.getState().setFloatingRect(floatId, current)
}

/** Puts the window back where the gesture started and commits nothing. */
function cancel(): void {
  if (!session) return
  paint(session.el, session.origin)
  session.release()
  session = null
}
