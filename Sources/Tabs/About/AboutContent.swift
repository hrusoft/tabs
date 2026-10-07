import Foundation
import TabsPluginSDK

/// What the About window hands the OS browser.
///
/// Every URL that reaches `open` is attacker-influenceable in principle, and the
/// OS would happily launch a `file:` path or a registered custom scheme, so the
/// protocol is checked first and a rejected URL is silently dropped.
enum ExternalURL {
    /// The allowlist is deliberately tiny.
    static let schemes: Set<String> = ["http", "https", "mailto"]

    /// Whether `string` is safe to open outside the app, in the user's browser or mail client.
    static func isSafe(_ string: String) -> Bool {
        // Not a parseable absolute URL at all (a relative path, a bare word): no scheme, so no.
        guard let scheme = URL(string: string)?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }

    /// `string` as a URL, if it may be opened.
    static func vetted(_ string: String) -> URL? {
        isSafe(string) ? URL(string: string) : nil
    }
}

/// One credited third-party package.
struct Attribution: Equatable, Sendable {
    /// The SwiftPM package name, exactly as a build spec (`project.yml`, a `plugin.yml`) declares it.
    let name: String
    /// SPDX identifier, read from the package's own license.
    let license: String
    /// Where a reader can go to check the claim.
    let url: String
}

/// Everything the About window credits.
///
/// This is a compliance obligation, not a courtesy. Tabs is proprietary (see LICENSE)
/// and what it links is MIT or BSD, whose one substantive condition is that the
/// notice travels with the binary. An unattributed package is a license violation,
/// which is why each list is reconciled against its build spec by a test
/// (`AboutContentTests`) rather than trusted to memory.
///
/// Core credits what `project.yml` links; a plugin credits what its own `plugin.yml`
/// links, in its Info.plist (`TabsCredits`), so the credits ship with the plugin that
/// carries the code. What the app shares with the system (AppKit, WebKit) is the OS's
/// own, so it has no row.
enum Attributions {
    /// The packages core and the shell link (`project.yml`'s), alphabetically: none.
    static let core: [Attribution] = []

    /// A plugin's Info.plist key for the packages it links: an array of `{name, license, url}`.
    static let infoPlistKey = "TabsCredits"

    /// What a plugin bundle credits (`TabsCredits`); an entry missing a field is left out.
    static func credits(of plugin: Bundle) -> [Attribution] {
        credits(inInfoDictionary: plugin.infoDictionary ?? [:])
    }

    /// The credits an Info.plist's contents list.
    static func credits(inInfoDictionary info: [String: Any]) -> [Attribution] {
        ((info[infoPlistKey] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, let license = entry["license"] as? String, let url = entry["url"] as? String
            else { return nil }
            return Attribution(name: name, license: license, url: url)
        }
    }

    /// Everything the app in `appBundle` credits: core's and every bundled plugin's (its
    /// stamp's list, enabled or not: it ships them all), each package once, alphabetically.
    static func all(in appBundle: Bundle) -> [Attribution] {
        let plugIns = appBundle.builtInPlugInsURL
        let bundled = (BuildStamp(of: appBundle)?.bundledPlugins ?? []).flatMap { id in
            plugIns.flatMap { Bundle(url: $0.appending(path: "\(id).tabsplugin")) }.map(credits(of:)) ?? []
        }
        var seen = Set<String>()
        return (core + bundled)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// One fixed donation tier.
struct DonationTier: Equatable, Identifiable, Sendable {
    /// Stable id: the accessibility identifier's suffix.
    let id: String
    /// The tier's name, as shown on its button.
    let label: String
    /// The bit of flavor text under the label.
    let flavor: String
    /// Whole units of `Donations.currency`.
    let amount: Int
    /// The tier's own Stripe Payment Link.
    let url: String
}

/// One receiving address.
struct CryptoAddress: Equatable, Identifiable, Sendable {
    /// Stable id: the accessibility identifier's suffix.
    let id: String
    /// Ticker, as shown in the UI.
    let symbol: String
    /// Full chain name, so the ticker is never the only label.
    let label: String
    /// The receiving address, copied to the pasteboard.
    let address: String
}

/// The About window's donation offer: three fixed tiers and two crypto addresses.
///
/// The structure and the copy are here. The values that have to be *right* are not:
/// every payment link and receiving address is read out of `AppConfig`, which
/// `Scripts/sync-app-config.py` generates from `Config/AppConfig.plist`, so a tier renamed here
/// without renaming its key there is a compile error, and the two files cannot differ
/// unnoticed (`AboutContentTests`).
enum Donations {
    /// The currency shown beside each tier, and it must be the currency the Payment
    /// Links are priced in. Nothing can check that: the price lives in Stripe.
    static let currency = "USD"

    /// The three tiers, cheapest first.
    static let tiers: [DonationTier] = [
        DonationTier(
            id: "coffee", label: "Coffee", flavor: "One cup, one bug fixed. Roughly.", amount: 4,
            url: AppConfig.PaymentLinks.coffee),
        DonationTier(
            id: "beans", label: "A pack of roasted beans", flavor: "Enough to get through a whole feature.", amount: 20,
            url: AppConfig.PaymentLinks.beans),
        DonationTier(
            id: "grinder", label: "I'm rich, I'll buy you a nice grinder", flavor: "Burr, not blade. You have excellent taste.",
            amount: 200, url: AppConfig.PaymentLinks.grinder),
    ]

    /// The chains offered.
    static let addresses: [CryptoAddress] = [
        CryptoAddress(id: "btc", symbol: "BTC", label: "Bitcoin", address: AppConfig.CryptoAddresses.btc),
        CryptoAddress(id: "eth", symbol: "ETH", label: "Ethereum", address: AppConfig.CryptoAddresses.eth),
    ]

    /// The tier's amount as it appears on screen, e.g. `$4 USD`.
    static func formatAmount(_ tier: DonationTier) -> String {
        "$\(tier.amount) \(currency)"
    }
}

/// The copy of the About window that isn't data, in one place so the model, the view and the
/// tests read the same strings.
enum AboutCopy {
    static let windowTitle = "About Tabs"
    static let name = "Tabs"
    /// Echoes README.md's own opening line rather than inventing a second description.
    static let tagline = "A fancy terminal with tabs, splits, and nested layouts."
    static let copyright = "Copyright © 2026 Hrusoft. All rights reserved."

    static let donationsTitle = "Buy me a coffee"
    static let donationsDescription = "Like this app? You can buy me a coffee to fuel future development."
    static let cryptoTitle = "Or in crypto"
    static let cryptoDescription = "Same idea, no card involved. Copy an address and send whatever you like."
    static let creditsTitle = "Built with"
    static let creditsDescription = "Tabs would not be possible without these projects."

    static let copyLabel = "Copy"
    static let copiedLabel = "Copied"

    /// "Version 1.2", from the running build's own version.
    static func version(_ version: String) -> String { "Version \(version)" }
    /// What a Copy button is called to assistive technology.
    static func copyAddressLabel(_ entry: CryptoAddress) -> String { "Copy \(entry.label) address" }
}
