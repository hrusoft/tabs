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

/// P-19
@Suite struct CommitDetailLineTotalsTests {
    private func detail(_ files: [ChangedFile]) -> CommitDetail {
        CommitDetail(
            hash: "abc", parents: [], author: "", authorEmail: "", date: "", refs: [], message: "m", files: files, filesTruncated: false)
    }

    @Test func theTotalsSumTheFilesCountsAndLeaveBinariesOut() throws {
        let totals = try #require(
            detail([
                ChangedFile(path: "a", insertions: 12, deletions: 3), ChangedFile(path: "logo.png", insertions: nil, deletions: nil),
                ChangedFile(path: "b", insertions: 8, deletions: 1),
                ChangedFile(path: "new", insertions: 5, deletions: 0, readFromDisk: true),
            ]).lineTotals)
        #expect(totals.insertions == 25 && totals.deletions == 4)
    }

    @Test func thereAreNoTotalsWithoutCounts() {
        #expect(detail([]).lineTotals == nil)
        #expect(detail([ChangedFile(path: "logo.png", insertions: nil, deletions: nil)]).lineTotals == nil)
        let zero = detail([ChangedFile(path: "mode", insertions: 0, deletions: 0)]).lineTotals
        #expect(zero?.insertions == 0 && zero?.deletions == 0, "zero counted lines are still counts")
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

    /// P-18
    @Test func parseNumstatReadsANulRenamesTwoPaths() {
        let parsed = Git.parseNumstat("1\t0\t\u{0}src/old/a.txt\u{0}src/new/a.txt\u{0}2\t2\tb.txt\u{0}", separator: "\u{0}")
        #expect(
            parsed.files == [
                ChangedFile(path: "src/new/a.txt", insertions: 1, deletions: 0, oldPath: "src/old/a.txt"),
                ChangedFile(path: "b.txt", insertions: 2, deletions: 2),
            ])
        #expect(parsed.files[0].displayPath == "src/{old => new}/a.txt")
    }

    /// P-18: git's `pprint_rename`.
    @Test func renameLabelKeepsWhatBothPathsShareOutsideBraces() {
        #expect(renameLabel("src/old/a.txt", "src/new/a.txt") == "src/{old => new}/a.txt")
        #expect(renameLabel("dir/a.txt", "dir/b.txt") == "dir/{a.txt => b.txt}")
        #expect(renameLabel("a/file.txt", "b/file.txt") == "{a => b}/file.txt")
        #expect(renameLabel("a.txt", "b.txt") == "a.txt => b.txt")
        #expect(renameLabel("x/a.txt", "x/y/a.txt") == "x/{ => y}/a.txt")
        #expect(renameLabel("é/a.txt", "é/b.txt") == "é/{a.txt => b.txt}")
    }

    @Test func aChangedFileDecodesWithoutTheFieldsAScenarioLeavesOut() throws {
        let file = try JSONValue.object(["path": "a.txt", "insertions": 1, "deletions": 2]).decode(ChangedFile.self)
        #expect(file == ChangedFile(path: "a.txt", insertions: 1, deletions: 2))
        #expect(!file.readFromDisk)
        #expect(file.oldPath == nil)
    }
}

// MARK: - One file's diff (P-12 … P-16)

private let patch = """
    diff --git a/a.swift b/a.swift
    index 1111111..2222222 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -3,4 +3,5 @@ func run() {
     three
    -four
    +FOUR
    +four and a half
     five
     six
    @@ -20,2 +21,2 @@ func stop() {
     twenty
    -twenty-one
    \\ No newline at end of file
    +21
    \\ No newline at end of file

    """

