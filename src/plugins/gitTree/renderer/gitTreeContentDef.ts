import { createLeaf } from '@shared/model/factories'
import type { LeafContent } from '@shared/model/types'
import type { ContentRendererDef } from '../../../renderer/src/plugin/api'
import { GIT_TREE_TYPE, manifest as gitTreeManifest } from '../shared/manifest'
import { GitTreeRenderer } from './GitTreeRenderer'
import { GitTreeIcon } from './gitTreeIcons'
import { gitTreeCtx } from './pluginContext'

/**
 * The git tree's content-registry contribution — registered by
 * registerBuiltins, which must stay this module's only importer: it pulls in
 * GitTreeRenderer and with it the type's CSS side-effect import.
 *
 * Identity comes from the shared census rather than being restated here, so
 * this def and the main-process module cannot disagree about what a git tree
 * is called (see shared/content/registry.ts).
 *
 * **`createAction` seeds no `cwd`, deliberately.** Seeding a literal the way
 * the terminal seeds `'~'` would be worse than useless — a home directory is
 * rarely a repository, so a pane that inherited nothing would open on a
 * failure notice. A pane with no configured directory adopts one on mount from
 * `gitTree.defaultDirectory()` instead, which is the fallback whenever
 * `deriveConfig` below comes up empty.
 *
 * `mayBlockClose` is absent for the ordinary reason: a git tree pane owns no
 * live work, so closing one destroys nothing.
 */
export const gitTreeContentDef: ContentRendererDef<LeafContent> = {
  type: gitTreeManifest.type,
  displayName: gitTreeManifest.displayName,
  Component: GitTreeRenderer,
  createAction: {
    testId: 'pane-new-git-tree-button',
    label: 'New git tree',
    Icon: GitTreeIcon,
    createContent: () => createLeaf(GIT_TREE_TYPE)
  },
  /**
   * Open on the repository the pane this was created from is sitting in —
   * "give me the history of what this shell is looking at", which is the
   * whole reason anyone opens one of these from a terminal.
   *
   * Asks the origin's own type through `exposedCwdOf`, so this file names no
   * other content type and gains nothing to update when a third one learns to
   * expose a directory. A terminal answers with its pty's *live* directory,
   * which is the only useful answer — `config.cwd` there is a stale snapshot
   * from before every `cd` the user typed.
   *
   * Ungated. `inheritCwdOnNewPane` is the terminal's own settings key and
   * reading it from here would cross the blob boundary; more to the point, a
   * git tree's directory *is* its subject, so a pane that declined to use one
   * it had been handed would just be showing the wrong repository. Origins
   * that expose nothing (an empty pane, a browser) fall through to the
   * renderer's own default-directory lookup, which is the same path a pane
   * created with no origin at all takes.
   */
  async deriveConfig(originLeaf) {
    const cwd = await gitTreeCtx.get().exposedCwdOf(originLeaf)
    return cwd ? { cwd } : undefined
  },
  /**
   * The repository this pane is showing, for a pane of another type created
   * from it — what makes New terminal on a git tree open a shell in that repo.
   *
   * The configured directory rather than a live lookup, and that is exact
   * rather than approximate: unlike a terminal's, a git tree's directory only
   * ever changes through its own path bar or browse button, both of which
   * write it straight back to config (see GitTreeRenderer). Undefined while a
   * freshly created pane is still adopting its default.
   */
  exposeCwd: async (leaf) => leaf.config.cwd as string | undefined
}
