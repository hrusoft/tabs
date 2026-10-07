import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

// The browser's pure model, unhosted (docs/BROWSER.md ids).

/// B-8: what Enter in the address bar navigates to.
@Suite struct AddressInputTests {
    @Test func prependsHttpsToABareDomain() {
        #expect(resolveAddressInput("example.com") == "https://example.com")
    }

    @Test func prependsHttpsToABareDomainWithAPath() {
        #expect(resolveAddressInput("example.com/docs") == "https://example.com/docs")
    }

    @Test func passesAnAlreadySchemedURLThroughUnchanged() {
        #expect(resolveAddressInput("http://example.com") == "http://example.com")
        #expect(resolveAddressInput("https://example.com") == "https://example.com")
        #expect(resolveAddressInput("about:blank") == "about:blank")
    }

    @Test func treatsLocalhostWithAPortAsAURLNotASearch() {
        #expect(resolveAddressInput("localhost:3000") == "https://localhost:3000")
        #expect(resolveAddressInput("LOCALHOST") == "https://LOCALHOST")
        #expect(resolveAddressInput("localhost/app") == "https://localhost/app")
    }

    @Test func treatsAMultiWordPhraseAsASearchQuery() {
        #expect(resolveAddressInput("claude code docs") == "https://www.google.com/search?q=claude%20code%20docs")
    }

    @Test func treatsASingleWordWithNoDotAsASearchQuery() {
        #expect(resolveAddressInput("cats") == "https://www.google.com/search?q=cats")
    }

    @Test func treatsADottedPhraseContainingASpaceAsASearchQuery() {
        #expect(resolveAddressInput("example.com is great") == "https://www.google.com/search?q=example.com%20is%20great")
    }

    @Test func returnsNilForBlankInput() {
        #expect(resolveAddressInput("") == nil)
        #expect(resolveAddressInput("   ") == nil)
        #expect(resolveAddressInput("\n\t ") == nil)
    }

    @Test func trimsSurroundingWhitespaceBeforeResolving() {
        #expect(resolveAddressInput("  example.com  ") == "https://example.com")
    }

    /// `encodeURIComponent`'s alphabet: what a query keeps, what it encodes.
    @Test func aSearchIsPercentEncodedTheWayEncodeURIComponentDoes() {
        #expect(resolveAddressInput("a&b=c?d") == "https://www.google.com/search?q=a%26b%3Dc%3Fd")
        #expect(resolveAddressInput("it's (fine)!") == "https://www.google.com/search?q=it's%20(fine)!")
        #expect(resolveAddressInput("café 日本") == "https://www.google.com/search?q=caf%C3%A9%20%E6%97%A5%E6%9C%AC")
    }
}

/// F-6, F-7 and the OS-open allowlist: `isAllowedUrl`, `isAllowedResourceUrl` and
/// `isSafeExternalUrl`.
@Suite struct UrlPolicyTests {
    @Test func allowsAboutBlankAndTheWebSchemesForNavigation() {
        #expect(isAllowedUrl("about:blank"))
        #expect(isAllowedUrl("http://example.com"))
        #expect(isAllowedUrl("https://example.com/a?b=c#d"))
        #expect(isAllowedUrl("HTTPS://EXAMPLE.COM"))
    }

    @Test func refusesEverythingElseForNavigation() {
        for url in [
            "file:///etc/hosts", "javascript:alert(1)", "data:text/html,<b>x</b>", "blob:http://example.com/uuid", "ftp://example.com/x",
            "chrome://version", "about:srcdoc", "example.com", "not a url", "", "http://", "http:",
        ] {
            #expect(!isAllowedUrl(url), "\(url)")
        }
    }

    @Test func allowsTheFourReadFromSchemes() {
        #expect(isAllowedResourceUrl("http://example.com/a.png"))
        #expect(isAllowedResourceUrl("https://example.com/a.png"))
        #expect(isAllowedResourceUrl("blob:http://example.com/uuid"))
        #expect(isAllowedResourceUrl("data:text/plain,hi"))
    }

