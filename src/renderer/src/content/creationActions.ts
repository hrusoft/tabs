import { isContentTypeEnabled } from '@shared/content/enablement'
import { useSyncExternalStore } from 'react'
import type { PaneCreationAction } from '../core/registry/registry'
import { contentRegistry, registryVersion, subscribeToRegistry } from '../core/registry/registry'
import { useSettingsStore } from '../core/store/settingsStore'

/**
 * What both creation surfaces say when the list below comes back empty — one
 * sentence, because two spellings would drift and both are asserted verbatim
 * in tests.
 */
export const NO_CONTENT_TYPES_MESSAGE =
  'No content types are enabled — turn one on in Settings → General → Content types.'

/**
 * The creation actions content types contribute, in registration order, minus
 * any the user has turned off (see shared/content/enablement.ts).
 *
 * This is one of the two creation gates CLAUDE.md counts —
 * `createAction.createContent()` — and it lives alone in its own module
 * because it now has two consumers: the pane header's creation group
 * (PaneHeaderControls.tsx) and the toolbar an empty pane shows in place of a
 * placeholder (empty/EmptyPaneRenderer.tsx). Both offer exactly the same set
 * of types and call exactly the same factory, so a second copy of this filter
 * would be a second gate to keep in step — which is the thing "there are
 * exactly two gates" exists to prevent. A new user-facing way to create
 * content belongs here rather than beside a third `isContentTypeEnabled` call.
 *
 * Subscribed to the one settings key rather than to the store as a whole: this
 * hook runs once per mounted pane, and a whole-store subscription would
 * re-render every header on every tick of a settings *drag* (the dimming
 * intensity slider fires per input event).
 *
 * Filtering here rather than skipping the type's registration is the point of
 * the feature — a disabled type's existing panes keep their renderer, and
 * unregistering would drop a live pane's rendering the next time the layout
 * normalized. Note the list feeds a `[root, ...rest]` destructure in the pane
 * header, so disabling the first type promotes the next enabled one to the
 * always-visible root button; the visible icon changing is expected. An empty
 * pane's toolbar has no such hierarchy — it shows the whole list at once.
 *
 * Each action also carries its type's plain `displayName` ('Terminal', not
 * the button's imperative `label` — 'New terminal'): the command palette
 * lists content types by name rather than repeating "New" per row, and
 * `def` already has both in hand here, so there's nothing to look up twice.
 */
export function useCreationActions(): (PaneCreationAction & { displayName: string })[] {
  useSyncExternalStore(subscribeToRegistry, registryVersion)
  const disabledContentTypes = useSettingsStore((state) => state.disabledContentTypes)
  return contentRegistry
    .list()
    .flatMap((def) =>
      def.createAction && isContentTypeEnabled(disabledContentTypes, def.type)
        ? [{ ...def.createAction, displayName: def.displayName }]
        : []
    )
}
