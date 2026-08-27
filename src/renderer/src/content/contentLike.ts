import { isContentTypeEnabled } from '@shared/content/enablement'
import { createLeaf } from '@shared/model/factories'
import type { ContentNode } from '@shared/model/types'
import { EMPTY_TYPE } from '@shared/model/types'
import { useSettingsStore } from '../core/store/settingsStore'
import { applyDerivedConfig, resolveOriginLeaf } from './createFrom'

/**
 * Fresh content of the same type (and config) as `origin`, for a new pane
 * that should pick up where the pane it was split/tabbed from left off —
 * e.g. splitting a terminal opens another terminal, splitting an empty pane
 * stays empty. Never copies a custom title override; the new pane gets the
 * default type-derived label.
 *
 * A type that registered a `deriveConfig` hook gets to refine the copied
 * config (the terminal swaps in its live cwd); everyone else takes the plain
 * copy with no await at all. A rejecting hook rejects this whole call. The
 * merge itself is `applyDerivedConfig` (./createFrom.ts), shared with the
 * creation-button path so the two cannot disagree about whose hook runs —
 * here the origin's type and the created type are the same by construction,
 * which is precisely what made that question easy to get wrong.
 *
 * A disabled origin type yields an empty pane instead of a copy, and that is
 * the whole reason this function reads settings at all. Every creation path
 * except the content-type buttons themselves comes through here — New Tab,
 * both splits and New Unpinned Pane, from the keyboard shortcuts and from the
 * header's split group alike — so without the check a single surviving pane
 * of a disabled type would remain a factory for new ones indefinitely, and
 * "disabled" would mean nothing to anyone who happened to have one open. The
 * check runs before `deriveConfig`, so a disabled type's hook is never asked
 * to derive config for a pane that isn't going to exist.
 */
export async function createContentLike(origin: ContentNode): Promise<ContentNode> {
  const leaf = resolveOriginLeaf(origin)
  if (!isContentTypeEnabled(useSettingsStore.getState().disabledContentTypes, leaf.type)) {
    return createLeaf(EMPTY_TYPE)
  }
  return applyDerivedConfig(createLeaf(leaf.type, { ...leaf.config }), leaf)
}
