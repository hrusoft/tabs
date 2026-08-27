import type { ContentNode } from '@shared/model/types'
import { memo, useSyncExternalStore } from 'react'
import type { ContentRendererDef } from '../core/registry/registry'
import { contentRegistry, registryVersion, subscribeToRegistry } from '../core/registry/registry'
import { Pane } from './Pane'
import { UnknownContent } from './UnknownContent'

/** Re-renders when the registry changes, so late-registered types swap in live. */
function useContentDef(type: string): ContentRendererDef | undefined {
  useSyncExternalStore(subscribeToRegistry, registryVersion)
  return contentRegistry.get(type)
}

interface ContentViewProps {
  node: ContentNode
  /**
   * True exactly when this node is a TabsRenderer's own tab content — reached
   * with no split in between. Only TabsRenderer ever passes it,
   * unconditionally, to every tab it renders: the flag says nothing about
   * this node's own type, only about how it was reached, and it becomes
   * Pane's `border: 'top-only'` — left/right/bottom suppressed (they would
   * sit flush against the parent's own border and stack, leaf or tabs-group
   * alike), border-top always drawn. The full derivation — why suppression is
   * positional rather than by node type, why the top can never double — is
   * CLAUDE.md's pane-chrome entry; the rule itself lives in global.css's
   * `.pane-border-top-only` comment.
   */
  insideTabsContent?: boolean
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
 */
function ContentViewImpl({ node, insideTabsContent }: ContentViewProps) {
  const def = useContentDef(node.type)
  const content = def ? <def.Component node={node} /> : <UnknownContent node={node} />
  if (node.type === 'split') return content
  const border = insideTabsContent === true ? 'top-only' : 'full'
  return (
    <Pane node={node} border={border}>
      {content}
    </Pane>
  )
}

export const ContentView = memo(ContentViewImpl)
