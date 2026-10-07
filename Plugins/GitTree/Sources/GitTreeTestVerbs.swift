#if DEBUG
import AppKit
import TabsPluginSDK

/// Debug-only verbs for the visual capture and the end-to-end tests: scripted
/// history, a pane's state, and where everything is drawn. Not in Release
/// builds.
///
/// The visual capture's hooks (Visual/README.md): `git-tree.test.stage` answers
/// a pane from a scenario's `content` entry, `git-tree.test.visual` measures it.
@MainActor
enum GitTreeTestVerbs {
    static func register(in context: any PluginContext, services: GitTreeServices) {
        context.register(
            ControlVerbContribution(
                name: "git-tree.test.stage",
                summary:
                    "Debug: answer a pane's git reads from a script (a Visual scenario's content entry), then settle it: read, the scripted selection made, its details read",
                arguments: [ControlArgument("spec", .object, required: true)],
                target: .pane(ofTypes: ["git-tree"])
            ) { [weak services] invocation in
                guard let services, let pane = invocation.pane(as: GitTreePane.self), let spec = invocation["spec"] else {
                    throw ControlVerbError("not a git tree pane")
                }
                let source = try ScriptedGitSource(fixture: spec)
                // Panes made later read it too.
                services.sourceOverride = source
                pane.useSource(source)
                try await pane.settle()
                if let hash = spec["select"]?.stringValue {
                    pane.select(hash)
                    try await pane.settle()
                }
                return .null
            })

        context.register(
            ControlVerbContribution(
                name: "git-tree.test.state",
                summary: "Debug: a git tree pane's directory, scope, rows, selection, details, split and notices",
                target: .pane(ofTypes: ["git-tree"])
            ) { invocation in
                guard let pane = invocation.pane(as: GitTreePane.self) else { throw ControlVerbError("not a git tree pane") }
                return pane.testState
            })

        context.register(
            ControlVerbContribution(
                name: "git-tree.test.visual",
                summary:
                    "Debug: a pane's block of the visual comparison's geometry (Visual/README.md): where it draws its parts, the toolbar's in the header title view's coordinates, the rest in its view's",
                target: .pane(ofTypes: ["git-tree"])
            ) { invocation in
                guard let pane = invocation.pane(as: GitTreePane.self), let view = pane.viewIfLoaded else {
                    throw ControlVerbError("not a shown git tree pane")
                }
                view.layoutSubtreeIfNeeded()
                return ["title": view.toolbarGeometry(), "body": view.geometry()]
            })
    }
}

extension ScriptedGitSource {
    /// A Visual scenario's content entry for a git tree: `log` or `failure`,
    /// optional `details`, `workingTree` and `head`.
    convenience init(fixture: JSONValue) throws {
        self.init()
        if let log = fixture["log"] {
            let commits = try (log["commits"] ?? .array([])).decode([Commit].self)
            setLog(
                commits, root: log["root"]?.stringValue, hasMore: log["hasMore"]?.boolValue ?? false,
                hasUncommittedChanges: log["hasUncommittedChanges"]?.boolValue ?? false)
        }
        if let failure = fixture["failure"] { self.failure = try GitFailure(json: failure) }
        if case .object(let details)? = fixture["details"] {
            for (hash, detail) in details { self.details[hash] = try detail.decode(CommitDetail.self) }
        }
        if let workingTree = fixture["workingTree"] { workingTreeDetail = try workingTree.decode(CommitDetail.self) }
        if let head = fixture["head"] {
            switch head["kind"]?.stringValue {
            case "detached": self.head = .detached(hash: head["hash"]?.stringValue ?? "")
            default: self.head = .branch(name: head["name"]?.stringValue ?? "main")
            }
        }
    }
}

extension GitFailure {
    init(json: JSONValue) throws {
        switch json["kind"]?.stringValue {
        case "git-missing": self = .gitMissing
        case "no-such-directory": self = .noSuchDirectory(path: json["path"]?.stringValue ?? "")
        case "not-a-repo": self = .notARepo(path: json["path"]?.stringValue ?? "")
        case "no-commits": self = .noCommits(root: json["root"]?.stringValue ?? "")
        case "failed": self = .failed(message: json["message"]?.stringValue ?? "")
        default: throw ControlVerbError("unknown failure kind")
        }
    }
}

