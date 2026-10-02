import Foundation
import TabsPluginSDK

/// A plugin that passed discovery, and how to instantiate it.
package struct PluginCandidate {
    package enum Source {
        /// A `.tabsplugin` bundle; loading it maps its code into the process.
        case bundle(Bundle)
        /// A plugin type linked into the running image. Tests use this to run
        /// the real host against plugins they define inline.
        case inProcess(bundle: Bundle, make: @MainActor () -> any TabsPlugin)
    }

    package let manifest: PluginManifest
    package let source: Source

    package init(manifest: PluginManifest, source: Source) {
        self.manifest = manifest
        self.source = source
    }

    package var bundle: Bundle {
        switch source {
        case .bundle(let bundle), .inProcess(let bundle, _): bundle
        }
    }

    package var location: String {
        switch source {
        case .bundle(let bundle): bundle.bundleURL.path
        case .inProcess: "in-process"
        }
    }
}

/// Finds plugins and vets them using nothing but their Info.plist. A plugin
/// rejected here never has a byte of its code mapped into the process.
package enum PluginDiscovery {
    package static let bundleExtension = "tabsplugin"

    package struct Result {
        package var candidates: [PluginCandidate] = []
        package var rejected: [PluginRecord] = []

        package init() {}
    }

    /// - Parameters:
    ///   - expectedFingerprint: the loaded SDK's shared-ABI fingerprint.
    ///   - bundled: the ids the app says it ships (`TabsBundledPlugins`). When
    ///     given, discovery reconciles in both directions: a listed plugin that
    ///     is absent, and a present bundle that isn't listed, are both rejected.
    ///     nil (a test fixture directory) skips the reconciliation.
    package static func discover(in directory: URL, expectedFingerprint: String?, bundled: [PluginID]? = nil) -> Result {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )) ?? []
        let bundles = urls.filter { $0.pathExtension == bundleExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result = Result()
        for url in bundles {
            let fileID = PluginID(url.deletingPathExtension().lastPathComponent)
            if let bundled, !bundled.contains(fileID) {
                result.rejected.append(
                    rejection(
                        fileID, at: url.path, manifest: nil,
                        "is not one of the app's bundled plugins (\(bundled.map(\.rawValue).joined(separator: ", "))); a stray or renamed bundle"
                    ))
                continue
            }
            switch vet(url, fileID: fileID, expectedFingerprint: expectedFingerprint) {
            case .success(let candidate): result.candidates.append(candidate)
            case .failure(let error): result.rejected.append(error.record)
            }
        }
        if let bundled {
            let present = Set(bundles.map { PluginID($0.deletingPathExtension().lastPathComponent) })
            for id in bundled where !present.contains(id) {
                result.rejected.append(
                    rejection(
                        id, at: directory.appending(path: "\(id).\(bundleExtension)").path, manifest: nil,
                        "is listed as bundled with the app but missing from its PlugIns directory"))
            }
        }
        return result
    }

    private static func vet(_ url: URL, fileID: PluginID, expectedFingerprint: String?) -> Swift.Result<PluginCandidate, RejectedPlugin> {
        func reject(_ reason: String, _ manifest: PluginManifest? = nil) -> Swift.Result<PluginCandidate, RejectedPlugin> {
            .failure(RejectedPlugin(record: rejection(fileID, at: url.path, manifest: manifest, reason)))
        }

        // A link could point anywhere, including outside the signed app bundle.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return reject("is a symbolic link; plugins must be real bundles inside the app")
        }
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else {
            return reject("is not a readable bundle")
        }
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest(infoDictionary: info)
        } catch {
            return reject(String(describing: error))
        }
        let problems = manifest.problems()
        if !problems.isEmpty {
            return reject("invalid manifest: " + problems.joined(separator: "; "), manifest)
        }
        if manifest.id != fileID {
            return reject("manifest id \"\(manifest.id)\" does not match the bundle name \"\(fileID).\(bundleExtension)\"", manifest)
        }
        guard let stamp = BuildStamp(of: bundle) else {
            return reject("carries no build stamp; it was not built by this project's build", manifest)
        }
        if stamp.role != .plugin {
            return reject("is stamped with role \"\(stamp.role.rawValue)\", not \"plugin\"", manifest)
        }
        if stamp.fingerprint != expectedFingerprint {
            return reject(
                "was built (\(stamp.configuration)) against different shared modules (fingerprint \(stamp.fingerprint), this app has \(expectedFingerprint ?? "none")); rebuild it with the app",
                manifest
            )
        }
        return .success(PluginCandidate(manifest: manifest, source: .bundle(bundle)))
    }

    /// Adds plugins linked into the running image (tests), vetted like bundles
    /// by their manifest.
    package static func add(inProcess candidates: [PluginCandidate], to result: inout Result) {
        for candidate in candidates {
            let problems = candidate.manifest.problems()
            if problems.isEmpty {
                result.candidates.append(candidate)
            } else {
                result.rejected.append(
                    rejection(
                        candidate.manifest.id, at: candidate.location, manifest: candidate.manifest,
                        "invalid manifest: " + problems.joined(separator: "; ")))
            }
        }
    }

    /// Two plugins with one id (a bundle and an in-process plugin) is a
    /// packaging error with no right winner: every claimant is rejected.
    /// Everything else a plugin owns is namespaced by its id, so this is the
    /// only clash possible.
    package static func rejectDuplicateIDs(_ result: inout Result) {
        let counts = Dictionary(result.candidates.map { ($0.manifest.id, 1) }, uniquingKeysWith: +)
        result.candidates.removeAll { candidate in
            guard counts[candidate.manifest.id, default: 0] > 1 else { return false }
            result.rejected.append(
                rejection(
                    candidate.manifest.id, at: candidate.location, manifest: candidate.manifest,
                    "another plugin has the same id"))
            return true
        }
    }

    /// A rejected plugin's record is keyed by its bundle name — its identity on
    /// disk — so a bundle claiming another plugin's id can't shadow that plugin.
    private static func rejection(_ id: PluginID, at location: String, manifest: PluginManifest?, _ reason: String) -> PluginRecord {
        PluginRecord(
            id: id,
            displayName: manifest?.displayName ?? id.rawValue,
            summary: manifest?.summary ?? "",
            location: location,
            canDisable: manifest?.canDisable ?? true,
            declaredContentTypes: manifest?.contentTypes ?? [],
            state: .rejected(reason),
            userEnabled: true
        )
    }
}

private struct RejectedPlugin: Error {
    let record: PluginRecord
}
