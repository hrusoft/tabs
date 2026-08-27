import type { FakeContentHost } from '@shared/testing/fakeApiHandle'
import { GitTreeMethod } from '../shared/ipc'
import type { GitTreeFakeHandle } from '../shared/testing'
import type { Commit, CommitDetail, GitFailure, GitLogResult } from '../shared/types'

/**
 * The git tree's fake main entry, installed into the fake content bridge,
 * plus the driver that scripts it.
 *
 * Answers out of memory what the real main entry would answer out of `git`.
 * That is enough to drive the whole renderer because the real bridge is
 * already pure data in both directions — main classifies every failure into a
 * `GitFailure` value rather than rejecting, so this fake has no error path to
 * imitate, only values to hand back.
 *
 * `commit` synthesizes a plausible detail from the matching log entry unless
 * a test set one explicitly, so a test about keyboard navigation doesn't have
 * to author commit details it never looks at.
 */
export function installFake(host: FakeContentHost): GitTreeFakeHandle {
  let commits: Commit[] = []
  let root = '/repo'
  let hasMore = false
  let failure: GitFailure | undefined
  let defaultDirectory = '/repo'
  let chosenDirectory: string | undefined
  const details = new Map<string, CommitDetail>()
  const logCalls: string[] = []

  function detailFor(hash: string): CommitDetail | undefined {
    const explicit = details.get(hash)
    if (explicit) return explicit
    const commit = commits.find((candidate) => candidate.hash === hash)
    if (!commit) return undefined
    return {
      hash: commit.hash,
      parents: commit.parents,
      author: commit.author,
      authorEmail: `${commit.author.toLowerCase()}@example.com`,
      date: commit.date,
      refs: commit.refs,
      message: commit.subject,
      files: [],
      filesTruncated: false
    }
  }

  host.handle(GitTreeMethod.log, (dir, _limit, skip): GitLogResult => {
    logCalls.push(dir as string)
    if (failure) return { ok: false, reason: failure }
    const limit = _limit as number
    const from = skip as number
    // Paged the way the real one is, so a "Load more" test sees the same
    // shape it would from git rather than the whole list every time.
    const page = commits.slice(from, from + limit)
    return {
      ok: true,
      root,
      head: { kind: 'branch', name: 'main' },
      commits: page,
      hasMore: hasMore || from + limit < commits.length
    }
  })
  host.handle(GitTreeMethod.commit, (_dir, hash) => {
    if (failure) return { ok: false, reason: failure }
    const detail = detailFor(hash as string)
    return detail
      ? { ok: true, detail }
      : { ok: false, reason: { kind: 'failed', message: `no such commit ${String(hash)}` } }
  })
  host.handle(GitTreeMethod.defaultDirectory, () => defaultDirectory)
  host.handle(GitTreeMethod.chooseDirectory, () => chosenDirectory)

  return {
    setGitTreeLog: (next, options) => {
      commits = next
      failure = undefined
      if (options?.root !== undefined) root = options.root
      hasMore = options?.hasMore ?? false
    },
    setGitTreeFailure: (reason) => {
      failure = reason
    },
    setGitTreeCommitDetail: (hash, detail) => {
      details.set(hash, detail)
    },
    setGitTreeDefaultDirectory: (dir) => {
      defaultDirectory = dir
    },
    setGitTreeChosenDirectory: (dir) => {
      chosenDirectory = dir
    },
    gitTreeLogCalls: () => [...logCalls]
  }
}
