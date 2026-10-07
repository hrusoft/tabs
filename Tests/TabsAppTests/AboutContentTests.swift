import Foundation
import TabsPluginSDK
import Testing

@testable import Tabs

/// What the About window credits and offers (docs/ABOUT.md), held to its rules: the list reconciled with
/// what the build links, and the donation data's shape. Plus two checks because the money values are
/// generated: that they are `Config/AppConfig.plist`'s, and that a URL is vetted before it is opened.
@Suite struct AboutContentTests {
    // MARK: Attributions

    /// The repository, from this file's own path.
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The SwiftPM packages a build spec declares: its `packages:` keys. A package there is a package its
    /// targets link; nothing else can be.
    private static func declaredPackages(in spec: String) -> [String] {
        var inPackages = false
        var names: [String] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "packages:" {
                inPackages = true
            } else if inPackages, line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") {
                names.append(String(line[line.index(line.startIndex, offsetBy: 2)..<colon]))
            } else if inPackages, !line.hasPrefix(" "), !line.hasPrefix("#"), !line.isEmpty {
                inPackages = false
            }
        }
        return names.sorted()
    }

    private static func declaredPackages(inSpecAt url: URL) throws -> [String] {
        declaredPackages(in: try String(contentsOf: url, encoding: .utf8))
    }

    /// Every plugin's folder: `Plugins/<Name>/`, with its plugin.yml and Info.plist.
    private static func pluginFolders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appending(path: "Plugins"), includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "plugin.yml").path) }
    }

    /// A plugin folder's Info.plist, as written.
    private static func info(ofPluginAt folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appending(path: "Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theSpecParseFindsThePackagesAndNothingElse() {
        let spec = """
            # A comment.
            packages:
              SwiftTerm:
                url: https://example.com/SwiftTerm
              Other:
                revision: abc
            targets:
              Plugin:
                dependencies:
                  - package: SwiftTerm
            """
        #expect(Self.declaredPackages(in: spec) == ["Other", "SwiftTerm"], "else the reconciliations would pass for any list")
    }

    @Test func coreCreditsExactlyThePackagesItLinks() throws {
        // One assertion rather than two set differences: a diff of the two sorted lists names the
        // offender in both directions at once.
        #expect(try Attributions.core.map(\.name).sorted() == Self.declaredPackages(inSpecAt: Self.root.appending(path: "project.yml")))
    }

    @Test func everyPluginCreditsExactlyThePackagesItLinks() throws {
        for folder in try Self.pluginFolders() {
            let credited = Attributions.credits(inInfoDictionary: try Self.info(ofPluginAt: folder)).map(\.name).sorted()
            let declared = try Self.declaredPackages(inSpecAt: folder.appending(path: "plugin.yml"))
            #expect(credited == declared, "Plugins/\(folder.lastPathComponent): its Info.plist's TabsCredits against its plugin.yml")
        }
    }

    @Test func theAppCreditsCoreAndEveryBundledPlugin() throws {
        let bundled = Set(try #require(BuildStamp(of: .main)?.bundledPlugins).map(\.rawValue))
        var expected = Set(Attributions.core.map(\.name))
        for folder in try Self.pluginFolders() {
            let info = try Self.info(ofPluginAt: folder)
            guard let id = (info["TabsPlugin"] as? [String: Any])?["id"] as? String, bundled.contains(id) else { continue }
            expected.formUnion(Attributions.credits(inInfoDictionary: info).map(\.name))
        }
        #expect(Set(Attributions.all(in: .main).map(\.name)) == expected)
    }

    @Test func namesNoPackageTwice() {
        let names = Attributions.all(in: .main).map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func listsThePackagesAlphabetically() {
        let names = Attributions.all(in: .main).map(\.name)
        #expect(names == names.sorted { $0.lowercased() < $1.lowercased() })
    }

    @Test func givesEveryEntryALicenseAndAnOpenableURL() throws {
        let entries = try Self.pluginFolders().flatMap { Attributions.credits(inInfoDictionary: try Self.info(ofPluginAt: $0)) }
        for entry in Attributions.core + entries {
            #expect(!entry.license.isEmpty, "\(entry.name) has no license")
            // Not decoration: a bad URL is a link that does nothing at all, not one that errors.
            #expect(ExternalURL.isSafe(entry.url), "\(entry.name): \(entry.url)")
        }
    }

    // MARK: Donations (the same file's "donations" group)

    @Test func offersTheThreeTiersCheapestFirst() {
        #expect(Donations.tiers.map(\.amount) == [4, 20, 200])
        #expect(Donations.tiers.map(\.id) == ["coffee", "beans", "grinder"])
    }

    @Test func formatsAnAmountWithItsCurrency() {
        #expect(Donations.tiers.map(Donations.formatAmount) == ["$4 USD", "$20 USD", "$200 USD"])
    }

    @Test func givesEveryTierADistinctIdAndItsOwnLink() {
        let ids = Donations.tiers.map(\.id)
        #expect(Set(ids).count == ids.count)
        let links = Donations.tiers.map(\.url)
        #expect(Set(links).count == links.count, "two tiers share a payment link")
    }

    @Test func keepsEveryTierLinkOpenable() {
        for tier in Donations.tiers { #expect(ExternalURL.isSafe(tier.url), "\(tier.id): \(tier.url)") }
    }

    @Test func givesEveryCryptoAddressADistinctIdAndANonEmptyValue() {
        let ids = Donations.addresses.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["btc", "eth"])
        for entry in Donations.addresses {
            #expect(!entry.address.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) has no address")
        }
    }

    // MARK: The money (docs/ABOUT.md "Money")

    /// `Config/AppConfig.plist`'s entries of one block, read straight out of the file by
    /// `PropertyListSerialization`: what the generated Swift must equal. Independent of
    /// `Scripts/sync-app-config.py`, which is what it checks.
    private static func appConfig(_ block: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appending(path: "Config/AppConfig.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let donations = try #require((plist as? [String: Any])?["donations"] as? [String: Any], "no donations dict")
        return try #require(donations[block] as? [String: String], "no \(block) block of strings")
    }

    @Test func theGeneratedPaymentLinksAreAppConfigsOwn() throws {
        let expected = try Self.appConfig("paymentLinks")
        #expect(expected.count == 3, "the parse found \(expected.count) links")
        #expect(AppConfig.PaymentLinks.all == expected)
    }

    @Test func theGeneratedAddressesAreAppConfigsOwn() throws {
        let expected = try Self.appConfig("cryptoAddresses")
        #expect(expected.count == 2, "the parse found \(expected.count) addresses")
        #expect(AppConfig.CryptoAddresses.all == expected)
    }

    @Test func everyTierAndAddressReadsItsOwnConfiguredValue() {
        for tier in Donations.tiers { #expect(AppConfig.PaymentLinks.all[tier.id] == tier.url, "\(tier.id)") }
        for entry in Donations.addresses { #expect(AppConfig.CryptoAddresses.all[entry.id] == entry.address, "\(entry.id)") }
        #expect(Set(AppConfig.PaymentLinks.all.keys) == Set(Donations.tiers.map(\.id)), "a configured link no tier shows")
        #expect(Set(AppConfig.CryptoAddresses.all.keys) == Set(Donations.addresses.map(\.id)), "a configured address nothing shows")
    }

    // MARK: What may be opened

    @Test func opensOnlyWebAndMailLinks() {
        for url in ["http://example.com", "https://example.com/a?b=c", "HTTPS://EXAMPLE.COM", "mailto:someone@example.com"] {
            #expect(ExternalURL.isSafe(url), "\(url)")
            #expect(ExternalURL.vetted(url) != nil, "\(url)")
        }
    }

    @Test func refusesEverythingElse() {
        let refused = [
            "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference", "tel:123", "ftp://example.com",
            "docs/readme", "example.com", "", "//example.com",
        ]
        for url in refused {
            #expect(!ExternalURL.isSafe(url), "\(url)")
            #expect(ExternalURL.vetted(url) == nil, "\(url)")
        }
    }
}