    @Test func refusesFileAndEveryOtherSchemeForReading() {
        for url in ["file:///etc/hosts", "chrome://version", "javascript:alert(1)", "ftp://example.com/x", "not a url"] {
            #expect(!isAllowedResourceUrl(url), "\(url)")
        }
    }

    @Test func acceptsHttpAndHttpsURLsToOpenOutside() {
        #expect(isSafeExternalUrl("http://example.com"))
        #expect(isSafeExternalUrl("https://example.com/docs?q=1#frag"))
        #expect(isSafeExternalUrl("https://localhost:3000"))
    }

    @Test func acceptsMailtoLinksToOpenOutside() {
        #expect(isSafeExternalUrl("mailto:someone@example.com"))
    }

    @Test func rejectsProtocolsThatWouldRunCodeOrReadTheFilesystem() {
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>alert(1)</script>", "vbscript:msgbox(1)"] {
            #expect(!isSafeExternalUrl(url), "\(url)")
        }
    }

    @Test func rejectsCustomSchemesThatCouldHandOffToAnotherApp() {
        #expect(!isSafeExternalUrl("ssh://root@example.com"))
        #expect(!isSafeExternalUrl("smb://example.com/share"))
    }

    @Test func rejectsAnythingThatIsNotAParseableAbsoluteURL() {
        for url in ["example.com", "/etc/passwd", "", "not a url at all"] { #expect(!isSafeExternalUrl(url), "\(url)") }
    }

    @Test func isCaseInsensitiveAboutTheScheme() {
        #expect(isSafeExternalUrl("HTTPS://example.com"))
        #expect(!isSafeExternalUrl("JavaScript:alert(1)"))
    }
}

/// The rule behind the navigation verbs' `redirected` flag.
@Suite struct UrlComparisonTests {
    let base = "http://127.0.0.1:5100"

    @Test func treatsTheSameURLAsTrivial() {
        #expect(isTrivialUrlChange(requested: "\(base)/page", final: "\(base)/page"))
    }

    @Test func ignoresATrailingSlashInBothDirections() {
        #expect(isTrivialUrlChange(requested: "\(base)/docs", final: "\(base)/docs/"))
        #expect(isTrivialUrlChange(requested: "\(base)/docs/", final: "\(base)/docs"))
        // A bare origin and its root path are the same place.
        #expect(isTrivialUrlChange(requested: base, final: "\(base)/"))
    }

    @Test func ignoresQueryParametersTheDestinationAdded() {
        #expect(isTrivialUrlChange(requested: "\(base)/page", final: "\(base)/page?session=abc"))
        #expect(isTrivialUrlChange(requested: "\(base)/page?a=1", final: "\(base)/page?a=1&b=2"))
    }

    @Test func flagsARequestedQueryParameterThatWasDroppedOrChanged() {
        // The deep-link-in-query case: the redirect discarded what was asked for.
        #expect(!isTrivialUrlChange(requested: "\(base)/app?next=%2Fdeep", final: "\(base)/app"))
        #expect(!isTrivialUrlChange(requested: "\(base)/search?q=a", final: "\(base)/search?q=b"))
        // A repeated parameter losing one of its values is a loss too.
        #expect(!isTrivialUrlChange(requested: "\(base)/list?tag=x&tag=y", final: "\(base)/list?tag=x"))
    }

    @Test func ignoresTheSchemeSoAnHttpsUpgradeIsNotARedirect() {
        #expect(isTrivialUrlChange(requested: "http://example.com/page", final: "https://example.com/page"))
    }

    @Test func ignoresTheFragment() {
        #expect(isTrivialUrlChange(requested: "\(base)/page", final: "\(base)/page#section"))
    }

    @Test func flagsADifferentPathTheAuthBounceShape() {
        #expect(!isTrivialUrlChange(requested: "\(base)/screening", final: "\(base)/dashboard"))
        // A subpath is still a different place, not a variant of the parent.
        #expect(!isTrivialUrlChange(requested: "\(base)/docs", final: "\(base)/docs/intro"))
    }

