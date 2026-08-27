import type { LeafContent } from '@shared/model/types'
import { contentRegistry } from '../core/registry/registry'

/**
 * The working directory a pane is showing, asked of whichever type owns it —
 * the read side of `ContentRendererDef.exposeCwd`.
 *
 * One function rather than each caller doing the registry lookup itself,
 * because the lookup is the whole contract: **ask the origin's own type**,
 * never assume a config key. A `deriveConfig` hook reaching into
 * `originLeaf.config.cwd` directly would appear to work — the terminal and the
 * git tree both happen to store one under that name — and would be wrong for
 * both of them: a terminal's is a stale snapshot from before every `cd` the
 * user has typed (see CLAUDE.md), and a type that named the key something else
 * would be silently ignored rather than failing.
 *
 * Undefined is the ordinary answer, not an error: it means the origin's type
 * declares no directory, offers none for this leaf, or is a type nothing has
 * registered at all (the `empty` pane, most obviously — a git tree created
 * from a blank pane has nothing to inherit and falls back to its own default).
 * Every caller must degrade rather than treat it as a failure.
 */
export async function exposedCwdOf(leaf: LeafContent): Promise<string | undefined> {
  return contentRegistry.get(leaf.type)?.exposeCwd?.(leaf)
}
