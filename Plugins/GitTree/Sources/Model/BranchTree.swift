import Foundation
import TabsPluginSDK

// The branches sidebar's tree: pure, so its shape is testable without views.
// Top level, the sources (Local, each remote, Tags); under each, its refs'
// names split at `/`, every segment but the last a folder, the way Finder
// shows a path: `my/branch/name` on origin is origin ▸ my ▸ branch ▸ name.

/// A top-level row of the sidebar: where the refs under it live.
enum BranchSource: Equatable, Sendable {
    case local
    case remote(String)
    case tags

    /// Its row's identity: distinct from every folder's and ref's.
    var id: String {
        switch self {
        case .local: "local"
        case .remote(let name): "remote:\(name)"
        case .tags: "tags"
        }
    }

    var title: String {
        switch self {
        case .local: "Local"
        case .remote(let name): name
        case .tags: "Tags"
        }
    }
}

/// One row of the sidebar and the rows under it.
struct BranchNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case source(BranchSource)
        /// A segment of one or more refs' names (`my` in `my/branch`).
        case folder
        case ref(GitRef)
    }

    /// Unique in the tree, and stable across re-reads (what expansion and
    /// selection are kept by): a source's `id`, a folder's
    /// `<source id>:<path>/`, a ref's full name.
    var id: String
    var title: String
    var kind: Kind
    var children: [BranchNode] = []

    var ref: GitRef? {
        if case .ref(let ref) = kind { ref } else { nil }
    }

    var isSource: Bool {
        if case .source = kind { true } else { false }
    }

    /// The first node with `id` in this subtree, this one included.
    func find(_ id: String) -> BranchNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }
}

/// The sidebar's top level: Local, then each remote (the configured ones in
/// `git remote`'s order, then any a ref names that isn't configured), then
/// Tags. Every source is listed, empty or not.
func buildBranchTree(_ refs: GitRefs) -> [BranchNode] {
    var remotes = refs.remotes
    for ref in refs.refs where ref.kind == .remote {
        if let remote = ref.remote, !remotes.contains(remote) { remotes.append(remote) }
    }
    let sources: [BranchSource] = [.local] + remotes.map(BranchSource.remote) + [.tags]
    return sources.map { source in
        let members = refs.refs.filter { ref in
            switch source {
            case .local: ref.kind == .local
            case .remote(let name): ref.kind == .remote && ref.remote == name
            case .tags: ref.kind == .tag
            }
        }
        let entries = members.map { (path: $0.name.split(separator: "/")[...], ref: $0) }
        return BranchNode(
            id: source.id, title: source.title, kind: .source(source), children: branchNodes(entries, prefix: "", source: source.id))
    }
}

/// One level of a source's refs, each entry's name still to place.
private func branchNodes(_ entries: [(path: ArraySlice<Substring>, ref: GitRef)], prefix: String, source: String) -> [BranchNode] {
    var nodes: [BranchNode] = []
    var folders: [String: [(path: ArraySlice<Substring>, ref: GitRef)]] = [:]
    for entry in entries {
        guard let first = entry.path.first else { continue }
        if entry.path.count == 1 {
            nodes.append(BranchNode(id: entry.ref.refname, title: String(first), kind: .ref(entry.ref)))
        } else {
            folders[String(first), default: []].append((entry.path.dropFirst(), entry.ref))
        }
    }
    for (name, members) in folders {
        let path = prefix + name + "/"
        nodes.append(
            BranchNode(id: "\(source):\(path)", title: name, kind: .folder, children: branchNodes(members, prefix: path, source: source)))
    }
    return nodes.sorted(by: branchOrder)
}

/// Finder's order: by name, numbers by value (`v2` before `v10`), case
/// ignored, folders among the refs; the id settles a tie.
func branchOrder(_ a: BranchNode, _ b: BranchNode) -> Bool {
    switch a.title.localizedStandardCompare(b.title) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.id < b.id
    }
}

/// Which rows are open: every source until closed, a folder once opened.
/// Saved in the pane's config (`branchesCollapsedSources`,
/// `branchesExpandedFolders`), so a relaunch opens the tree as it was left.
struct BranchExpansion: Equatable, Sendable {
    var collapsedSources: Set<String> = []
    var expandedFolders: Set<String> = []

    func isExpanded(_ node: BranchNode) -> Bool {
        switch node.kind {
        case .source: !collapsedSources.contains(node.id)
        case .folder: expandedFolders.contains(node.id)
        case .ref: false
        }
    }

    mutating func set(_ node: BranchNode, expanded: Bool) {
        switch node.kind {
        case .source:
            if expanded { collapsedSources.remove(node.id) } else { collapsedSources.insert(node.id) }
        case .folder:
            if expanded { expandedFolders.insert(node.id) } else { expandedFolders.remove(node.id) }
        case .ref: break
        }
    }

    /// Without the rows `tree` no longer has (a deleted branch's folder).
    func pruned(to tree: [BranchNode]) -> BranchExpansion {
        var ids: Set<String> = []
        func collect(_ nodes: [BranchNode]) {
            for node in nodes {
                ids.insert(node.id)
                collect(node.children)
            }
        }
        collect(tree)
        return BranchExpansion(collapsedSources: collapsedSources.intersection(ids), expandedFolders: expandedFolders.intersection(ids))
    }

    /// The config's keys for it: absent while it's the default.
    var config: [String: JSONValue] {
        [
            "branchesCollapsedSources": collapsedSources.isEmpty ? .null : .array(collapsedSources.sorted().map(JSONValue.string)),
            "branchesExpandedFolders": expandedFolders.isEmpty ? .null : .array(expandedFolders.sorted().map(JSONValue.string)),
        ]
    }
}

/// The expansion a pane's config asks for: each key an array of strings
/// (anything else in it ignored), else empty.
func readBranchExpansion(_ config: JSONValue) -> BranchExpansion {
    func ids(_ key: String) -> Set<String> {
        guard case .array(let values)? = config[key] else { return [] }
        return Set(values.compactMap(\.stringValue))
    }
    return BranchExpansion(collapsedSources: ids("branchesCollapsedSources"), expandedFolders: ids("branchesExpandedFolders"))
}

/// The rows as the sidebar lists them: depth first, each with its depth,
/// only under open rows.
func visibleBranchRows(_ tree: [BranchNode], _ expansion: BranchExpansion) -> [(node: BranchNode, level: Int)] {
    var rows: [(node: BranchNode, level: Int)] = []
    func walk(_ nodes: [BranchNode], _ level: Int) {
        for node in nodes {
            rows.append((node, level))
            if expansion.isExpanded(node) { walk(node.children, level + 1) }
        }
    }
    walk(tree, 0)
    return rows
}