extension GitTreePane {
    var testState: JSONValue {
        var state: [String: JSONValue] = [
            "cwd": configuredDir.map(JSONValue.string) ?? .null,
            "branchScope": .string(branchScope.rawValue),
            "rows": .array(commits.map { .string($0.hash) }),
            "subjects": .array(commits.map { .string($0.subject) }),
            "selected": selectedHash.map(JSONValue.string) ?? .null,
            "detailHash": detail.map { .string($0.hash) } ?? .null,
            "detailFiles": .array((detail?.files ?? []).map { .string($0.path) }),
            "collapsed": .bool(split.collapsed),
            "fraction": .double(split.fraction),
            "loading": .bool(log == nil),
        ]
        if case .failure(let error)? = log { state["notice"] = .string(failureMessage(error.reason)) }
        if case .success(let value)? = log {
            state["hasMore"] = .bool(value.hasMore)
            switch value.head {
            case .branch(let name): state["head"] = .string(name)
            case .detached(let hash): state["head"] = .string("detached at \(shortHash(hash))")
            }
        }
        if let view = viewIfLoaded {
            state["listFocused"] = .bool(view.window?.firstResponder === view.list)
            state["pathText"] = .string(view.toolbar.pathValue)
            state["editingPath"] = .bool(view.toolbar.isEditingPath)
        }
        return .object(state)
    }

