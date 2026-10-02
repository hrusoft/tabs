import type { FakeContentHost } from '@tabs/plugin-sdk/renderer/fakeContentHost'
import { type CheckoutTarget, type RemoteRefInfo, splitRemoteRef } from '../shared/checkoutTargets'
import { GitTreeMethod } from '../shared/ipc'
import type { GitTreeFakeHandle } from '../shared/testing'
import type {
  Commit,
  CommitDetail,
  GitBranchesAtCommitResult,
  GitBranchScope,
  GitCheckoutResult,
  GitFailure,
  GitHead,
  GitLogResult
} from '../shared/types'
import { UNCOMMITTED_CHANGES_HASH } from '../shared/types'

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
  let hasUncommittedChanges = false
  let failure: GitFailure | undefined
  let defaultDirectory = '/repo'
  let chosenDirectory: string | undefined
  const details = new Map<string, CommitDetail>()
  const logCalls: string[] = []
  const scopeCalls: GitBranchScope[] = []
  const detailReads: string[] = []
  // Checking out a commit or branch. `head` is what a successful
  // `checkout()` moves — what makes "the pane refreshes to show the new
  // HEAD" an observable fact at this tier rather than plumbing nothing
  // exercises.
  let head: GitHead = { kind: 'branch', name: 'main' }
  const branchesAtCommitAnswers = new Map<
    string,
    { local: string[]; remotes: RemoteRefInfo[]; allLocalBranches: string[] }
  >()
  const branchesAtCommitCalls: string[] = []
  let branchesAtCommitRejection: Error | undefined
  const checkoutCalls: CheckoutTarget[] = []
  let checkoutFailure: { reason: GitFailure; detail?: string } | undefined
  let checkoutGateHeld = false
  const pendingCheckouts: Array<() => void> = []
  let workingTreeDetail: CommitDetail = {
    hash: UNCOMMITTED_CHANGES_HASH,
    parents: [],
    author: '',
    authorEmail: '',
    date: '',
    refs: [],
    message: 'Uncommitted changes',
    files: [],
    filesTruncated: false
  }

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

  host.handle(GitTreeMethod.log, (dir, _limit, skip, branchScope): GitLogResult => {
    logCalls.push(dir as string)
    scopeCalls.push(branchScope as GitBranchScope)
    if (failure) return { ok: false, reason: failure }
    const limit = _limit as number
    const from = skip as number
    // Paged the way the real one is, so a "Load more" test sees the same
    // shape it would from git rather than the whole list every time.
    const page = commits.slice(from, from + limit)
    return {
      ok: true,
      root,
      head,
      commits: page,
      hasMore: hasMore || from + limit < commits.length,
      hasUncommittedChanges
    }
  })
  host.handle(GitTreeMethod.commit, (_dir, hash) => {
    detailReads.push(hash as string)
    if (failure) return { ok: false, reason: failure }
    const detail = detailFor(hash as string)
    return detail
      ? { ok: true, detail }
      : { ok: false, reason: { kind: 'failed', message: `no such commit ${String(hash)}` } }
  })
  host.handle(GitTreeMethod.workingTree, () => {
    detailReads.push(UNCOMMITTED_CHANGES_HASH)
    if (failure) return { ok: false, reason: failure }
    return { ok: true, detail: workingTreeDetail }
  })
  host.handle(GitTreeMethod.defaultDirectory, () => defaultDirectory)
  host.handle(GitTreeMethod.chooseDirectory, () => chosenDirectory)
  host.handle(GitTreeMethod.branchesAtCommit, (_dir, hash): GitBranchesAtCommitResult => {
    branchesAtCommitCalls.push(hash as string)
    // Thrown, not returned as a `GitFailure` — this simulates the IPC hop
    // itself rejecting (main.branchesAtCommit never rejects for real; see
    // git.ts's own "never a rejection" rule), which the fake's `invoke`
    // turns into a rejected promise the same way a real ipcRenderer.invoke
    // failure would.
    if (branchesAtCommitRejection) throw branchesAtCommitRejection
    const answer = branchesAtCommitAnswers.get(hash as string) ?? {
      local: [],
      remotes: [],
      allLocalBranches: []
    }
    return { ok: true, ...answer }
  })
  host.handle(GitTreeMethod.checkout, (_dir, target): Promise<GitCheckoutResult> => {
    checkoutCalls.push(target as CheckoutTarget)
    return new Promise<GitCheckoutResult>((resolve) => {
      const settle = (): void => {
        if (checkoutFailure) {
          resolve({
            ok: false,
            reason: checkoutFailure.reason,
            ...(checkoutFailure.detail === undefined ? {} : { detail: checkoutFailure.detail })
          })
          return
        }
        const checkoutTarget = target as CheckoutTarget
        head =
          checkoutTarget.kind === 'commit'
            ? { kind: 'detached', hash: checkoutTarget.hash }
            : { kind: 'branch', name: checkoutTarget.name }
        resolve({ ok: true })
      }
      if (checkoutGateHeld) pendingCheckouts.push(settle)
      else settle()
    })
  })

  return {
    setGitTreeLog: (next, options) => {
      commits = next
      failure = undefined
      if (options?.root !== undefined) root = options.root
      hasMore = options?.hasMore ?? false
      hasUncommittedChanges = options?.hasUncommittedChanges ?? false
    },
    setGitTreeFailure: (reason) => {
      failure = reason
    },
    setGitTreeCommitDetail: (hash, detail) => {
      details.set(hash, detail)
    },
    setGitTreeWorkingTreeDetail: (detail) => {
      workingTreeDetail = detail
    },
    setGitTreeHead: (next) => {
      head = next
    },
    setGitTreeDefaultDirectory: (dir) => {
      defaultDirectory = dir
    },
    setGitTreeChosenDirectory: (dir) => {
      chosenDirectory = dir
    },
    gitTreeLogCalls: () => [...logCalls],
    gitTreeLogScopes: () => [...scopeCalls],
    gitTreeDetailReads: () => [...detailReads],
    setGitTreeBranchesAtCommit: (hash, refs) => {
      branchesAtCommitAnswers.set(hash, {
        local: refs.local ?? [],
        // The test-facing shape stays plain "origin/feature-x" strings — the
        // real per-remote matching splitRemoteRef offers is a main-side fact
        // (git.test.ts pins it against real git); this fake only needs a
        // consistent split, which its own naive fallback (no configured
        // remote names) already gives for every ordinary remote name.
        remotes: (refs.remotes ?? []).map((ref) => splitRemoteRef(ref, [])),
        allLocalBranches: refs.allLocalBranches ?? []
      })
    },
    setGitTreeCheckoutFailure: (reason, detail) => {
      checkoutFailure =
        reason === undefined ? undefined : { reason, ...(detail === undefined ? {} : { detail }) }
    },
    setGitTreeCheckoutGate: (held) => {
      checkoutGateHeld = held
    },
    releaseGitTreeCheckout: () => {
      for (const settle of pendingCheckouts.splice(0)) settle()
    },
    gitTreeCheckoutCalls: () => [...checkoutCalls],
    gitTreeBranchesAtCommitCalls: () => [...branchesAtCommitCalls],
    setGitTreeBranchesAtCommitRejection: (error) => {
      branchesAtCommitRejection = error
    }
  }
}
