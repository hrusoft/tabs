import { createPaneValueStore } from '../../../renderer/src/plugin/api'
import type { GitHead } from '../shared/types'

/**
 * Where each pane's HEAD currently is — the one piece of `GitTreeRenderer`'s
 * state that `GitTreeHeaderTitle` needs for its own HEAD label and cannot
 * get from `leaf.config`/`gitTreeBridge` directly. Everything else the
 * header does (the path bar, the browse button, the branch-scope select)
 * writes through `setLeafConfig`/`gitTreeBridge`, which either component can
 * already reach on its own.
 *
 * A subscription rather than a one-time read because of mount order — see
 * createPaneValueStore. Unlike terminalRegistry.ts/browserRegistry.ts this
 * is not a reattach registry: a git tree pane owns no live OS resource to
 * keep alive across a remount.
 */
export const gitTreeHeads = createPaneValueStore<GitHead>()
