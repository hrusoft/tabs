import Foundation
import TabsPluginSDK

/// A JSON document core persists (settings.json, layout.json).
///
/// On disk the document is its encoded form plus a top-level `"version"`,
/// which lets a build recognise a file from a newer one. There are no
/// migrations: formats change in lockstep with the app, and nothing reads an
/// older one. Decoding should be tolerant — fields with defaults decode when
/// absent, and a malformed element is dropped and reported through
/// `DecodingDiagnostics` rather than failing the whole document.
package protocol PersistedDocument: Codable {
    static var currentVersion: Int { get }
}

/// Collects what a tolerant decode had to drop. Models reach it through
/// `decoder.diagnostics` and record instead of throwing.
package final class DecodingDiagnostics: @unchecked Sendable {
    package private(set) var dropped: [String] = []
    package init() {}
    package func drop(_ what: String) { dropped.append(what) }

    static let key = CodingUserInfoKey(rawValue: "tabs.decodingDiagnostics")!
}

package extension Decoder {
    var diagnostics: DecodingDiagnostics? { userInfo[DecodingDiagnostics.key] as? DecodingDiagnostics }
}

package extension DocumentStore.Outcome {
    var document: Document? {
        switch self {
        case .loaded(let document), .recovered(let document, _): document
        case .missing, .unreadable: nil
        }
    }

    /// What the user should hear about, if anything.
    var notes: [String] {
        switch self {
        case .recovered(_, let notes): notes
        case .unreadable(let reason): [reason]
        case .missing, .loaded: []
        }
    }
}

/// Reads and writes one document, and never loses the user's data doing it.
///
/// - A file that doesn't parse, or doesn't decode, is moved aside
///   (`<name>.unreadable-<time>.json`) and the caller starts fresh.
/// - A file that decoded only partly is copied aside (`.partial-<time>`)
///   before the first save replaces it.
/// - A file written by a newer build (higher version) is copied aside
///   (`.newer-<time>`) before this build's first save.
/// - A save that can't encode logs and leaves the previous file intact; writes
///   are atomic. Nothing here throws: persistence runs from timers and at quit.
///
/// `readOnly` stores (headless modes) never move, copy or write anything.
package final class DocumentStore<Document: PersistedDocument> {
    package enum Outcome {
        case missing
        case loaded(Document)
        /// Loaded, but parts were dropped or the file came from a newer build;
        /// the original is preserved before the first save.
        case recovered(Document, notes: [String])
        /// Unusable; moved aside (unless read-only) and the caller starts fresh.
        case unreadable(reason: String)
    }

    /// The two file operations the promise rests on; replaceable in tests to
    /// prove that a failure refuses the save rather than being ignored.
    package struct FileOperations {
        package var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        package var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        package init() {}
    }

    package let file: URL
    package let readOnly: Bool
    package var fileOperations = FileOperations()
    /// Set by `load` when the original must be preserved before a save replaces it.
    private var preserveBeforeSave: String?
    /// Set when an unreadable file could not be moved aside: it must not be overwritten.
    private var mustNotOverwrite = false

    package init(file: URL, readOnly: Bool = false) {
        self.file = file
        self.readOnly = readOnly
    }

    package func load() -> Outcome {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        } catch {
            return unreadable("does not parse: \(Self.describe(error))")
        }
        let version = Int(json["version"]?.intValue ?? 1)
        var notes: [String] = []
        if version > Document.currentVersion {
            notes.append(
                "written by a newer build (version \(version), this build reads \(Document.currentVersion)); the original is kept alongside"
            )
            preserveBeforeSave = "newer"
        }
        let diagnostics = DecodingDiagnostics()
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[DecodingDiagnostics.key] = diagnostics
            let document = try decoder.decode(Document.self, from: json.encodedData(pretty: false))
            if !diagnostics.dropped.isEmpty {
                notes += diagnostics.dropped
                preserveBeforeSave = preserveBeforeSave ?? "partial"
            }
            return notes.isEmpty ? .loaded(document) : .recovered(document, notes: notes)
        } catch {
            return unreadable("does not decode: \(Self.describe(error))")
        }
    }

    /// Returns whether the document reached disk.
    @discardableResult
    package func save(_ document: Document) -> Bool {
        guard !readOnly else { return false }
        guard !mustNotOverwrite else {
            Log.persistence.error(
                "not saving \(self.file.lastPathComponent, privacy: .public): it could not be read or moved aside, and would be lost")
            return false
        }
        do {
            guard case .object(var object) = try JSONValue(encoding: document) else {
                Log.persistence.fault("\(self.file.lastPathComponent, privacy: .public): a document must encode as a JSON object")
                return false
            }
            object["version"] = .int(Int64(Document.currentVersion))
            let data = try JSONValue.object(object).encodedData()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let reason = preserveBeforeSave {
                // Copy first; if that fails, don't overwrite (the flag stays set,
                // the next save retries). A file that has gone since it was read
                // (the user deleted it) has nothing left to preserve.
                if FileManager.default.fileExists(atPath: file.path) { try fileOperations.copy(file, sibling(reason)) }
                preserveBeforeSave = nil
            }
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            Log.persistence.error(
                "could not save \(self.file.lastPathComponent, privacy: .public), keeping the previous file: \(Self.describe(error), privacy: .public)"
            )
            return false
        }
    }

    private func unreadable(_ reason: String) -> Outcome {
        Log.persistence.error("\(self.file.lastPathComponent, privacy: .public) \(reason, privacy: .public)")
        guard !readOnly else { return .unreadable(reason: reason) }
        let aside = sibling("unreadable")
        do {
            try fileOperations.move(file, aside)
            return .unreadable(reason: "\(reason); moved to \(aside.lastPathComponent)")
        } catch {
            mustNotOverwrite = true
            return .unreadable(reason: "\(reason); it could not be moved aside (\(Self.describe(error))), so it will not be overwritten")
        }
    }

    /// `<name>.<reason>-<time>.json`, never an existing file.
    private func sibling(_ reason: String) -> URL {
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
        let base = file.deletingPathExtension()
        var candidate = base.appendingPathExtension("\(reason)-\(stamp).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathExtension("\(reason)-\(stamp)-\(counter).json")
            counter += 1
        }
        return candidate
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "missing \"\(key.stringValue)\" at \(path(context))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "wrong type at \(path(context))"
        case DecodingError.dataCorrupted(let context):
            "corrupt data at \(path(context)): \(context.debugDescription)"
        default:
            String(describing: error)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "the top level" : path
    }
}
