import { collectLeaves } from '@shared/model/tree'
import type { ContentNode } from '@shared/model/types'
import { contentRegistry } from '../core/registry/registry'

/**
 * Resolves whether it's OK to destroy everything under `node` — false only
 * when the user was warned about live work and chose Cancel. Which content
 * types *can* block a close is the registry's to say (`mayBlockClose` — the
 * same per-type question shape as titles.ts); which of those leaves actually
 * block right now is the main process's (see main/closeBlockers.ts). Skips
 * the IPC round-trip entirely when no leaf's type can block (e.g. an empty
 * pane), so plain closes stay instant. A leaf whose type isn't registered
 * can't block either — nothing knows what work it would be doing.
 */
export function confirmClosingContent(node: ContentNode | null): Promise<boolean> {
  if (!node) return Promise.resolve(true)
  const ids = collectLeaves(node)
    .filter((leaf) => contentRegistry.get(leaf.type)?.mayBlockClose)
    .map((leaf) => leaf.id)
  if (ids.length === 0) return Promise.resolve(true)
  return window.api.pane.confirmClose(ids)
}