@Suite struct ParsePatchTests {
    /// P-12
    @Test func numbersEveryLineFromItsHunksHeader() throws {
        let diff = Git.parsePatch(patch)
        #expect(!diff.binary)
        #expect(!diff.truncated)
        #expect(diff.hunks.count == 2)
        let first = try #require(diff.hunks.first)
        #expect([first.oldStart, first.oldCount, first.newStart, first.newCount] as [Int] == [3, 4, 3, 5])
        #expect(
            first.lines == [
                FileDiff.Line(kind: .context, text: "three", old: 3, new: 3),
                FileDiff.Line(kind: .removed, text: "four", old: 4),
                FileDiff.Line(kind: .added, text: "FOUR", new: 4),
                FileDiff.Line(kind: .added, text: "four and a half", new: 5),
                FileDiff.Line(kind: .context, text: "five", old: 5, new: 6),
                FileDiff.Line(kind: .context, text: "six", old: 6, new: 7),
            ])
        #expect(
            diff.hunks[1].lines.map(\.kind) == [.context, .removed, .note, .added, .note],
            "the note follows the line it's about, unnumbered")
        #expect(diff.hunks[1].lines[2] == FileDiff.Line(kind: .note, text: "\\ No newline at end of file"))
    }

    @Test func aHeaderCountLeftOutIsOne() throws {
        let header = try #require(Git.parseHunkHeader("@@ -7 +7,0 @@"))
        #expect(header.oldStart == 7 && header.oldCount == 1 && header.newStart == 7 && header.newCount == 0)
        #expect(Git.parseHunkHeader("@@ nonsense @@") == nil)
    }

    /// P-13
    @Test func binaryFilesHaveNoHunks() {
        let diff = Git.parsePatch("diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n")
        #expect(diff.binary)
        #expect(diff.hunks.isEmpty)
    }

    /// P-13: a mode change has only headers.
    @Test func aModeChangeHasNoHunksAndIsntBinary() {
        let diff = Git.parsePatch("diff --git a/x b/x\nold mode 100644\nnew mode 100755\n")
        #expect(!diff.binary)
        #expect(diff.hunks.isEmpty)
    }

    @Test func aCarriageReturnBeforeTheNewlineIsntShown() {
        let diff = Git.parsePatch("@@ -1 +1 @@\n-a\r\n+b\r\n")
        #expect(diff.hunks[0].lines.map(\.text) == ["a", "b"])
    }

    @Test func aLaterFileHeaderEndsTheHunk() {
        let diff = Git.parsePatch("@@ -1 +1 @@\n-a\n+b\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n")
        #expect(diff.hunks[0].lines.map(\.text) == ["a", "b"], "the next file's `---`/`+++` aren't lines")
    }

    /// P-14
    @Test func cutsAtTheLineCapAndLongLinesAtTheLengthCap() {
        let many = "@@ -1,\(Git.diffLineCap + 5) +1,\(Git.diffLineCap + 5) @@\n" + String(repeating: " x\n", count: Git.diffLineCap + 5)
        let diff = Git.parsePatch(many)
        #expect(diff.hunks[0].lines.count == Git.diffLineCap)
        #expect(diff.truncated)
        let exact = "@@ -1,\(Git.diffLineCap) +1,\(Git.diffLineCap) @@\n" + String(repeating: " x\n", count: Git.diffLineCap)
        #expect(!Git.parsePatch(exact).truncated)
        let long = Git.parsePatch("@@ -1 +1 @@\n+" + String(repeating: "y", count: Git.diffLineLength + 50) + "\n")
        #expect(long.hunks[0].lines[0].text == String(repeating: "y", count: Git.diffLineLength) + "…")
    }

    @Test func fileLinesCountAsGitDoes() {
        #expect(Git.fileLines("a\nb\n") == ["a", "b"])
        #expect(Git.fileLines("a\nb") == ["a", "b"])
        #expect(Git.fileLines("a\r\n\nb") == ["a", "", "b"])
        #expect(Git.fileLines("") == [])
    }
}

/// A diff of a 30-line file, lines 15 and 16 changed to one: hunks of 5
/// lines' context, the old file's lines as given.
private func thirtyLineDiff(base: [String]? = (1...30).map { "line \($0)" }) -> FileDiff {
    var diff = Git.parsePatch(
        "@@ -10,12 +10,11 @@\n" + (10...14).map { " line \($0)\n" }.joined() + "-line 15\n-line 16\n+line 15-16\n"
            + (17...21).map { " line \($0)\n" }.joined())
    diff.base = base
    return diff
}