    @Test func flagsADifferentHostOrExplicitPort() {
        #expect(!isTrivialUrlChange(requested: "http://app.example.com/", final: "http://login.example.com/"))
        #expect(!isTrivialUrlChange(requested: "http://localhost:3000/", final: "http://localhost:4000/"))
    }

    @Test func fallsBackToPlainStringComparisonForURLsThatDoNotParse() {
        #expect(isTrivialUrlChange(requested: "about:blank", final: "about:blank"))
        #expect(isTrivialUrlChange(requested: "not a url", final: "not a url"))
        #expect(!isTrivialUrlChange(requested: "not a url", final: "also not a url"))
    }

    @Test func aHostIsCaseInsensitiveAndADefaultPortIsNoPort() {
        #expect(isTrivialUrlChange(requested: "http://EXAMPLE.com/a", final: "http://example.com:80/a"))
        #expect(!isTrivialUrlChange(requested: "http://example.com/a", final: "https://example.com:8443/a"))
    }
}

/// G-3: the placement setting, read and stored.
@MainActor
@Suite struct BrowserSettingsTests {
    @Test func resolveNewPanePlacementPassesEveryKnownPlacementThroughUnchanged() {
        for placement in NewPanePlacement.allCases {
            #expect(resolveNewPanePlacement(.string(placement.rawValue)) == placement)
        }
        #expect(NewPanePlacement.allCases.map(\.rawValue) == ["tab", "split-horizontal", "split-vertical", "unpinned"])
    }

    @Test func resolveNewPanePlacementFallsBackToTheDefaultForAnythingAHandEditedFileCouldHold() {
        for value: JSONValue? in ["sideways", "", nil, 3, ["placement": "tab"], .null, true] {
            #expect(resolveNewPanePlacement(value) == .tab)
        }
    }

    /// Core merges what is stored over the defaults, then decodes.
    private func decoded(_ stored: JSONValue) throws -> BrowserSettings {
        try stored.merged(over: JSONValue(encoding: BrowserSettings())).decode(BrowserSettings.self)
    }

    @Test func mergeReturnsTheDefaultsForNothingPersisted() throws {
        #expect(BrowserSettings() == BrowserSettings(controlledPanePlacement: .tab))
        #expect(try decoded([:]) == BrowserSettings())
    }

    @Test func mergeLetsAPersistedValueOverrideTheDefault() throws {
        #expect(try decoded(["controlledPanePlacement": "unpinned"]).controlledPanePlacement == .unpinned)
        #expect(try decoded(["controlledPanePlacement": "split-vertical"]).controlledPanePlacement == .splitVertical)
    }

    @Test func mergeNormalizesAGarbagePlacementRatherThanPassingItThrough() throws {
        #expect(try decoded(["controlledPanePlacement": "sideways"]).controlledPanePlacement == .tab)
        #expect(try decoded(["controlledPanePlacement": 9]).controlledPanePlacement == .tab)
    }

    @Test func mergeNeverThrowsWhateverShapeThePersistedValueIs() {
        // Totality is the whole contract: a throw here would make core use the
        // defaults wholesale.
        let hostile: [JSONValue] = [.null, 0, "x", [], [1, 2], true, ["controlledPanePlacement": 9], ["controlledPanePlacement": ["a"]]]
        for stored in hostile {
            #expect(throws: Never.self) { try decoded(stored) }
        }
    }

    @Test func aStoredValueRoundTripsThroughCoreSettings() throws {
        let harness = try PluginHarness.browser()
        TestSupport.writeJSON(
            ["controlledPanePlacement": "unpinned"], to: harness.runtime.paths.dataDirectory.appending(path: "unused.json"))
        let plugin = try #require(harness.runtime.registry.contribution(to: .settingsPages, id: "browser"))
        #expect(plugin.value.title == "Browser")
        #expect(harness.storedSettings == nil, "nothing is stored until the user changes something")
    }
}

extension BrowserSettings {
    init(controlledPanePlacement: NewPanePlacement) {
        self.init()
        self.controlledPanePlacement = controlledPanePlacement
    }
}

