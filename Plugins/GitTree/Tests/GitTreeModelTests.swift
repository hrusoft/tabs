import Foundation
import TabsPluginSDK
import Testing

// The pure logic. Case ids are docs/GIT-TREE.md's.

/// A commit with only the fields lane assignment reads.
private func commit(_ hash: String, _ parents: String...) -> Commit {
    Commit(hash: hash, parents: parents, author: "A", date: "2026-01-01T00:00:00Z", refs: [], subject: hash)
}

// MARK: - Lane assignment (R-1)

@Suite("a linear history") struct LinearHistoryTests {
    // c
    // |
    // b
    // |
    // a
    let graph = assignLanes([commit("c", "b"), commit("b", "a"), commit("a")])

    @Test("keeps every commit in one column") func keepsEveryCommitInOneColumn() {
        #expect(graph.rows.map(\.lane) == [0, 0, 0])
        #expect(graph.laneCount == 1)
    }

    @Test("links each row to the next through the dot, with nothing passing by") func linksEachRow() {
        #expect(graph.rows.map(\.incoming) == [[], [0], [0]])
        #expect(graph.rows.map(\.outgoing) == [[0], [0], []])
        #expect(graph.rows.allSatisfy { $0.through.isEmpty })
    }

    @Test("leaves the root commit with no line below it") func leavesTheRoot() {
        #expect(graph.rows[2].outgoing == [])
    }
}

@Suite("a fork") struct ForkTests {
    // c d
    // |/
    // b
    // |
    // a
    let graph = assignLanes([commit("c", "b"), commit("d", "b"), commit("b", "a"), commit("a")])

    @Test("gives the second tip a lane of its own") func secondTipOwnLane() {
        #expect(graph.rows.map(\.lane) == [0, 1, 0, 0])
        #expect(graph.laneCount == 2)
    }

    @Test("converges both branches into the commit they share") func converges() {
        #expect(graph.rows[2].incoming == [0, 1])
        #expect(graph.rows[2].lane == 0)
    }

    @Test("draws the first tip past the second row rather than through its dot") func firstTipPasses() {
        #expect(graph.rows[1].through == [0])
        #expect(graph.rows[1].incoming == [])
    }

    @Test("is back to one lane by the root") func backToOneLane() {
        #expect(graph.rows[3].lane == 0)
        #expect(graph.rows[3].through == [])
    }
}

@Suite("a merge") struct MergeTests {
    // m
    // |\
    // | c
    // b |
    // |/
    // a
    let graph = assignLanes([commit("m", "b", "c"), commit("c", "a"), commit("b", "a"), commit("a")])

    @Test("leaves the merge commit by two lines, first parent in its own lane") func leavesByTwoLines() {
        #expect(graph.rows[0].lane == 0)
        #expect(graph.rows[0].outgoing == [0, 1])
    }

    @Test("places the second parent in the lane the merge opened for it") func placesSecondParent() {
        #expect(graph.rows[1].commit.hash == "c")
        #expect(graph.rows[1].lane == 1)
        #expect(graph.rows[1].incoming == [1])
        #expect(graph.rows[1].through == [0])
    }

    @Test("brings both sides back together at their common ancestor") func bringsBothSides() {
        #expect(graph.rows[3].commit.hash == "a")
        #expect(graph.rows[3].incoming == [0, 1])
        #expect(graph.rows[3].lane == 0)
    }

    @Test("never needs more than two columns") func twoColumns() {
        #expect(graph.laneCount == 2)
    }
}

@Suite("a diamond") struct DiamondTests {
    // m
    // |\
    // d c
    // |/
    // a
    let graph = assignLanes([commit("m", "d", "c"), commit("c", "a"), commit("d", "a"), commit("a")])

    @Test("draws no line out of the row between the fork and its shared parent") func noStrayLine() {
        #expect(graph.rows[2].commit.hash == "d")
        #expect(graph.rows[2].outgoing == [0])
        #expect(graph.rows[2].through == [1])
    }

    @Test("brings both siblings back together at the shared parent") func siblingsMeet() {
        #expect(graph.rows[3].commit.hash == "a")
        #expect(graph.rows[3].incoming == [0, 1])
    }
}

@Suite("an octopus merge") struct OctopusTests {
    let graph = assignLanes([
        commit("m", "b", "c", "d"), commit("b", "a"), commit("c", "a"), commit("d", "a"), commit("a"),
    ])

    @Test("opens one lane per parent") func oneLanePerParent() {
        #expect(graph.rows[0].outgoing == [0, 1, 2])
        #expect(graph.laneCount == 3)
    }

