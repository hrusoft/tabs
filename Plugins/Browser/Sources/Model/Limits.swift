import Foundation
import TabsPluginSDK

/// The browser's caps, waits and guest-global names. Every number the verbs'
/// docs state comes from here.
enum BrowserLimits {
    /// Caps that keep a response from blowing up the caller's context. Page text
    /// is truncated (always reported via `truncated: true`, never silently), and a
    /// caller's own `maxLength` can lower the default but not raise it past the
    /// hard cap.
    static let defaultPageTextMax = 50_000
    static let pageTextHardMax = 200_000

    /// Cap on an `execute-js` result, measured on its serialized form. Past this
    /// the value comes back as a truncated JSON *string* with `truncated: true`.
    /// The opt-out for a result genuinely needed in full is `--out`.
    static let executeResultMax = 50_000

    /// Cap on the bytes a single `save-resource` will write, checked before the
    /// file is created: a runaway artifact (a video mistaken for the target) is
    /// refused with an error naming its size and this cap.
    static let maxResourceBytes = 50 * 1024 * 1024

    /// How long a verb waits on a page: `loadWaitMs` for a navigation to settle
    /// before answering `loaded: false`, plus `mountWaitMs` before that for
    /// `create-browser-pane`, which first waits for the new pane's page to mount.
    static let loadWaitMs = 15_000
    static let mountWaitMs = 5_000
    /// How long a navigation verb watches a page that finished loading for a
    /// navigation it starts itself (`BrowserPage.waitForLoadSettle`). A redirect
    /// from script during parse, from the load event, or a zero-delay meta
    /// refresh starts within a few milliseconds of the load ending; one timed
    /// later than this is after the answer.
    static let redirectQuietMs = 150

    /// How long an input verb waits for the page to acknowledge what it sent
    /// (`PageInput.settle`): for as long as the page keeps acknowledging, giving
    /// up once it has acknowledged nothing new for `inputQuietMs` (a page that
    /// can't say, an event swallowed, text no field took). Each read of the
    /// page's counters gets `inputReadMs` before the page counts as unable to
    /// say (busy in a script of its own).
    static let inputQuietMs = 500
    static let inputReadMs = 2_000

    /// `wait-for`'s bounds. The default is deliberately above "a couple of
    /// seconds": a wrong condition costing 10s is cheaper than the caller's retry
    /// round trip. A request may lower the wait to zero (one immediate check) but
    /// never raise it past the ceiling.
    static let waitDefaultTimeoutMs = 10_000
    static let waitMaxTimeoutMs = 300_000

    /// How long the DOM must stay mutation-free for `--idle` to resolve, and the
    /// quiet period behind the read verbs' `settled` field: the same measurement
    /// of the same tracker.
    static let waitIdleQuietMs = 500

    /// The in-guest fallback check interval, and the floor that keeps a caller's
    /// `pollMs` from turning the guest's mutation bursts into a busy-loop.
    static let waitDefaultPollMs = 250
    static let waitMinPollMs = 50

    /// How long an `assert`'s check may take end to end (not a caller wait: the
    /// in-guest check runs synchronously on injection). A condition that arrives
    /// within this window passes: "holds now", measured to this tolerance.
    static let assertCheckBudgetMs = 1_000

    /// The guest-global names the ref registry lives under: names of globals in
    /// the page's main world, not code that runs here. `save-resource` resolves a
    /// `--ref` to an element's `src` through the same registry.
    static let refRegistry = "__tabsPageRefs"
    static let refCounter = "__tabsPageRefSeq"
    /// The per-document tag every ref carries.
    static let refDocument = "__tabsPageRefDoc"
    /// Refs retained per page before the oldest start dropping (a dropped ref
    /// fails like a stale one).
    static let refCapacity = 1000

    /// The console buffer's size: messages retained per pane.
    static let consoleCapacity = 200
}

/// The one wait arithmetic, used by *both* ends: the wait runs on exactly this
/// number, and the verb's budget is this number plus headroom, which is what
/// makes "the deadline always outlives the wait" hold per request rather than
/// per verb. Anything non-numeric (untyped wire input) falls back to the
/// default rather than the ceiling.
func clampWaitTimeout(_ requested: JSONValue?) -> Int {
    guard let value = requested?.doubleValue, value.isFinite else { return BrowserLimits.waitDefaultTimeoutMs }
    return Int(min(Double(BrowserLimits.waitMaxTimeoutMs), max(0, value.rounded())))
}

/// `clampWaitTimeout`'s twin for the poll interval.
func clampWaitPoll(_ requested: JSONValue?) -> Int {
    guard let value = requested?.doubleValue, value.isFinite else { return BrowserLimits.waitDefaultPollMs }
    return Int(max(Double(BrowserLimits.waitMinPollMs), value.rounded()))
}

/// The guest expression resolving a `read-page` ref to its element, or null for
/// a ref the current page doesn't know — most often because it navigated since,
/// which drops the registry along with the rest of the old document's globals.
///
/// The single spelling of the read, for the reason it is shared: two spellings
/// could disagree about a ref the registry no longer holds. The ref-shaped
/// instance of `hitTestPointScript`'s resolver contract: an expression
/// evaluating to `Element | null | { error: string }`.
func refResolverExpression(_ ref: String) -> String {
    "((window.\(BrowserLimits.refRegistry) instanceof Map ? window.\(BrowserLimits.refRegistry).get(\(jsonQuoted(ref))) : null) ?? null)"
}

/// The answer for a ref the current page doesn't hold — one wording everywhere,
/// because its remedy is an instruction an agent acts on, and two phrasings
/// would teach two recoveries for one state.
func staleRefError(_ ref: String) -> String {
    "no element for ref \(ref) — refs are only valid until the page navigates (a ref from an earlier page never names anything on a later one), so call readPage again"
}

/// A browser pane that exists but has no live page right now (not mounted).
let paneNotMountedError = "browser pane is not currently mounted"