/// The roles a `--role` filter can name.
@Suite struct AriaRolesTests {
    @Test func acceptsEveryRoleRoleForCanDeriveWhateverTheCase() {
        for role in ["link", "button", "combobox", "textbox", "heading", "checkbox", "radio", "slider", "generic", "Button", "COMBOBOX"] {
            #expect(roleFilterError(role) == nil, "\(role)")
        }
    }

    @Test func acceptsTheARIARolesPagesSetExplicitlyModuleRolesIncluded() {
        for role in ["group", "switch", "menuitemcheckbox", "tab", "dialog", "searchbox"] {
            #expect(roleFilterError(role) == nil, "\(role)")
        }
        #expect(roleFilterError("doc-chapter") == nil)
        #expect(roleFilterError("graphics-document") == nil)
        // A bare prefix is not a role.
        #expect(roleFilterError("doc-")?.contains("unknown role") == true)
    }

    @Test func refusesANameThatIsNotARoleListingTheVocabulary() throws {
        let error = try #require(roleFilterError("nonsense"))
        #expect(error.contains("unknown role \"nonsense\""))
        for role in ariaRoles { #expect(error.contains(role), "\(role)") }
        // The tag, not its role: the mistake this most often catches.
        #expect(roleFilterError("select")?.contains("unknown role \"select\"") == true)
    }
}

/// The arithmetic both ends of a wait must agree on.
@Suite struct WaitBoundsTests {
    @Test func clampWaitTimeoutDefaultsWhenAbsentAndOnAnythingNonNumericOffTheWire() {
        #expect(clampWaitTimeout(nil) == BrowserLimits.waitDefaultTimeoutMs)
        #expect(clampWaitTimeout("9000") == BrowserLimits.waitDefaultTimeoutMs)
        #expect(clampWaitTimeout(.double(.nan)) == BrowserLimits.waitDefaultTimeoutMs)
        #expect(clampWaitTimeout(.double(.infinity)) == BrowserLimits.waitDefaultTimeoutMs)
    }

    @Test func clampWaitTimeoutPassesAReasonableRequestThroughRounded() {
        #expect(clampWaitTimeout(3000) == 3000)
        #expect(clampWaitTimeout(2500.7) == 2501)
    }

    @Test func clampWaitTimeoutCapsAtTheCeilingAndFloorsAtZero() {
        #expect(clampWaitTimeout(.int(Int64(BrowserLimits.waitMaxTimeoutMs + 1))) == BrowserLimits.waitMaxTimeoutMs)
        #expect(clampWaitTimeout(-5) == 0)
    }

    @Test func clampWaitPollDefaultsWhenAbsentOrNonNumericAndFloorsAtTheMinimum() {
        #expect(clampWaitPoll(nil) == BrowserLimits.waitDefaultPollMs)
        #expect(clampWaitPoll("fast") == BrowserLimits.waitDefaultPollMs)
        #expect(clampWaitPoll(1) == BrowserLimits.waitMinPollMs)
        #expect(clampWaitPoll(400) == 400)
    }

    @Test func theLimitsAreTheseNumbers() {
        #expect(BrowserLimits.defaultPageTextMax == 50_000 && BrowserLimits.pageTextHardMax == 200_000)
        #expect(BrowserLimits.executeResultMax == 50_000 && BrowserLimits.maxResourceBytes == 50 * 1024 * 1024)
        #expect(BrowserLimits.loadWaitMs == 15_000 && BrowserLimits.mountWaitMs == 5_000)
        #expect(BrowserLimits.waitDefaultTimeoutMs == 10_000 && BrowserLimits.waitMaxTimeoutMs == 300_000)
        #expect(BrowserLimits.waitIdleQuietMs == 500 && BrowserLimits.waitDefaultPollMs == 250 && BrowserLimits.waitMinPollMs == 50)
        #expect(BrowserLimits.assertCheckBudgetMs == 1_000 && BrowserLimits.refCapacity == 1_000 && BrowserLimits.consoleCapacity == 200)
    }
}

/// Ranking `read-page`'s elements against a plain-language description.
@Suite struct FindElementsTests {
    private func element(_ name: String, ref: String = "e1", role: String = "button", tag: String = "button") -> PageElement {
        PageElement(ref: ref, role: role, name: name, tag: tag)
    }

