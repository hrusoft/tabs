import type { LeafContent } from '@shared/model/types'
import type { Dispatch, SetStateAction } from 'react'
import { paneTitleForContent } from '../core/registry/titles'
import { useLayoutStore } from '../core/store/layoutStore'
import { InlineTitleEditor } from './InlineTitleEditor'

/**
 * The pane header's title slot when a content type declares no
 * `ContentRendererDef.HeaderTitle` of its own — the overwhelming majority of
 * types. Double-click, or the header's right-click "Edit title" entry (see
 * Pane.tsx, which only offers that entry while this component is the active
 * title slot), swaps in `InlineTitleEditor`. `isEditingTitle` stays owned by
 * Pane.tsx rather than moving in here: it also gates that component's own
 * drag-arm guard and context-menu guard, so it has to be visible there
 * regardless of which title slot is rendering.
 */
export function DefaultPaneTitle({
  node,
  isEditingTitle,
  setIsEditingTitle
}: {
  node: LeafContent
  isEditingTitle: boolean
  setIsEditingTitle: Dispatch<SetStateAction<boolean>>
}) {
  const renamePane = useLayoutStore((state) => state.renamePane)

  if (isEditingTitle) {
    return (
      <InlineTitleEditor
        initialValue={paneTitleForContent(node)}
        className="pane-title-input"
        ariaLabel="Pane title"
        // Saving an emptied box reverts to the derived content-type label
        // rather than being rejected — unlike a tab's title, a pane's is an
        // optional override.
        onSave={(trimmed) => renamePane(node.id, trimmed === '' ? undefined : trimmed)}
        onDone={() => setIsEditingTitle(false)}
      />
    )
  }

  return (
    // Double-click to rename — the header's right-click "Edit title" entry
    // is the equivalent entry point.
    // biome-ignore lint/a11y/noStaticElementInteractions: see above
    <span className="pane-title" onDoubleClick={() => setIsEditingTitle(true)}>
      {paneTitleForContent(node)}
    </span>
  )
}
