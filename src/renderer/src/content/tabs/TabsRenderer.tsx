import type { NodeId, Tab, TabsContent } from '@tabs/plugin-sdk/shared/model/types'
import { useRef } from 'react'
import type { ContentRendererProps } from '../../core/registry/registry'
import { ContentView } from '../ContentView'
import { TabDepthContext, useTabDepth } from '../depth'
import { TabBar } from './TabBar'

/**
 * `tabs` in the order their panels were first rendered, not strip order.
 *
 * Panels are rendered in this stable order because reordering keyed siblings
 * makes React *move* DOM nodes, and a moved `<webview>` loses its guest: the
 * page reloads, with its history, form state, console and refs (CLAUDE.md's
 * webview-reparent entry). Rendering in strip order meant a drag along the
 * strip reloaded pages the user never touched — measured: dragging the last
 * tab to the front reloaded the other tabs' browser pages, while the dragged
 * one kept its own (React moves whichever siblings its diff picks, not the
 * one that moved). Only the active panel is ever visible (the rest are
 * `hidden`), so DOM order has no visual meaning here; the strip (TabBar) is
 * where order shows. Same fix as FloatingLayer's stable render order for
 * raises. A tab added anywhere in the strip is appended, a closed one
 * dropped, and nothing already rendered moves.
 *
 * The previous order is threaded through a ref, so this must stay a pure
 * function of (previous order, current tabs): React may render twice.
 */
function inFirstSeenOrder(previous: readonly NodeId[], tabs: readonly Tab[]): Tab[] {
  const byId = new Map(tabs.map((tab) => [tab.id, tab]))
  const ordered: Tab[] = []
  for (const id of previous) {
    const tab = byId.get(id)
    if (!tab) continue
    ordered.push(tab)
    byId.delete(id)
  }
  // What is left is new since the last render, in strip order.
  for (const tab of byId.values()) ordered.push(tab)
  return ordered
}

export function TabsRenderer({ node, cornerLeft, cornerRight }: ContentRendererProps<TabsContent>) {
  // The bar paints at this group's own depth; everything a tab reveals is one
  // step deeper, which is what alternates the shade and steps the indent. The
  // provider wraps only the content, so `TabBar` keeps this group's depth.
  const depth = useTabDepth()
  const panelOrderRef = useRef<NodeId[]>([])
  const panels = inFirstSeenOrder(panelOrderRef.current, node.tabs)
  panelOrderRef.current = panels.map((tab) => tab.id)
  return (
    <div className="tabs-view">
      <TabBar group={node} />
      <div className="tabs-view-content">
        <TabDepthContext.Provider value={depth + 1}>
          {panels.map((tab) => (
            // Inactive tabs stay mounted, just hidden — so a terminal's shell
            // or any other content's state survives switching away and back.
            <div key={tab.id} className="tabs-view-pane" hidden={tab.id !== node.activeTabId}>
              {/* A tab's content is its own pane: opening content on it adds a
                  sibling tab here, rather than nesting a group inside it. Its
                  left/right/bottom border is suppressed unconditionally,
                  whatever its type: those sides sit flush against this group's
                  own border and would stack (a split further down narrows this
                  to the sides each child actually shares — see
                  ContentRendererProps). The top is never suppressed at any
                  depth — it is the hairline under this bar. The full
                  derivation is CLAUDE.md's pane-chrome entry. */}
              <ContentView
                node={tab.content}
                cornerLeft={cornerLeft}
                cornerRight={cornerRight}
                suppressBorderLeft
                suppressBorderRight
                suppressBorderBottom
              />
            </div>
          ))}
        </TabDepthContext.Provider>
      </div>
    </div>
  )
}
