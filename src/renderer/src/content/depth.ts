import { createContext, useContext } from 'react'

/**
 * How many tab groups enclose a node — the one number the chrome's depth
 * striping and indentation are derived from.
 *
 * Counted over tab groups ONLY, not over panes: a split contributes nothing,
 * so both halves of a split stripe and indent identically. That's what makes
 * the ladder read as "how deep am I in tabs", which is the question the
 * indentation answers; counting splits too would step the shade sideways for
 * a reason the user can't see in the bar.
 *
 * `TabsRenderer` is the only thing that provides a new value (its own + 1,
 * around its tabs' content); `Pane` is the only thing that reads it, and
 * publishes it to CSS as `--depth` / `data-depth-parity`. A floating window
 * renders its tree outside every provider, so it restarts at 0 — which is
 * right: it's its own root, not part of the docked ladder.
 */
export const TabDepthContext = createContext(0)

export function useTabDepth(): number {
  return useContext(TabDepthContext)
}
