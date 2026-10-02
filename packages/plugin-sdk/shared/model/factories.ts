import { createId } from './ids'
import type {
  ContentNode,
  LeafContent,
  NodeId,
  SplitContent,
  SplitDirection,
  Tab,
  TabsContent
} from './types'

export function createLeaf(
  type: string,
  config: Record<string, unknown> = {},
  id: NodeId = createId()
): LeafContent {
  return { id, type, config }
}

export function createTab(title: string, content: ContentNode, id: NodeId = createId()): Tab {
  return { id, title, content }
}

export function createTabs(
  tabs: Tab[] = [],
  opts: { id?: NodeId; activeTabId?: NodeId | null } = {}
): TabsContent {
  return {
    id: opts.id ?? createId(),
    type: 'tabs',
    tabs,
    activeTabId: opts.activeTabId !== undefined ? opts.activeTabId : (tabs[0]?.id ?? null)
  }
}

export function createSplit(
  direction: SplitDirection,
  children: ContentNode[],
  opts: { id?: NodeId; sizes?: number[] } = {}
): SplitContent {
  return {
    id: opts.id ?? createId(),
    type: 'split',
    direction,
    children,
    sizes: opts.sizes ?? evenSizes(children.length)
  }
}

export function evenSizes(count: number): number[] {
  return Array.from({ length: count }, () => 1 / count)
}