/// P-15, P-16
@Suite struct DiffGapTests {
    @Test func theRunsBeforeAndAfterTheHunksAreHiddenRows() {
        let diff = thirtyLineDiff()
        #expect(
            diff.gaps == [
                FileDiff.Gap(index: 0, oldFirst: 1, count: 9, newOffset: 0), FileDiff.Gap(index: 1, oldFirst: 22, count: 9, newOffset: -1),
            ])
        let rows = diff.rows(revealed: [])
        #expect(rows.first == .hidden(gap: 0, count: 9, revealable: true))
        #expect(rows.last == .hidden(gap: 1, count: 9, revealable: true))
        #expect(rows.count == 2 + 13)
        #expect(diff.revealableGaps == [0, 1])
    }

    @Test func aRevealedRunIsItsLinesNumberedOnBothSides() {
        let rows = thirtyLineDiff().rows(revealed: [1])
        guard case .line(let first) = rows[rows.count - 9], case .line(let last) = rows[rows.count - 1] else {
            Issue.record("the last run wasn't shown")
            return
        }
        #expect(first == FileDiff.Line(kind: .context, text: "line 22", old: 22, new: 21))
        #expect(last == FileDiff.Line(kind: .context, text: "line 30", old: 30, new: 29))
        #expect(rows.first == .hidden(gap: 0, count: 9, revealable: true), "the other run stays hidden")
    }

    @Test func everyRunOpenIsTheWholeFile() {
        let rows = thirtyLineDiff().rows(revealed: [0, 1])
        let lines = rows.compactMap { row -> FileDiff.Line? in if case .line(let line) = row { line } else { nil } }
        #expect(lines.count == rows.count, "nothing hidden")
        #expect(lines.compactMap(\.old) == Array(1...30))
        #expect(lines.compactMap(\.new) == Array(1...29))
    }

    @Test func withoutTheOldFileTheRunsBetweenHunksShowButCantOpenAndTheLastIsUnknown() {
        let diff = thirtyLineDiff(base: nil)
        #expect(diff.rows(revealed: [0]).first == .hidden(gap: 0, count: 9, revealable: false))
        #expect(diff.gaps.count == 1, "the run after the last hunk needs the old file's length")
        #expect(diff.revealableGaps.isEmpty)
    }

    @Test func aCutDiffHasNoRunAfterItsLastHunk() {
        var diff = thirtyLineDiff()
        diff.truncated = true
        #expect(diff.gaps.map(\.index) == [0])
    }

    @Test func aRunBetweenTwoHunksIsNumberedByTheFirstHunksEnd() {
        var diff = Git.parsePatch("@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10,2 +11,1 @@\n j\n-k\n")
        diff.base = ["a", "c", "3", "4", "5", "6", "7", "8", "9", "j", "k"]
        #expect(diff.gaps.first == FileDiff.Gap(index: 1, oldFirst: 3, count: 7, newOffset: 1))
        guard case .line(let line) = diff.rows(revealed: [1])[3] else {
            Issue.record("the run between the hunks wasn't shown")
            return
        }
        #expect(line == FileDiff.Line(kind: .context, text: "3", old: 3, new: 4))
        #expect(diff.largestLineNumber == 11)
    }

    @Test func anOldFileShorterThanTheHeadersSayCantOpenTheRun() {
        let diff = thirtyLineDiff(base: ["only", "three", "lines"])
        #expect(diff.rows(revealed: [0]).first == .hidden(gap: 0, count: 9, revealable: false))
        #expect(diff.revealableGaps.isEmpty)
    }

    @Test func anAddedFileHidesNothing() {
        var diff = Git.parsePatch("@@ -0,0 +1,2 @@\n+a\n+b\n")
        diff.base = nil
        #expect(diff.gaps.isEmpty)
        #expect(diff.rows(revealed: []).count == 2)
    }
}

@Suite struct DiffTextTests {
    @Test func tabsStopEveryFourColumns() {
        #expect(CommitDetailLayout.expandTabs("\tx") == "    x")
        #expect(CommitDetailLayout.expandTabs("ab\tx") == "ab  x")
        #expect(CommitDetailLayout.expandTabs("none") == "none")
    }

    @Test func codeWrapsAfterASpaceButNeverInsideTheIndentation() {
        let width = 10 * GitTreeMetrics.monoAdvance
        #expect(CommitDetailLayout.wrapCode("short", width: width) == ["short"])
        #expect(CommitDetailLayout.wrapCode("let a = b + c", width: width) == ["let a = b ", "+ c"])
        #expect(CommitDetailLayout.wrapCode("let totals = b", width: width) == ["let ", "totals = b"])
        #expect(CommitDetailLayout.wrapCode("        indented", width: width) == ["        in", "dented"])
        #expect(CommitDetailLayout.wrapCode("abcdefghijklmnopqrstuvwxy", width: width) == ["abcdefghij", "klmnopqrst", "uvwxy"])
    }

    @Test func plainASCIIIsCountedAtMenlosAdvance() {
        #expect(abs(CommitDetailLayout.codeWidth("abcdef") - GitText.mono11.width("abcdef")) < 0.01)
    }
}
