import type { FloatingPane } from '@shared/model/floating'
import { memo, useMemo } from 'react'
import { useLayoutStore } from '../../core/store/layoutStore'
import { ContentView } from '../ContentView'
import { FloatingContext } from './floatingContext'
import { RESIZE_EDGES, startFloatingResize } from './floatingDrag'

/**
 * One floating window: a pane lifted out of the docked layout, drawn over it
 * and moved/resized directly. Its body is a plain `ContentView`, which is the
 * whole payoff of keeping a float a `ContentNode` — `Pane`, `TabBar`,
 * `SplitRenderer` and the leaf renderers all work inside a window unchanged,
 * so it can be split, tabbed and renamed like any docked pane.
 *
 * `depth` is the window's index in the layout's floating list (its z-order),
 * applied as a `z-index` rather than by rendering in that order: reordering
 * the DOM on a raise would disconnect and reconnect the raised subtree, which
 * destroys and rebuilds a `<webview>`'s guest WebContents (see CLAUDE.md), so
 * clicking a floating browser pane would reload its page every time.
 */
function FloatingWindowImpl({ entry, depth }: { entry: FloatingPane; depth: number }) {
  const raiseFloatingWindow = useLayoutStore((state) => state.raiseFloatingWindow)
  const context = useMemo(
    () => ({ floatId: entry.id, rootNodeId: entry.content.id }),
    [entry.id, entry.content.id]
  )

  return (
    <FloatingContext.Provider value={context}>
      {/* Raising is a window-level concern, not a widget's, so it takes the
          capture phase — which wins over the `stopPropagation` in Pane's own
          click handling.

          It does NOT catch a press landing on a `<webview>`, despite what this
          comment used to claim. A guest emits no host DOM event at all —
          measured with capture-phase window listeners for pointerdown/mousedown/
          click/focus/focusin plus direct listeners on the element, all silent
          for a real click inside a guest while a click on the pane's own
          toolbar logged five (see CLAUDE.md). Those presses arrive over the
          browser's own bridge instead and raise this window by activating its
          pane, since `setActivePane` raises the float that owns the pane —
          see src/plugins/browser/main/guestActivation.ts. */}
      <div
        className="floating-window"
        data-testid="floating-window"
        data-floating-id={entry.id}
        style={{
          left: entry.rect.x,
          top: entry.rect.y,
          width: entry.rect.width,
          height: entry.rect.height,
          zIndex: depth + 1
        }}
        onPointerDownCapture={() => raiseFloatingWindow(entry.id)}
      >
        <ContentView node={entry.content} />
        {/* Frame grips: pointer-only by nature, with no keyboard equivalent —
            a floating window is sized the way any window is. */}
        {RESIZE_EDGES.map((edge) => (
          <div
            key={edge}
            className={`floating-resize floating-resize-${edge}`}
            data-testid={`floating-resize-${edge}`}
            onPointerDown={(event) => startFloatingResize(event, entry.id, edge)}
          />
        ))}
      </div>
    </FloatingContext.Provider>
  )
}

export const FloatingWindow = memo(FloatingWindowImpl)
