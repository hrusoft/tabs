import type { RendererPluginContext } from '@tabs/plugin-sdk/renderer/api'
import { gitTreeContentDef } from '../renderer/gitTreeContentDef'
import { installGitTreeSettingsAccess } from '../renderer/gitTreeSettingsAccess'
import { gitTreeCtx } from '../renderer/pluginContext'
import { gitTreeFake } from '../shared/testing'
import type { Commit, CommitDetail, GitFailure, GitHead } from '../shared/types'

/**
 * The git tree as the native-vs-Electron visual comparison renders it
 * (native/Visual/capture-electron.mjs, through the Chromium harness). Never
 * part of the app: reached only from the harness's registerTestContent.ts.
 *
 * The real thing: the same content def `activate` registers, so the toolbar
 * is the pane header's own `HeaderTitle` and the body is the real
 * `GitTreeRenderer`. What this adds is the scenario's seed — the fake
 * bridge's history — in place of a repository.
 */

/** One git tree's history as a scenario seeds it (the README's `gitTree.<leaf id>`, minus `select`). */
export interface GitTreeVisualSeed {
  log?: { root: string; commits: Commit[]; hasMore?: boolean; hasUncommittedChanges?: boolean }
  failure?: GitFailure
  details?: Record<string, CommitDetail>
  workingTree?: CommitDetail
  head?: GitHead
}

/**
 * The capture's stand-in for this package's `activate`: the same context,
 * settings wiring and content def, with the fake bridge seeded with the
 * scenario's history.
 */
export function activateVisualCapture(ctx: RendererPluginContext, seed: GitTreeVisualSeed): void {
  gitTreeCtx.set(ctx)
  installGitTreeSettingsAccess(ctx.settings)

  const fake = gitTreeFake()
  if (!fake) throw new Error('git tree visual capture: no fake bridge')
  if (seed.log) {
    const { commits, ...options } = seed.log
    fake.setGitTreeLog(commits, options)
  }
  if (seed.failure) fake.setGitTreeFailure(seed.failure)
  for (const [hash, detail] of Object.entries(seed.details ?? {})) {
    fake.setGitTreeCommitDetail(hash, detail)
  }
  if (seed.workingTree) fake.setGitTreeWorkingTreeDetail(seed.workingTree)
  if (seed.head) fake.setGitTreeHead(seed.head)

  ctx.registerContent(gitTreeContentDef)
}
