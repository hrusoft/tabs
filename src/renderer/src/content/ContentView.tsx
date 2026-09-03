import { memo, useSyncExternalStore } from 'react'
import type { ContentRendererDef, ContentRendererProps } from '../core/registry/registry'
import { contentRegistry, registryVersion, subscribeToRegistry } from '../core/registry/registry'
import { Pane } from './Pane'
import { UnknownContent } from './UnknownContent'

/** Re-renders when the registry changes, so late-registered types swap in live. */
function useContentDef(type: string): ContentRendererDef | undefined {
  useSyncExternalStore(subscribeToRegistry, registryVersion)
  return contentRegistry.get(type)
}

/**
 * The single dispatch point: renders any content node through the renderer
 * registered for its type. Recursion (tabs in splits in tabs …) falls out of
 * renderers rendering ContentView for their children. Memoized so the model's
 * structural sharing pays off: an unchanged subtree keeps its node reference
 * and skips re-rendering.
 *
 * Every node is its own independently active/splittable pane, regardless of
 * nesting (a tab's content, a split's child, the root) — except `split`
 * itself, which is a layout container rather than a pane.
 *
 * The edge props (see ContentRendererProps) are forwarded unchanged to both
 * the type's own renderer — which cares only if it's TabsRenderer or
 * SplitRenderer — and, once this node actually renders as a `.pane`, to Pane
 * itself. Nothing is decided here: TabsRenderer seeds suppression for every
 * tab's content and SplitRenderer narrows it per child.
 */
function ContentViewImpl({ node, ...edges }: ContentRendererProps) {
  const def = useContentDef(node.type)
  const content = def ? <def.Component node={node} {...edges} /> : <UnknownContent node={node} />
  if (node.type === 'split') return content
  return (
    <Pane node={node} {...edges}>
      {content}
    </Pane>
  )
}

export const ContentView = memo(ContentViewImpl)
