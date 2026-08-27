import { useEffect } from 'react'
import { useLayoutStore } from '../../core/store/layoutStore'
import { FloatingWindow } from './FloatingWindow'

/** Window resizes arrive in bursts; one re-clamp at the end of each is enough. */
const RECLAMP_DEBOUNCE_MS = 150

/**
 * The picture-in-picture layer: every floating pane, drawn over the docked
 * layout. Renders nothing at all when there are no floating panes, so the
 * common case adds no full-viewport element for `elementFromPoint` to trip
 * over — and when it does render, the layer itself stays `pointer-events:
 * none` so hit-testing falls straight through to the panes underneath (see
 * global.css).
 *
 * Windows are rendered in a stable order and stacked with an explicit
 * `z-index`, never reordered in the DOM — see `FloatingWindow`.
 */
export function FloatingLayer() {
  const floating = useLayoutStore((state) => state.floating)

  // A layout saved on a large display can restore mostly off-screen on a
  // smaller one, and a window parked at the right edge belongs back in view
  // when the window shrinks. `reclampFloating` re-clamps every window against
  // the current viewport in one update and no-ops when nothing moves, so this
  // is free while idle.
  useEffect(() => {
    const reclamp = (): void => useLayoutStore.getState().reclampFloating()
    reclamp()
    let timer: ReturnType<typeof setTimeout> | undefined
    const onResize = (): void => {
      clearTimeout(timer)
      timer = setTimeout(reclamp, RECLAMP_DEBOUNCE_MS)
    }
    window.addEventListener('resize', onResize)
    return () => {
      clearTimeout(timer)
      window.removeEventListener('resize', onResize)
    }
  }, [])

  if (floating.length === 0) return null

  // Sorted by id purely for stability: the set of windows decides the DOM
  // order, never the stack order, so a raise touches one style attribute and
  // moves no elements. Depth comes from the entry's z-order position in the
  // unsorted array (same references, so identity lookup works).
  const stable = [...floating].sort((a, b) => (a.id < b.id ? -1 : 1))

  return (
    <div className="floating-layer" data-testid="floating-layer">
      {stable.map((entry) => (
        <FloatingWindow key={entry.id} entry={entry} depth={floating.indexOf(entry)} />
      ))}
    </div>
  )
}
