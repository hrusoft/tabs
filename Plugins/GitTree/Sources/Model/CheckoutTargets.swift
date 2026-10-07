// The pure "what gets checked out" policy: no git, just a decision over ref
// names `Git` already read. Kept apart from the git layer (which only fetches
// the raw refs) so the policy is testable without a repository.

/// One thing a checkout can target.
enum CheckoutTarget: Equatable, Sendable {
    case branch(name: String)
    /// A remote-tracking branch with no local branch of its own yet: checking
    /// it out creates one, tracking `ref`.
    case remoteBranch(RemoteRefInfo)
    case commit(hash: String)
}

enum CheckoutDecision: Equatable, Sendable {
    case none
    case single(CheckoutTarget)
    case choose([CheckoutTarget])
}

/// One `refs/remotes/*` entry pointing at the commit, split into its remote and
/// branch name.
struct RemoteRefInfo: Equatable, Sendable {
    /// The remote's own name ("origin").
    var remote: String
    /// The branch's name on that remote; may contain slashes ("release/1.0").
    var name: String
    /// `remote`/`name` back together: what `refs/remotes/` is relative to, and
    /// what `git switch --track` wants as its start point.
    var ref: String
}

/// Splits a `refs/remotes/`-relative ref ("origin/feature/x") into its remote
/// and branch name.
///
/// Matched against the repository's configured remotes first, longest name
/// first, so a remote whose own name contains a slash (legal, if unusual)
/// still resolves; the naive first-segment reading would misparse that. Falls
/// back to the first segment when no configured remote matches (an empty
/// `git remote` read, a ref built by hand). Remote names conventionally never
/// contain a slash, so the two readings almost always agree.
func splitRemoteRef(_ ref: String, remoteNames: [String]) -> RemoteRefInfo {
    // Stable: equal lengths keep their order.
    let byLength = remoteNames.enumerated().sorted { a, b in
        a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
    }.map(\.element)
    for remote in byLength where ref.hasPrefix("\(remote)/") {
        return RemoteRefInfo(remote: remote, name: String(ref.dropFirst(remote.count + 1)), ref: ref)
    }
    guard let slash = ref.firstIndex(of: "/") else { return RemoteRefInfo(remote: ref, name: ref, ref: ref) }
    return RemoteRefInfo(remote: String(ref[..<slash]), name: String(ref[ref.index(after: slash)...]), ref: ref)
}

/// The branch-count policy: which ref(s) checking out a commit means.
///
/// Local branches at the commit are always the answer. Remote-tracking
/// branches count only when there are none: a branch in sync with its remote
/// is the ordinary case, and counting both would turn almost every checkout
/// into a spurious "which one?". With nothing local at the commit, a
/// remote-tracking branch is a real target (something a teammate just pushed),
/// so it's offered instead of falling straight to a detached HEAD.
///
/// A remote-tracking candidate whose name an existing local branch already has
/// (anywhere in the repository, not only at this commit: "my local branch is
/// behind its remote" is the everyday version) is dropped before counting:
/// `git switch -c <name> --track <ref>` would fail outright. If that leaves
/// nothing, the commit falls through to `none`.
func decideCheckout(local: [String], remotes: [RemoteRefInfo], allLocalBranches: [String]) -> CheckoutDecision {
    let localNames = Set(allLocalBranches)
    let targets: [CheckoutTarget] =
        !local.isEmpty
        ? local.map { .branch(name: $0) }
        : remotes.filter { !localNames.contains($0.name) }.map { .remoteBranch($0) }
    if targets.isEmpty { return .none }
    if targets.count == 1 { return .single(targets[0]) }
    return .choose(targets)
}

/// What a target is called: a branch by its name, a remote branch by its full
/// ref (so it reads apart from a same-named local branch), a commit by its hash.
func checkoutTargetLabel(_ target: CheckoutTarget) -> String {
    switch target {
    case .branch(let name): name
    case .remoteBranch(let info): info.ref
    case .commit(let hash): hash
    }
}
