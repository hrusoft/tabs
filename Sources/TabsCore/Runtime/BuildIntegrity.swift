import Foundation
import TabsPluginSDK

/// Checks that an app bundle is one build: the app and every framework in it
/// carry the loaded SDK's fingerprint. Plugins are checked one by one at
/// discovery, where a mismatch rejects only that plugin; a mismatch here means
/// the app itself can't be trusted.
package enum BuildIntegrity {
    package static func problems(appBundle: Bundle, sdkFingerprint: String? = BuildStamp.loadedFingerprint) -> [String] {
        guard let sdkFingerprint else { return ["the loaded SDK carries no build stamp"] }
        var problems: [String] = []
        func check(_ bundle: Bundle, _ name: String) {
            guard let stamp = BuildStamp(of: bundle) else {
                problems.append("\(name) carries no build stamp")
                return
            }
            if stamp.fingerprint != sdkFingerprint {
                problems.append(
                    "\(name) was built (\(stamp.configuration)) against shared modules \(stamp.fingerprint), the SDK is \(sdkFingerprint)")
            }
        }
        check(appBundle, appBundle.bundleURL.lastPathComponent)
        let frameworks =
            (try? FileManager.default.contentsOfDirectory(
                at: appBundle.privateFrameworksURL ?? appBundle.bundleURL, includingPropertiesForKeys: nil
            )) ?? []
        for url in frameworks.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "framework" {
            guard let framework = Bundle(url: url) else {
                problems.append("\(url.lastPathComponent) is not a readable bundle")
                continue
            }
            check(framework, url.lastPathComponent)
        }
        return problems
    }
}
