import type { DragInfo } from '../../core/store/dragStore'
import { useDragStore } from '../../core/store/dragStore'
import { FLY_BACK_MS } from '../dragController'

/**
 * An active drag whose pointer has left this window: OS mouse capture keeps
 * delivering its moves here, and a ghost drawn just past the left or top
 * edge would peek back in. The window the cursor is over draws it now.
 */
function pointerOutsideWindow(drag: DragInfo): boolean {
  if (drag.phase !== 'active') return false
  return drag.x < 0 || drag.y < 0 || drag.x >= window.innerWidth || drag.y >= window.innerHeight
}

/**
 * The floating ghost that follows the pointer during a tab drag. After a
 * targetless release it transitions back to the source tab's position (the
 * `returning` phase) before the drag state clears.
 */
export function DragOverlay() {
  const drag = useDragStore((state) => state.drag)
  if (!drag || pointerOutsideWindow(drag)) return null

  const returning = drag.phase === 'returning' && drag.returnTo !== null
  const x = returning && drag.returnTo ? drag.returnTo.x : drag.x + 12
  const y = returning && drag.returnTo ? drag.returnTo.y : drag.y + 16

  return (
    <div
      className={returning ? 'drag-ghost drag-ghost-returning' : 'drag-ghost'}
      style={{
        transform: `translate(${x}px, ${y}px)`,
        // TS's FLY_BACK_MS is the one source for the transition and the
        // cleanup timer that must outlive it; the stylesheet states no
        // duration of its own. Only while returning — a duration on the
        // live ghost would make it trail the pointer.
        transitionDuration: returning ? `${FLY_BACK_MS}ms` : undefined
      }}
    >
      {drag.title}
    </div>
  )
}
