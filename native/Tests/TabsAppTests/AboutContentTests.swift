import Foundation
import Testing

@testable import Tabs

/// What the About window credits and offers (docs/ABOUT.md), held to its rules the way the Electron
/// app's `attributions.test.ts` holds its own: the list reconciled with what the build links, and the
/// donation data's shape. Plus the two checks the native app adds because its money values are
/// generated: that they are `app.config.ts`'s, and that a URL is vetted before it is opened.
@Suite struct AboutContentTests {
    // MARK: Attributions (shared/__tests__/attributions.test.ts)

    /// The repository's `native/` directory, from this file's own path.
    private static let native = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The SwiftPM packages the build specs declare: the `packages:` keys of `project.yml` and of every
    /// plugin's `plugin.yml`. A package there is a package the app links; nothing else can be.
    private static func declaredPackages() throws -> [String] {
        var files = [native.appending(path: "project.yml")]
        let plugins = native.appending(path: "Plugins")
        for folder in try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            let spec = folder.appending(path: "plugin.yml")
            if FileManager.default.fileExists(atPath: spec.path) { files.append(spec) }
        }
        var names: [String] = []
        for file in files {
            var inPackages = false
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                if line == "packages:" {
                    inPackages = true
                } else if inPackages, line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") {
                    names.append(String(line[line.index(line.startIndex, offsetBy: 2)..<colon]))
                } else if inPackages, !line.hasPrefix(" "), !line.hasPrefix("#"), !line.isEmpty {
                    inPackages = false
                }
            }
        }
        return names.sorted()
    }

    @Test func creditsExactlyThePackagesTheBuildLinks() throws {
        let declared = try Self.declaredPackages()
        #expect(!declared.isEmpty, "the spec parse found nothing: the test would pass for any list")
        // One assertion rather than two set differences: a diff of the two sorted lists names the
        // offender in both directions at once.
        #expect(Attributions.all.map(\.name).sorted() == declared)
    }

    @Test func namesNoPackageTwice() {
        let names = Attributions.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func listsThePackagesAlphabetically() {
        let names = Attributions.all.map(\.name)
        #expect(names == names.sorted { $0.lowercased() < $1.lowercased() })
    }

    @Test func givesEveryEntryALicenseAndAnOpenableURL() {
        #expect(!Attributions.all.isEmpty)
        for entry in Attributions.all {
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

    /// `app.config.ts`'s entries of one block, read straight out of the file: what the generated Swift
    /// must equal. Independent of `Scripts/sync-app-config.py`, which is what it checks.
    private static func appConfig(_ block: String) throws -> [String: String] {
        let source = try String(contentsOf: native.deletingLastPathComponent().appending(path: "app.config.ts"), encoding: .utf8)
        let noBlocks = source.replacing(/\/\*[\s\S]*?\*\//, with: "")
        let withoutComments = noBlocks.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let open = try #require(withoutComments.range(of: "\(block): {"), "no \(block) block")
        let rest = withoutComments[open.upperBound...]
        let close = try #require(rest.firstIndex(of: "}"))
        var entries: [String: String] = [:]
        for match in rest[..<close].matches(of: /(\w+):\s*'([^']*)'/) { entries[String(match.output.1)] = String(match.output.2) }
        return entries
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

    // MARK: What may be opened (openExternal.ts, plugin-sdk/shared/url.ts)

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
