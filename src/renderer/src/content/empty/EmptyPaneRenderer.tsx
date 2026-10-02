import { fireAndReport } from '@tabs/plugin-sdk/renderer/fireAndReport'
import { paneAttr } from '@tabs/plugin-sdk/shared/paneDomAttrs'
import type { ContentRendererProps } from '../../core/registry/registry'
import { useDragStore } from '../../core/store/dragStore'
import { useLayoutStore } from '../../core/store/layoutStore'
import { createContentFor } from '../createFrom'
import { NO_CONTENT_TYPES_MESSAGE, useCreationActions } from '../creationActions'

/**
 * A content-less pane: a row of "fill me with this" buttons, one per enabled
 * content type — or, when every type is turned off, the one sentence that says
 * why the row is missing and where to fix it.
 *
 * Each button opens its type's content aimed at this pane —
 * `openContent(node.id, …)` — which needs no placement rule or store operation
 * of its own: `tree.openContent` already replaces an empty target in place
 * rather than tabbing beside it (its "an empty pane -> `content` replaces it"
 * branch).
 *
 * Icons, labels and factories all come from `createAction` on the content
 * registry (../creationActions.ts), so a new content type appears here for
 * free the moment it declares a `createAction` — no list here to add it to.
 */
export function EmptyPaneRenderer({ node }: ContentRendererProps) {
  const isDropTarget = useDragStore(
    (state) => state.drag?.target?.kind === 'empty-pane' && state.drag.target.paneId === node.id
  )
  const openContent = useLayoutStore((state) => state.openContent)
  const creationActions = useCreationActions()

  return (
    <div
      className={isDropTarget ? 'empty-pane empty-pane-drop-target' : 'empty-pane'}
      data-testid="empty-pane"
      {...paneAttr('dropEmptyPane', node.id)}
    >
      {creationActions.length > 0 ? (
        // One flex row, no gap: the shared edges are what make this read as a
        // single segmented control rather than as loose chips, so the seam
        // between two buttons is one hairline and not two stacked (see
        // `.empty-pane-toolbar` in global.css).
        <div className="empty-pane-toolbar" data-testid="empty-pane-toolbar">
          {creationActions.map((action) => (
            <button
              key={action.testId}
              type="button"
              // Prefixed (`empty-…`): the id every test tier addresses these
              // buttons by, and distinct from the palette's rows for the same
              // types.
              data-testid={`empty-${action.testId}`}
              aria-label={action.label}
              title={action.label}
              onClick={(event) => {
                // The press isolation HeaderButton documents, for the same
                // reason: this click must not bubble into Pane's activate
                // handler, which would aim setActivePane at the id of the leaf
                // this very call just replaced. (Harmless in itself —
                // setActivePane no-ops on an id no tree holds — but the
                // contract belongs here rather than resting on that.)
                event.stopPropagation()
                // Origin-aware like every creation path, and the origin here
                // is this blank pane itself — which offers no
                // directory, so a type that would have inherited one falls
                // back to its own default instead. That fallback is the
                // point: an empty pane is the one origin guaranteed to have
                // nothing to give.
                fireAndReport(() =>
                  createContentFor(action, node).then((content) => openContent(node.id, content))
                )
              }}
            >
              <action.Icon />
            </button>
          ))}
        </div>
      ) : (
        // Only reachable from Settings → General → Content types, so the text
        // names the way back (see NO_CONTENT_TYPES_MESSAGE).
        <p>{NO_CONTENT_TYPES_MESSAGE}</p>
      )}
    </div>
  )
}
