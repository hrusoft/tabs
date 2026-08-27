import { createLeaf } from '@shared/model/factories'
import { entryPaneId } from '@shared/model/navigation'
import { findNode } from '@shared/model/tree'
import type { ContentNode, LeafContent } from '@shared/model/types'
import { EMPTY_TYPE, isSplit, isTabs } from '@shared/model/types'
import type { PaneCreationAction } from '../core/registry/registry'
import { contentRegistry } from '../core/registry/registry'

/**
 * Making content *from* an origin pane — the one rule both creation paths use,
 * and the module that owns the answer to "whose `deriveConfig` runs".
 *
 * There are exactly two ways to create non-empty content (see CLAUDE.md's
 * enablement entry), and they differ only in where the new content comes from:
 *
 * - `createContentLike` (../contentLike.ts) — New Tab, both splits, New
 *   Unpinned Pane. Clones the origin's own type and config.
 * - `createContentFor` (below) — a content type's creation button, in the pane
 *   header and in an empty pane's toolbar. Builds whatever type the button
 *   makes, from an origin that can be any type at all.
 *
 * Both then run the same tail, `applyDerivedConfig`, which resolves
 * `deriveConfig` **off the content being created** and hands it the origin
 * leaf. Through `createContentLike` those are the same type, which is exactly
 * why the ownership question went unasked for so long; through a creation
 * button they routinely differ, and that is the case the hook has to be right
 * about. Stating the rule in one function is what stops the two paths drifting
 * into two different answers.
 *
 * This module deliberately imports nothing from ../contentLike.ts — the
 * dependency runs one way, since the reverse edge would be an ESM cycle. Hence
 * `resolveOriginLeaf` living here rather than there, beside its only two
 * callers.
 */

/**
 * The leaf content that represents what a pane is "really" showing — the
 * model's own directionless entry descent (active tab, else a split's first
 * child), so this can never drift from where keyboard navigation would land.
 * The fresh empty leaf covers the degenerate non-leaf result (a tabs group
 * with no tabs), which `normalize` never actually leaves behind.
 */
export function resolveOriginLeaf(node: ContentNode): LeafContent {
  const leaf = findNode(node, entryPaneId(node))
  return leaf && !isTabs(leaf) && !isSplit(leaf) ? leaf : createLeaf(EMPTY_TYPE)
}

/**
 * `content`, with whatever its own type's `deriveConfig` hook makes of
 * `originLeaf` merged over its config.
 *
 * A type that registered no hook takes the content unchanged — and that fast
 * path matters beyond tidiness: it is what keeps every creation press that
 * *doesn't* need a lookup free of one, rather than paying an IPC round trip to
 * be told nothing.
 *
 * Structural content (a tabs group, a split) is returned untouched: it carries
 * no `config` to merge into, and no creation action produces one today.
 */
export async function applyDerivedConfig(
  content: ContentNode,
  originLeaf: LeafContent
): Promise<ContentNode> {
  if (isTabs(content) || isSplit(content)) return content
  const deriveConfig = contentRegistry.get(content.type)?.deriveConfig
  if (!deriveConfig) return content
  const derived = await deriveConfig(originLeaf)
  if (!derived) return content
  return { ...content, config: { ...content.config, ...derived } }
}

/**
 * Fresh content from a creation action, refined by the pane it was created
 * from — what both the pane header's creation group and an empty pane's
 * toolbar call.
 *
 * The origin is the pane whose chrome (or whose blank middle) was pressed. It
 * was always available at both call sites and simply never passed, which is
 * what left "open a git tree of the directory this shell is in" unreachable
 * however `deriveConfig` was arranged.
 *
 * No enablement check here, and that is not an omission: the actions these are
 * called with come from `useCreationActions` (./creationActions.ts), which has
 * already filtered out every disabled type. That remains one of the two
 * creation gates, in one place.
 */
export async function createContentFor(
  action: PaneCreationAction,
  origin: ContentNode
): Promise<ContentNode> {
  return applyDerivedConfig(action.createContent(), resolveOriginLeaf(origin))
}