    @Test("lands each parent in the lane its edge pointed at") func landsEachParent() {
        let pairs = graph.rows[1..<4].map { "\($0.commit.hash)\($0.lane)" }
        #expect(pairs == ["b0", "c1", "d2"])
    }

    @Test("collapses all three back into the shared root") func collapses() {
        #expect(graph.rows[4].incoming == [0, 1, 2])
        #expect(graph.rows[4].lane == 0)
        #expect(graph.rows[4].outgoing == [])
    }
}

@Suite("multiple roots") struct MultipleRootsTests {
    let graph = assignLanes([commit("b", "a"), commit("a"), commit("d", "c"), commit("c")])

    @Test("reuses the lane the first history freed rather than growing the gutter") func reusesLane() {
        #expect(graph.rows.map(\.lane) == [0, 0, 0, 0])
        #expect(graph.laneCount == 1)
    }

    @Test("draws no line between the two histories") func noLineBetween() {
        #expect(graph.rows[1].outgoing == [])
        #expect(graph.rows[2].incoming == [])
    }
}

@Suite("a lane freed mid-history") struct FreedLaneTests {
    let graph = assignLanes([commit("c", "b"), commit("x"), commit("b", "a"), commit("t"), commit("a")])

    @Test("hands the freed lane to the next tip") func handsFreedLane() {
        #expect(graph.rows[1].commit.hash == "x")
        #expect(graph.rows[1].lane == 1)
        #expect(graph.rows[3].commit.hash == "t")
        #expect(graph.rows[3].lane == 1)
        #expect(graph.laneCount == 2)
    }
}

@Suite("a truncated log") struct TruncatedLogTests {
    @Test("still draws the dangling line out of the last row") func danglingLine() {
        let graph = assignLanes([commit("c", "b"), commit("b", "a")])
        #expect(graph.rows[1].outgoing == [0])
    }
}

@Suite("an empty log") struct EmptyLogTests {
    @Test("produces no rows and no gutter") func noRows() {
        #expect(assignLanes([]) == CommitGraph(rows: [], laneCount: 0))
    }
}

// MARK: - Checkout targets (C-12)

@Suite("splitRemoteRef") struct SplitRemoteRefTests {
    @Test("splits on the matching configured remote, even when the branch name has slashes of its own") func splits() {
        #expect(
            splitRemoteRef("origin/feature/x", remoteNames: ["origin"])
                == RemoteRefInfo(remote: "origin", name: "feature/x", ref: "origin/feature/x"))
    }

    @Test("prefers the longest matching remote name, so a remote whose own name has a slash still resolves") func longest() {
        #expect(
            splitRemoteRef("origin/staging/main", remoteNames: ["origin", "origin/staging"])
                == RemoteRefInfo(remote: "origin/staging", name: "main", ref: "origin/staging/main"))
    }

    @Test("falls back to the first path segment when no configured remote matches") func firstSegment() {
        #expect(
            splitRemoteRef("origin/feature-x", remoteNames: [])
                == RemoteRefInfo(remote: "origin", name: "feature-x", ref: "origin/feature-x"))
    }

    @Test("falls back to the whole string as both remote and name when there is no slash at all") func wholeString() {
        #expect(splitRemoteRef("origin", remoteNames: []) == RemoteRefInfo(remote: "origin", name: "origin", ref: "origin"))
    }
}

@Suite("decideCheckout") struct DecideCheckoutTests {
    private func remote(_ remote: String, _ name: String) -> RemoteRefInfo {
        RemoteRefInfo(remote: remote, name: name, ref: "\(remote)/\(name)")
    }

    @Test("checks out the one local branch with no prompt") func oneLocal() {
        #expect(decideCheckout(local: ["main"], remotes: [], allLocalBranches: ["main"]) == .single(.branch(name: "main")))
    }

    @Test("prompts among several local branches, never mixing in a remote") func severalLocal() {
        let decision = decideCheckout(
            local: ["main", "stable"], remotes: [remote("origin", "main")], allLocalBranches: ["main", "stable"])
        #expect(decision == .choose([.branch(name: "main"), .branch(name: "stable")]))
    }