    @Test func ranksAnExactNameAboveAPrefixAPrefixAboveASubstring() {
        let exact = scoreElement(element("Save"), description: "Save")
        let prefix = scoreElement(element("Save changes"), description: "Save")
        let substring = scoreElement(element("Autosave draft"), description: "save")
        #expect(exact > prefix)
        #expect(prefix > substring)
        #expect(substring > 0)
    }

    @Test func isCaseAndWhitespaceInsensitive() {
        #expect(scoreElement(element("  SAVE   CHANGES "), description: "save changes") == 1)
    }

    @Test func scoresAPartialTokenOverlapBelowAnyDirectSubstringMatch() {
        let tokens = scoreElement(element("Submit the order form"), description: "submit form")
        let substring = scoreElement(element("Autosave draft"), description: "save")
        #expect(tokens > 0)
        #expect(tokens < substring)
    }

    @Test func ignoresStopWordsRatherThanLettingThemMatchEverything() {
        #expect(scoreElement(element("Delete account"), description: "the") == 0)
    }

    @Test func returns0ForAnElementSharingNothingWithTheDescription() {
        #expect(scoreElement(element("Delete account"), description: "newsletter signup") == 0)
    }

    @Test func letsANamedRoleCorroborateAMatchButNeverCreateOne() {
        let corroborated = scoreElement(element("Save", role: "button"), description: "save button")
        let roleOnly = scoreElement(element("Delete", role: "button"), description: "button")
        #expect(corroborated > 0)
        // Naming only the role matches nothing: otherwise "button" would return every button on the page.
        #expect(roleOnly == 0)
    }

    @Test func scoresAnEmptyDescriptionAsNoMatchAtAll() {
        #expect(scoreElement(element("Save"), description: "   ") == 0)
    }

    private var elements: [PageElement] {
        [
            element("Cancel", ref: "e1"), element("Save changes", ref: "e2"), element("Save", ref: "e3"),
            element("Delete account", ref: "e4"),
        ]
    }

    @Test func returnsMatchesStrongestFirstAndDropsNonMatches() {
        let matches = findElements(elements, description: "save")
        #expect(matches.map(\.element.ref) == ["e3", "e2"])
        #expect(matches[0].score > matches[1].score)
    }

    @Test func capsTheResultCount() {
        #expect(findElements(elements, description: "save", maxResults: 1).count == 1)
        #expect(findElements(elements, description: "save", maxResults: 0).isEmpty)
    }

    @Test func returnsNothingRatherThanAWeakGuessWhenNothingMatches() {
        #expect(findElements(elements, description: "checkout basket").isEmpty)
    }

    @Test func equalScoresKeepPageOrder() {
        let same = [element("Save", ref: "e1"), element("Save", ref: "e2"), element("Save", ref: "e3")]
        #expect(findElements(same, description: "save").map(\.element.ref) == ["e1", "e2", "e3"])
    }
}

/// H-16: the wire of the log the console shares with any capture buffer.
@MainActor
@Suite struct RingLogTests {
    private struct Entry: Sequenced {
        var seq = 0
        var text: String
    }

    private final class Boxed: Sequenced {
        var seq = 0
        var text: String
        init(_ text: String) { self.text = text }
    }

    @Test func assignsIncreasingSequenceNumbersFrom1() {
        let log = RingLog<Entry>(capacity: 10)
        #expect(log.add(Entry(text: "a")).seq == 1)
        #expect(log.add(Entry(text: "b")).seq == 2)
    }

    @Test func evictsTheOldestEntriesOnceCapacityIsExceeded() {
        let log = RingLog<Entry>(capacity: 3)
        for text in ["a", "b", "c", "d", "e"] { log.add(Entry(text: text)) }
        #expect(log.list().map(\.text) == ["c", "d", "e"])
    }

