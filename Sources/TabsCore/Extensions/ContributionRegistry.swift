import Foundation
import TabsPluginSDK

/// Core's declared extension points and every committed contribution, in
/// activation order. Only core declares points; plugins only contribute.
///
/// Plugins reach it only through a `ContributionTransaction` — one per plugin
/// activation. Each contribution is validated when it's made;
/// the transaction commits atomically only if the plugin's `activate` returned
/// and nothing it staged broke a rule. Otherwise none of it is ever visible: a
/// failed plugin leaves no half-registered state behind.
@MainActor
package final class ContributionRegistry {
    package struct Entry {
        package let owner: PluginID
        package let pointID: String
        package let contributionID: String
        package let value: Any
    }

    /// A point and the one contribution type it accepts.
    package struct Declaration {
        package let pointID: String
        package let contributionType: ObjectIdentifier
        package let typeName: String
    }

    /// Checks a contribution's id against the contributing plugin's manifest.
    /// Returns a problem, or nil.
    package typealias IDPolicy = (_ contributionID: String, _ manifest: PluginManifest) -> String?
    /// Runs over the whole transaction at commit.
    package typealias CommitCheck = (_ manifest: PluginManifest, _ staged: [Entry]) -> [String]

    private var entries: [String: [Entry]] = [:]
    private var declarations: [String: Declaration] = [:]
    private var idPolicies: [String: IDPolicy] = [:]
    private var validators: [String: [(Any, PluginID, [Entry]) -> String?]] = [:]
    private var commitChecks: [CommitCheck] = []
    /// Bumped on every commit, so observers can tell the contribution set changed.
    package private(set) var generation = 0

    package init() {}

    // MARK: Configuration (core only)

    /// Declares one of core's points, with an optional id policy (default: the
    /// contributing plugin's namespace).
    package func declareCorePoint<C: Contribution>(_ point: ExtensionPoint<C>, idPolicy: IDPolicy? = nil) {
        precondition(point.id.hasPrefix("tabs."), "core points live under tabs.")
        precondition(declarations[point.id] == nil, "\(point.id) declared twice")
        declarations[point.id] = Self.declaration(of: point)
        if let idPolicy { idPolicies[point.id] = idPolicy }
    }

    /// A point-specific rule. `others` is everything already on the point:
    /// committed contributions plus this transaction's earlier ones.
    package func addValidator<C>(
        for point: ExtensionPoint<C>,
        _ validate: @escaping (_ candidate: C, _ owner: PluginID, _ others: [Owned<C>]) -> String?
    ) {
        validators[point.id, default: []].append { candidate, owner, others in
            guard let candidate = candidate as? C else { return "internal: wrong contribution type" }
            return validate(candidate, owner, others.compactMap(Self.typed))
        }
    }

    package func addCommitCheck(_ check: @escaping CommitCheck) {
        commitChecks.append(check)
    }

    // MARK: Reading

    package func contributions<C>(to point: ExtensionPoint<C>) -> [Owned<C>] {
        (entries[point.id] ?? []).compactMap(Self.typed)
    }

    package func contribution<C>(to point: ExtensionPoint<C>, id: String) -> Owned<C>? {
        (entries[point.id] ?? []).first { $0.contributionID == id }.flatMap(Self.typed)
    }

    package func declaration(of pointID: String) -> Declaration? { declarations[pointID] }

    /// Per point, how many contributions `owner` made.
    package func counts(for owner: PluginID) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (point, list) in entries {
            let count = list.filter { $0.owner == owner }.count
            if count > 0 { counts[point] = count }
        }
        return counts
    }

    // MARK: Transactions

    package func begin(for manifest: PluginManifest) -> ContributionTransaction {
        ContributionTransaction(manifest: manifest)
    }

    package func stage<C: Contribution>(_ contribution: C, to point: ExtensionPoint<C>, in transaction: ContributionTransaction) {
        let owner = transaction.manifest.id
        let id = contribution.contributionID
        func reject(_ problem: String) { transaction.problems.append("\(point.id) \"\(id)\": \(problem)") }

        guard let declaration = declarations[point.id] else {
            return reject("no extension point \"\(point.id)\" is declared")
        }
        guard declaration.contributionType == ObjectIdentifier(C.self) else {
            return reject("the point is declared for \(declaration.typeName), not \(String(reflecting: C.self))")
        }
        let policy = idPolicies[point.id] ?? Self.namespacePolicy
        if let problem = policy(id, transaction.manifest) { return reject(problem) }

        let existing = (entries[point.id] ?? []) + transaction.staged.filter { $0.pointID == point.id }
        if let clash = existing.first(where: { $0.contributionID == id }) {
            return reject(clash.owner == owner ? "registered twice" : "already registered by \(clash.owner)")
        }
        for validate in validators[point.id] ?? [] {
            if let problem = validate(contribution, owner, existing) { return reject(problem) }
        }
        transaction.staged.append(Entry(owner: owner, pointID: point.id, contributionID: id, value: contribution))
    }

    /// Commits everything or nothing. Returns the problems that prevented it.
    package func commit(_ transaction: ContributionTransaction) -> [String] {
        defer { transaction.isOpen = false }
        var problems = transaction.problems
        for check in commitChecks { problems += check(transaction.manifest, transaction.staged) }
        guard problems.isEmpty else { return problems }
        for entry in transaction.staged { entries[entry.pointID, default: []].append(entry) }
        generation += 1
        return []
    }

    package func discard(_ transaction: ContributionTransaction) {
        transaction.isOpen = false
        transaction.staged.removeAll()
    }

    // MARK: Helpers

    /// The default id rule: a valid qualified name inside the plugin's namespace.
    package static let namespacePolicy: IDPolicy = { id, manifest in
        guard IdentifierRules.isValidQualifiedName(id) else { return "not a valid name" }
        guard IdentifierRules.isNamespaced(id, under: manifest.id) else {
            return "must be \"\(manifest.id)\" or start with \"\(manifest.id).\""
        }
        return nil
    }

    private static func declaration<C>(of point: ExtensionPoint<C>) -> Declaration {
        Declaration(pointID: point.id, contributionType: ObjectIdentifier(C.self), typeName: String(reflecting: C.self))
    }

    private static func typed<C>(_ entry: Entry) -> Owned<C>? {
        (entry.value as? C).map { Owned(owner: entry.owner, value: $0) }
    }
}

@MainActor
package final class ContributionTransaction {
    package let manifest: PluginManifest
    fileprivate(set) var staged: [ContributionRegistry.Entry] = []
    fileprivate(set) var problems: [String] = []
    package fileprivate(set) var isOpen = true

    fileprivate init(manifest: PluginManifest) {
        self.manifest = manifest
    }
}