    @Test("ignores remote-tracking branches entirely once any local branch is at the commit — the everyday in-sync case")
    func ignoresRemotes() {
        #expect(
            decideCheckout(local: ["main"], remotes: [remote("origin", "main")], allLocalBranches: ["main"])
                == .single(.branch(name: "main")))
    }

    @Test("falls back to a lone remote-tracking branch when there is no local branch at all") func loneRemote() {
        #expect(
            decideCheckout(local: [], remotes: [remote("origin", "feature-x")], allLocalBranches: ["main"])
                == .single(.remoteBranch(remote("origin", "feature-x"))))
    }

    @Test("prompts among several remote-tracking branches when there is no local branch") func severalRemotes() {
        let decision = decideCheckout(
            local: [], remotes: [remote("origin", "feature-x"), remote("upstream", "feature-x")], allLocalBranches: ["main"])
        #expect(decision == .choose([.remoteBranch(remote("origin", "feature-x")), .remoteBranch(remote("upstream", "feature-x"))]))
    }

    @Test("drops a remote-tracking branch whose name collides with an existing local branch anywhere in the repo") func dropsCollision() {
        #expect(
            decideCheckout(local: [], remotes: [remote("origin", "feature")], allLocalBranches: ["main", "feature"])
                == CheckoutDecision.none)
    }

    @Test("falls through to none when a collision drops the only remote candidate, even with others left unfiltered")
    func fallsThrough() {
        let decision = decideCheckout(
            local: [], remotes: [remote("origin", "feature"), remote("upstream", "feature")], allLocalBranches: ["main", "feature"])
        #expect(decision == CheckoutDecision.none)
    }

    @Test("is none when the commit has no local or remote-tracking branch at all") func noneAtAll() {
        #expect(decideCheckout(local: [], remotes: [], allLocalBranches: ["main"]) == CheckoutDecision.none)
    }
}

@Suite("checkoutTargetLabel") struct CheckoutTargetLabelTests {
    @Test("labels a branch by its own name") func branch() {
        #expect(checkoutTargetLabel(.branch(name: "main")) == "main")
    }

    @Test("labels a remote branch by its full ref, so it reads distinctly from a same-named local branch") func remote() {
        #expect(checkoutTargetLabel(.remoteBranch(RemoteRefInfo(remote: "origin", name: "x", ref: "origin/x"))) == "origin/x")
    }

    @Test("labels a bare commit target by its hash") func commitTarget() {
        #expect(checkoutTargetLabel(.commit(hash: "abc123")) == "abc123")
    }
}

// MARK: - The detail split (V-2, V-4)

@Suite("readDetailSplit") struct ReadDetailSplitTests {
    @Test("gives an untouched pane the fixed 60/40 it always had, open") func untouched() {
        #expect(readDetailSplit([:]) == DetailSplit(fraction: 0.4, collapsed: false))
        #expect(DetailSplitRules.defaultFraction == 0.4)
    }

    @Test("reads a saved fraction and collapsed state") func saved() {
        #expect(readDetailSplit(["detailFraction": 0.25, "detailCollapsed": true]) == DetailSplit(fraction: 0.25, collapsed: true))
    }

    @Test(
        "falls back to the default for a fraction that is invalid",
        arguments: [
            JSONValue.double(.nan), .int(0), .int(1), .double(-0.3), .double(1.5), .double(.infinity), .string("0.3"), .null,
        ])
    func fallsBack(_ fraction: JSONValue) {
        #expect(readDetailSplit(.object(["detailFraction": fraction])).fraction == DetailSplitRules.defaultFraction)
    }

    @Test("treats anything but a literal true as open") func literalTrue() {
        #expect(!readDetailSplit(["detailCollapsed": "true"]).collapsed)
        #expect(!readDetailSplit(["detailCollapsed": 1]).collapsed)
    }
}

@Suite("resolveDetailDrag") struct ResolveDetailDragTests {
    let open = DetailSplit(fraction: 0.4, collapsed: false)
    let minimum = DetailSplitRules.detailMinHeight

    @Test("gives the details what the drag asks for, as a share of the body") func share() {
        #expect(resolveDetailDrag(detailHeight: 250, bodyHeight: 1000, previous: open) == DetailSplit(fraction: 0.25, collapsed: false))
    }