    @Test func keepsSequenceNumbersStableAcrossEvictionSoSinceSeqStaysCorrect() {
        let log = RingLog<Entry>(capacity: 2)
        log.add(Entry(text: "a"))
        log.add(Entry(text: "b"))
        let third = log.add(Entry(text: "c"))
        // "a" is gone, but "c" is still seq 3: a caller that had read up to 2 gets
        // exactly what it hasn't seen, not a replay.
        #expect(third.seq == 3)
        #expect(log.list(sinceSeq: 2).map(\.text) == ["c"])
    }

    @Test func returnsEntriesStrictlyAfterSinceSeq() {
        let log = RingLog<Entry>(capacity: 10)
        for text in ["a", "b", "c"] { log.add(Entry(text: text)) }
        #expect(log.list(sinceSeq: 0).map(\.text) == ["a", "b", "c"])
        #expect(log.list(sinceSeq: 2).map(\.text) == ["c"])
        #expect(log.list(sinceSeq: 3).isEmpty)
    }

    @Test func doesNotRewindSequenceNumbersOnClearSoAStaleSinceSeqCannotReplay() {
        let log = RingLog<Entry>(capacity: 10)
        log.add(Entry(text: "old page"))
        log.add(Entry(text: "old page 2"))
        log.clear()
        let fresh = log.add(Entry(text: "new page"))
        #expect(log.list().count == 1)
        #expect(fresh.seq == 3)
        #expect(log.list(sinceSeq: 2).map(\.text) == ["new page"])
    }

    @Test func removesAnEntryBySeqReportingWhetherItWasPresent() {
        let log = RingLog<Entry>(capacity: 10)
        log.add(Entry(text: "a"))
        let b = log.add(Entry(text: "b"))
        log.add(Entry(text: "c"))
        #expect(log.remove(seq: b.seq))
        #expect(log.list().map(\.text) == ["a", "c"])
        // Already gone: a second remove reports that rather than throwing.
        #expect(!log.remove(seq: b.seq))
    }

    @Test func reportsAnEvictedEntryAsAbsentFromRemoveAndNeverReusesItsSeq() {
        let log = RingLog<Entry>(capacity: 2)
        let a = log.add(Entry(text: "a"))
        log.add(Entry(text: "b"))
        log.add(Entry(text: "c"))
        #expect(!log.remove(seq: a.seq))
        #expect(log.add(Entry(text: "d")).seq == 4)
    }

    @Test func handsBackTheStoredObjectSoAnInFlightEntryCanBeCompletedLater() {
        let log = RingLog<Boxed>(capacity: 10)
        let entry = log.add(Boxed("pending"))
        entry.text = "done"
        #expect(log.list()[0].text == "done")
    }

    @Test func compilePatternMatchesEverythingWhenNoPatternIsGiven() {
        #expect(compilePattern(nil)("anything"))
        #expect(compilePattern("")("anything"))
    }

    @Test func compilePatternTreatsThePatternAsARegularExpression() {
        let matches = compilePattern("^GET")
        #expect(matches("GET /api/users"))
        #expect(!matches("POST /api/users"))
        // A JavaScript regular expression, not ICU's: a named group, a lookbehind.
        #expect(compilePattern("(?<=a)b")("ab"))
        #expect(compilePattern(#"\d{3}"#)("x123"))
    }

    @Test func patternFilterErrorIsNilForAValidPatternAndForNoPatternAtAll() {
        #expect(patternFilterError("^GET") == nil)
        #expect(patternFilterError(nil) == nil)
        #expect(patternFilterError("") == nil)
    }

    @Test func patternFilterErrorNamesTheParseFailureForAnUnterminatedCharacterClass() throws {
        let error = try #require(patternFilterError("["))
        #expect(error.contains("--pattern"))
        #expect(error.contains("["))
        // The engine's own reason, not a generic "invalid pattern".
        #expect(error.lowercased().contains("character class"), "\(error)")
    }
}
