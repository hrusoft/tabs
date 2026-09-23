/**
 * The pure "what gets checked out" policy — no git, no IPC, just a decision
 * over ref names main already read. Kept separate from
 * git.ts (which only fetches the raw refs) so the actual branch-count policy
 * is unit-testable without a repository on disk, the same split `assignLanes`
 * (../shared/graph.ts) uses for the commit graph's own policy.
 */

/** One thing a checkout can target. */
export type CheckoutTarget =
  | { kind: 'branch'; name: string }
  /** A remote-tracking branch with no local branch of its own yet — checking it out creates one, tracking `ref`. */
  | { kind: 'remote-branch'; remote: string; name: string; ref: string }
  | { kind: 'commit'; hash: string }

export type CheckoutDecision =
  | { kind: 'none' }
  | { kind: 'single'; target: CheckoutTarget }
  | { kind: 'choose'; targets: CheckoutTarget[] }

/** One `refs/remotes/*` entry pointing at the commit in question, already split into its remote and branch name. */
export interface RemoteRefInfo {
  /** The remote's own name ("origin"). */
  remote: string
  /** The branch's name as it exists on that remote — may itself contain slashes ("release/1.0"). */
  name: string
  /** `remote`/`name` back together — what `refs/remotes/` is relative to, and what `git switch --track` wants as its start point. */
  ref: string
}

/**
 * Splits a `refs/remotes/`-relative ref ("origin/feature/x") into its remote
 * and branch name.
 *
 * Matched against the repository's actual configured remotes first (longest
 * name first, so a remote whose own name happens to contain a slash — legal,
 * if unusual — still resolves correctly), since the naive "first path
 * segment" reading would misparse that case. Falls back to the first-segment
 * reading when no configured remote matches (a `git remote` read that came
 * back empty, or a ref built by hand rather than by a real fetch, as this
 * package's own e2e fixtures did before this ticket) — remote names
 * conventionally never contain a slash, so the two readings agree in the
 * overwhelming majority of repositories either way.
 */
export function splitRemoteRef(ref: string, remoteNames: readonly string[]): RemoteRefInfo {
  const byLength = [...remoteNames].sort((a, b) => b.length - a.length)
  for (const remote of byLength) {
    if (ref.startsWith(`${remote}/`)) {
      return { remote, name: ref.slice(remote.length + 1), ref }
    }
  }
  const slash = ref.indexOf('/')
  if (slash === -1) return { remote: ref, name: ref, ref }
  return { remote: ref.slice(0, slash), name: ref.slice(slash + 1), ref }
}

/**
 * The branch-count policy: which ref(s) checking out a commit actually means.
 *
 * Local branches at the commit are always the primary answer. Remote-tracking
 * branches are consulted only when there are none: a branch that is simply in
 * sync with its own remote is the ordinary case (a local branch's tip is
 * usually also its remote-tracking counterpart's tip), and counting both
 * would turn almost every everyday checkout into a spurious "which one?"
 * prompt. When nothing local is at the commit, a remote-tracking branch is a
 * real, useful target (checking out something a teammate just pushed), so it
 * is offered instead of falling straight to a detached-HEAD warning.
 *
 * A remote-tracking candidate whose branch name collides with an EXISTING
 * local branch — anywhere in the repository, not only at this commit, since
 * "my local branch is behind its remote" is the everyday version of this — is
 * dropped before the count is taken. Offering it would mean `git switch -c
 * <name> --track <ref>` fails outright ("a branch named '<name>' already
 * exists"); refusing it up front is one fewer surprising failure. If that
 * leaves no candidates at all, the commit falls through to `none` — the
 * ordinary detached-HEAD confirmation.
 */
export function decideCheckout(
  local: readonly string[],
  remotes: readonly RemoteRefInfo[],
  allLocalBranches: readonly string[]
): CheckoutDecision {
  const localNames = new Set(allLocalBranches)
  const targets: CheckoutTarget[] =
    local.length > 0
      ? local.map((name) => ({ kind: 'branch', name }))
      : remotes
          .filter((info) => !localNames.has(info.name))
          .map((info) => ({ kind: 'remote-branch', ...info }))
  if (targets.length === 0) return { kind: 'none' }
  if (targets.length === 1) return { kind: 'single', target: targets[0]! }
  return { kind: 'choose', targets }
}

/** The label a choose-dialog option shows for one target — also its unique value, since branch/remote-ref names are each unique within their own namespace. */
export function checkoutTargetLabel(target: CheckoutTarget): string {
  switch (target.kind) {
    case 'branch':
      return target.name
    case 'remote-branch':
      return target.ref
    case 'commit':
      return target.hash
  }
}