    @Test("collapses below half the minimum, remembering the last open size") func collapses() {
        #expect(
            resolveDetailDrag(detailHeight: minimum / 2 - 1, bodyHeight: 1000, previous: open)
                == DetailSplit(fraction: 0.4, collapsed: true))
        #expect(resolveDetailDrag(detailHeight: -50, bodyHeight: 1000, previous: open).collapsed)
    }

    @Test("holds at the minimum between half of it and all of it") func holds() {
        #expect(
            resolveDetailDrag(detailHeight: minimum / 2, bodyHeight: 1000, previous: open)
                == DetailSplit(fraction: minimum / 1000, collapsed: false))
        #expect(resolveDetailDrag(detailHeight: minimum - 1, bodyHeight: 1000, previous: open).fraction == minimum / 1000)
    }

    @Test("reopens a collapsed panel once dragged back past half the minimum") func reopens() {
        let collapsed = DetailSplit(fraction: 0.4, collapsed: true)
        #expect(resolveDetailDrag(detailHeight: 300, bodyHeight: 1000, previous: collapsed) == DetailSplit(fraction: 0.3, collapsed: false))
    }

    @Test("never squeezes the commit list below its minimum") func listMinimum() {
        #expect(
            resolveDetailDrag(detailHeight: 990, bodyHeight: 1000, previous: open).fraction == (1000 - DetailSplitRules.listMinHeight)
                / 1000)
    }

    @Test("keeps the details at their minimum in a body too short for both, never a fraction a reload would refuse") func tooShort() {
        let split = resolveDetailDrag(detailHeight: 100, bodyHeight: 80, previous: open)
        #expect(!split.collapsed)
        #expect(split.fraction > 0 && split.fraction < 1)
        #expect(readDetailSplit(["detailFraction": .double(split.fraction)]).fraction == split.fraction)
    }

    @Test("changes nothing for a body with no height") func noHeight() {
        #expect(resolveDetailDrag(detailHeight: 10, bodyHeight: 0, previous: open) == open)
    }
}

// MARK: - Settings (ST-4), as core merges stored settings over the defaults

@Suite("Stored git tree settings over the defaults") struct GitTreeSettingsTests {
    /// What core does with a stored blob (`PluginSettings.decode`): merged over
    /// the encoded defaults, decoded, defaults when it can't be.
    private func merge(_ stored: JSONValue?) -> GitTreeSettings {
        guard let stored, let defaults = try? JSONValue(encoding: GitTreeSettings()) else { return GitTreeSettings() }
        return (try? stored.merged(over: defaults).decode(GitTreeSettings.self)) ?? GitTreeSettings()
    }

    @Test("returns the defaults for nothing persisted") func defaults() {
        let settings = merge(nil)
        #expect(settings == GitTreeSettings())
        #expect(!settings.autoRefreshOnFocus && !settings.showAuthorColumn && !settings.showDateColumn)
    }

    @Test("lets a persisted value override the default") func overrides() {
        var expected = GitTreeSettings()
        expected.autoRefreshOnFocus = true
        #expect(merge(["autoRefreshOnFocus": true]) == expected)
    }

    @Test("lets the column visibility settings override their defaults independently") func independent() {
        var author = GitTreeSettings()
        author.showAuthorColumn = true
        #expect(merge(["showAuthorColumn": true]) == author)
        var date = GitTreeSettings()
        date.showDateColumn = true
        #expect(merge(["showDateColumn": true]) == date)
    }

    @Test("never throws, whatever shape the persisted value is") func total() {
        let hostile: [JSONValue] = [
            .null, 0, "x", [], [1, 2], true, ["autoRefreshOnFocus": "nope"], ["showAuthorColumn": "nope"], ["showDateColumn": "nope"],
        ]
        for stored in hostile { _ = merge(stored) }
        // A wrongly typed field costs only itself.
        var expected = GitTreeSettings()
        expected.showDateColumn = true
        #expect(merge(["autoRefreshOnFocus": "nope", "showDateColumn": true]) == expected)
    }
}

// MARK: - Formatting and the git parsers

@Suite struct FormatTests {
    @Test func shortHashIsTheFirstSevenCharacters() {
        #expect(shortHash("0123456789abcdef") == "0123456")
        #expect(shortHash("") == "")
    }

    /// H-8: `YYYY-MM-DD HH:MM`, local time; anything else passes through.
    @Test func formatDateReadsAsSortableLocalTime() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(formatDate("2026-08-05T14:32:09+00:00", timeZone: utc) == "2026-08-05 14:32")
        #expect(formatDate("2026-01-02T03:04:05Z", timeZone: utc) == "2026-01-02 03:04")
        #expect(formatDate("2026-01-02T03:04:05+02:00", timeZone: utc) == "2026-01-02 01:04")
        #expect(formatDate("", timeZone: utc) == "")
        #expect(formatDate("not a date", timeZone: utc) == "not a date")
    }

    @Test func baseNameIsTheTrailingSegment() {
        #expect(baseName("/home/ann/projects/tabs") == "tabs")
        #expect(baseName("/home/ann/projects/tabs/") == "tabs")
        #expect(baseName("/") == "/")
    }
}

