import type { TabsContent } from '@shared/model/types'
import type { ContentRendererProps } from '../../core/registry/registry'
import { ContentView } from '../ContentView'
import { TabDepthContext, useTabDepth } from '../depth'
import { TabBar } from './TabBar'

export function TabsRenderer({ node, cornerLeft, cornerRight }: ContentRendererProps<TabsContent>) {
  // The bar paints at this group's own depth; everything a tab reveals is one
  // step deeper, which is what alternates the shade and steps the indent. The
  // provider wraps only the content, so `TabBar` keeps this group's depth.
  const depth = useTabDepth()
  return (
    <div className="tabs-view">
      <TabBar group={node} />
      <div className="tabs-view-content">
        <TabDepthContext.Provider value={depth + 1}>
          {node.tabs.map((tab) => (
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