    /// Waits until the log is read and, unless collapsed, the selected row's
    /// details are (the read is debounced).
    func settle() async throws {
        for _ in 0..<200 {
            let detailDone = split.collapsed || selectedHash == nil || detail?.hash == selectedHash
            if log != nil && !fetchPending && detailDone { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControlVerbError("the git tree didn't settle")
    }
}

extension GitTreeView {
    /// The toolbar's part of this pane's geometry block (docs/GIT-TREE.md,
    /// Visual), in the header title view's coordinates (the capture adds its
    /// origin): the toolbar is the header's title.
    func toolbarGeometry() -> JSONValue {
        func r(_ rect: CGRect?) -> JSONValue {
            guard let rect else { return .null }
            func round2(_ x: Double) -> JSONValue { .double((x * 100).rounded() / 100) }
            return .array([round2(rect.minX), round2(rect.minY), round2(rect.width), round2(rect.height)])
        }
        func n(_ x: Double?) -> JSONValue { x.map { .double(($0 * 100).rounded() / 100) } ?? .null }
        let toolbarLayout = toolbar.computeLayout(width: toolbar.bounds.width)
        var out: [String: JSONValue] = [:]
        out["pathInput"] = r(toolbarLayout.path)
        out["browse"] = r(toolbarLayout.browse)
        out["pathBaseline"] = n(GitTreeToolbar.pathTextOrigin(in: toolbarLayout.path).y)
        if let head = toolbarLayout.head, let text = toolbarLayout.headText {
            let font = GitText.ui11
            // The text's own box, clipped to the label's (padding included).
            out["head"] = r(head)
            out["headText"] = r(
                CGRect(x: head.minX + 4, y: head.minY, width: min(font.width(text), head.width - 4), height: font.lineHeight))
            out["headBaseline"] = n(head.minY + font.ascent)
        } else {
            out["head"] = .null
            out["headText"] = .null
            out["headBaseline"] = .null
        }
        out["select"] = r(toolbarLayout.select)
        out["selectBaseline"] = n(
            toolbarLayout.select.minY + (toolbarLayout.select.height - GitText.ui11.lineHeight) / 2 + GitText.ui11.ascent)
        return .object(out)
    }

    /// The rest of this pane's geometry block, in this view's coordinates (the
    /// capture adds the pane body's origin).
    func geometry() -> JSONValue {
        func r(_ rect: CGRect?) -> JSONValue {
            guard let rect else { return .null }
            func round2(_ x: Double) -> JSONValue { .double((x * 100).rounded() / 100) }
            return .array([round2(rect.minX), round2(rect.minY), round2(rect.width), round2(rect.height)])
        }
        func n(_ x: Double?) -> JSONValue { x.map { .double(($0 * 100).rounded() / 100) } ?? .null }
        let layout = computeLayout()
        var out: [String: JSONValue] = [:]
        out["container"] = r(bounds)
        switch state {
        case .loading: out["state"] = "loading"
        case .list: out["state"] = "list"
        case .notice: out["state"] = "notice"
        }
        if state == .list {
            out["notice"] = .null
            out["noticeLines"] = .array([])
        } else {
            let origin = layout.content.origin
            out["notice"] = r(layout.content)
            let paragraphs = notice.lines(width: layout.content.width)
            out["noticeLines"] = .array(
                state == .loading
                    ? []
                    : paragraphs.map { lines in
                        let first = lines.first
                        let box = lines.reduce(CGRect.null) { $0.union($1.box) }
                        return .object([
                            "text": r(box.offsetBy(dx: origin.x, dy: origin.y)), "baseline": n((first?.baseline ?? 0) + origin.y),
                        ])
                    })
        }
        guard state == .list, let listRect = layout.list else {
            for key in ["list", "loadMore", "divider", "detail", "message"] { out[key] = .null }
            out["rows"] = .object([:])
            out["dividerCollapsed"] = .bool(false)
            out["fields"] = .array([])
            out["files"] = .array([])
            out["detailNotes"] = .array([])
            return .object(out)
        }
        out["list"] = r(listRect)
        var rows: [String: JSONValue] = [:]
        for index in 0..<list.rowCount {
            let row = pane.graph.rows[index]
            let rowRect = list.rowRect(index).offsetBy(dx: listRect.minX, dy: listRect.minY)
            let rowLayout = list.layout(ofRow: index)
            func inRow(_ rect: CGRect?) -> JSONValue { r(rect?.offsetBy(dx: rowRect.minX, dy: rowRect.minY)) }
            let phantom = row.commit.hash == uncommittedChangesHash
            let subjectFont = phantom ? GitText.italic12 : GitText.ui12
            var subjectText: CGRect?
            if !rowLayout.subjectText.isEmpty {
                // The whole text, clipped to the subject's box.
                let textWidth = subjectFont.width(
                    rowLayout.pills.count < row.commit.refs.count ? rowLayout.subjectText : row.commit.subject)
                let height = subjectFont.lineHeight
                let text = CGRect(
                    x: rowLayout.subjectTextX, y: rowLayout.subjectBaseline - subjectFont.ascent, width: textWidth, height: height)
                let clipped = text.intersection(rowLayout.subject)
                subjectText = clipped.isNull || clipped.width <= 0 ? nil : clipped
            }
            let small = GitText.ui11
            func smallText(_ box: CGRect?, _ text: String?) -> CGRect? {
                guard let box, let text, !text.isEmpty else { return nil }
                return CGRect(x: box.minX, y: box.minY, width: min(small.width(text), box.width), height: box.height)
            }
            rows[phantom ? "working-tree" : row.commit.hash] = .object([
                "rect": r(rowRect),
                "gutter": inRow(rowLayout.gutter),
                "hash": rowLayout.hashText.isEmpty ? .null : inRow(rowLayout.hash),
                "hashBaseline": rowLayout.hashText.isEmpty ? .null : n(rowRect.minY + rowLayout.hashBaseline),
                "subject": inRow(rowLayout.subject),
                "subjectText": inRow(subjectText),
                "subjectBaseline": n(rowRect.minY + rowLayout.subjectBaseline),
                "truncated": .bool(rowLayout.truncated),
                "refs": .array(rowLayout.pills.map { inRow($0.rect) }),
                "author": inRow(smallText(rowLayout.author, rowLayout.authorText)),
                "date": inRow(smallText(rowLayout.date, rowLayout.dateText)),
                "selected": .bool(row.commit.hash == pane.selectedHash),
                "phantom": .bool(phantom),
            ])
        }
        out["rows"] = .object(rows)
        out["loadMore"] = r(list.loadMoreRect?.offsetBy(dx: listRect.minX, dy: listRect.minY))
        out["divider"] = r(layout.divider)
        out["dividerCollapsed"] = .bool(layout.dividerCollapsed)
        guard let detailRect = layout.detail else {
            out["detail"] = .null
            out["message"] = .null
            out["fields"] = .array([])
            out["files"] = .array([])
            out["detailNotes"] = .array([])
            return .object(out)
        }
        out["detail"] = r(detailRect)
        let detailLayout = detail.layout(width: bounds.width)
        func inDetail(_ rect: CGRect?) -> JSONValue { r(rect?.offsetBy(dx: detailRect.minX, dy: detailRect.minY)) }
        out["message"] = inDetail(detailLayout.message)
        out["fields"] = .array(detailLayout.fields.map { .object(["dt": inDetail($0.dt), "dd": inDetail($0.dd)]) })
        out["files"] = .array(
            detailLayout.files.map { file in
                .object([
                    "row": inDetail(file.row), "stat": inDetail(file.stat), "insertions": inDetail(file.insertions),
                    "deletions": inDetail(file.deletions), "binary": inDetail(file.binary), "path": inDetail(file.path),
                ])
            })
        out["detailNotes"] = .array(detailLayout.notes.map { inDetail($0) })
        return .object(out)
    }
}
#endif