@Suite struct GitParserTests {
    /// H-2
    @Test func parseRefsSplitsHeadArrow() {
        #expect(Git.parseRefs("HEAD -> main, origin/main, tag: v1") == ["HEAD", "main", "origin/main", "tag: v1"])
        #expect(Git.parseRefs("") == [])
        #expect(Git.parseRefs("HEAD") == ["HEAD"])
    }

    @Test func parseLogLineReadsEveryField() throws {
        let line = ["abc", "p1 p2", "Ann", "2026-01-02T03:04:05Z", "HEAD -> main", "the subject"].joined(separator: "\u{1f}")
        let parsed = try #require(Git.parseLogLine(line))
        #expect(
            parsed
                == Commit(
                    hash: "abc", parents: ["p1", "p2"], author: "Ann", date: "2026-01-02T03:04:05Z", refs: ["HEAD", "main"],
                    subject: "the subject"))
        let root = try #require(Git.parseLogLine(["r", "", "Ann", "d", "", "root"].joined(separator: "\u{1f}")))
        #expect(root.parents == [])
        #expect(Git.parseLogLine("too\u{1f}few") == nil)
    }

    @Test func parseNumstatReadsBinaryAndTabs() {
        let parsed = Git.parseNumstat("3\t1\ta.txt\n-\t-\timg.png\n2\t0\twith\ttab.txt\n")
        #expect(
            parsed.files == [
                ChangedFile(path: "a.txt", insertions: 3, deletions: 1), ChangedFile(path: "img.png", insertions: nil, deletions: nil),
                ChangedFile(path: "with\ttab.txt", insertions: 2, deletions: 0),
            ])
        #expect(!parsed.truncated)
        let nul = Git.parseNumstat("1\t2\tx\u{0}3\t4\ty\u{0}", separator: "\u{0}")
        #expect(nul.files.map(\.path) == ["x", "y"])
    }

    /// P-5
    @Test func parseNumstatCutsAtTheFileCap() {
        let many = (0..<(Git.fileCap + 3)).map { "1\t1\tf\($0)" }.joined(separator: "\n")
        let parsed = Git.parseNumstat(many)
        #expect(parsed.files.count == Git.fileCap)
        #expect(parsed.truncated)
        let exact = (0..<Git.fileCap).map { "1\t1\tf\($0)" }.joined(separator: "\n")
        #expect(!Git.parseNumstat(exact).truncated)
    }

    @Test func parseStatusPathsSkipsARenamesOriginal() {
        let status = " M a.txt\u{0}R  new.txt\u{0}old.txt\u{0}?? dir/untracked file.txt\u{0}"
        #expect(Git.parseStatusPaths(status) == ["a.txt", "new.txt", "dir/untracked file.txt"])
    }

    @Test func capLinesKeepsTheFirstLinesAndCountsTheRest() {
        #expect(Git.capLines("a\nb", 2) == "a\nb")
        #expect(Git.capLines("a\nb\nc", 2) == "a\nb\n… (1 more line)")
        #expect(Git.capLines("a\nb\nc\nd", 2) == "a\nb\n… (2 more lines)")
    }

    /// E-1, E-2, E-5
    @Test func classifyReadsGitsStablePhrases() {
        #expect(Git.classify(stderr: "fatal: not a git repository (or any…)", message: "", cwd: "/x") == .notARepo(path: "/x"))
        #expect(
            Git.classify(stderr: "fatal: your current branch 'main' does not have any commits yet", message: "", cwd: "/x")
                == .noCommits(root: "/x"))
        #expect(Git.classify(stderr: "fatal: bad default revision 'HEAD'", message: "", cwd: "/x") == .noCommits(root: "/x"))
        #expect(Git.classify(stderr: "\n  error: something odd\nmore", message: "", cwd: "/x") == .failed(message: "error: something odd"))
        #expect(Git.classify(stderr: "", message: "Command failed: git log", cwd: "/x") == .failed(message: "Command failed: git log"))
    }

    /// C-11
    @Test func checkoutArgsUseSwitch() {
        #expect(Git.checkoutArgs(.branch(name: "main")) == ["switch", "main"])
        #expect(
            Git.checkoutArgs(.remoteBranch(RemoteRefInfo(remote: "origin", name: "x", ref: "origin/x"))) == [
                "switch", "-c", "x", "--track", "origin/x",
            ])
        #expect(Git.checkoutArgs(.commit(hash: "abc")) == ["switch", "--detach", "abc"])
    }

    @Test func scopeArgsNeverIncludeTags() {
        #expect(Git.scopeArgs(.current) == ["HEAD"])
        #expect(Git.scopeArgs(.local) == ["--branches"])
        #expect(Git.scopeArgs(.all) == ["--branches", "--remotes"])
    }
}
