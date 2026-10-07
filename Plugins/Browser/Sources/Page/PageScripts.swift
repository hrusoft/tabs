import Foundation
import TabsPluginSDK

// The JavaScript the browser evaluates inside a page. It is standard DOM (the
// refs, roles and names, visibility, hit test, fill, scroll), and so
// engine-neutral; only the wrapping is Swift.
//
// Scripts are plain source strings rather than closures because there is no shared
// realm to pass a closure into: the page is a different process running a
// different document. Two things follow, both deliberate:
//
// - **They run in the page's own main world.** A hostile page can observe or
//   redefine anything these touch, and the ref registry has to live where the
//   page's own globals do so a later script finds it. Nothing here is a security
//   boundary; the boundary is pane ownership.
// - **Only JSON-serializable values can come back.** A DOM node can't cross,
//   which is why `readPageScript` returns opaque refs and keeps the actual
//   elements in a map on the page side (`BrowserLimits.refRegistry`) for a later
//   input verb to resolve.

/// Where the persistent DOM-activity tracker lives: a pair of timestamps
/// (`installedAt`, and `lastAt` for the most recent mutation) stamped by a
/// MutationObserver that is installed on first use and stays for the document's
/// lifetime (navigation drops it with the rest of the page's globals, like the ref
/// registry). One tracker serves two consumers: the read verbs' `settled` field is
/// computed from these timestamps at read time, and `wait-for --idle` polls them
/// until the quiet period holds (`domIdleScript`): a single definition of "the DOM
/// is quiet", not two clocks that could disagree.
private let domActivity = "__tabsDomActivity"

/// Elements worth reporting: everything interactive, plus headings for orientation.
private let candidateSelector = [
    "a[href]", "button", "input", "select", "textarea", "summary", "[role]", "[onclick]", "[tabindex]", "[contenteditable=\"true\"]",
    "h1", "h2", "h3", "h4", "h5", "h6",
].joined(separator: ",")

/// Response-size discipline: a caller's context is the real budget here, not memory.
private let maxElements = 200
private let maxNameLength = 120

/// Candidates listed in an ambiguous-match error before "and N more" truncates the rest.
private let ambiguityListMax = 10

/// Where `find` parks the elements it described, between describing them and
/// minting refs for the few it returns (`findCandidatesScript`): a page global
/// like the ref registry, so it dies with the document it points into.
private let findPool = "__tabsFindPool"

/// Input types a text fill is meaningless for: their value is not text a user
/// would enter (a checkbox's is its submit token, a button's is its label), so
/// writing to it would report success while changing nothing the caller meant to
/// change. `file` is here too (it can't be set at all), and each gets a loud
/// `unfillable` outcome pointing at `click` instead.
private let unfillableInputTypes = ["checkbox", "radio", "button", "submit", "reset", "image", "file"]

/// A value as a JavaScript literal (JSON is one).
func jsLiteral(_ value: JSONValue) -> String {
    (try? value.encodedData(pretty: false)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
}

/// A number as a JavaScript literal (`Number(x)`): integral values without a fraction.
func jsNumber(_ value: Double) -> String {
    guard value.isFinite else { return "NaN" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
}

/// Guest-side fragment ensuring the tracker exists, leaving it in scope as
/// `activity`. Idempotent per document: a second run finds the global and attaches
/// nothing, so repeated reads never restart the observation window: which is
/// exactly what lets a *re*-read report `settled: true`.
let ensureDomActivityJS = #"""
      const existing = window.\#(domActivity)
      const activity =
        existing && typeof existing.installedAt === 'number' && typeof existing.lastAt === 'number'
          ? existing
          : (() => {
              const created = { installedAt: Date.now(), lastAt: 0 }
              new MutationObserver(() => {
                created.lastAt = Date.now()
              }).observe(document.documentElement ?? document, {
                subtree: true,
                childList: true,
                characterData: true,
                attributes: true
              })
              window.\#(domActivity) = created
              return created
            })()
    """#

/// Defines `readiness()`, the `{ readyState, settled }` pair every read verb folds
/// into its result. `settled` is "no observed mutation in the last
/// `waitIdleQuietMs`", measured from `max(installedAt, lastAt)`, so a page that has
/// only just come under observation cannot certify quiet: the first read of any
/// page reports `settled: false` by construction, and a later read is the one that
/// can vouch for it. That is the honest direction: the field exists to tell a
/// caller "read again", never to promise stillness it never watched.
private let readinessJS = #"""
      \#(ensureDomActivityJS)
      const readiness = () => ({
        readyState: document.readyState,
        settled: Date.now() - Math.max(activity.installedAt, activity.lastAt) >= \#(BrowserLimits.waitIdleQuietMs)
      })
    """#

/// Defines `documentShape()`, `{ frames, shadowRoots }`: always-present integers (0
/// included) reported alongside every read, so an agent learns the fields exist
/// rather than only noticing them once they matter. Both count what the read verbs
/// cannot otherwise hint at: content one level below the top document that
/// `querySelectorAll`/`innerText` structurally never reach, so an unexpectedly empty
/// result next to a nonzero count is the caller's cue that the content may live
/// there rather than not existing.
///
/// `frames` counts `<iframe>`/`<frame>` elements in the top document. `shadowRoots`
/// counts only **open** shadow roots (a closed one returns `null` from
/// `el.shadowRoot` and is invisible to page script by design), and only top-level
/// shadow hosts: one level down is the case that bites (a widget library's host
/// element), and the caller has `execute-js` for anything deeper.
private let documentShapeJS = #"""
      const documentShape = () => {
        // Counted in a loop rather than Array.from(...).filter(...).length: the
        // walk is inherent to the count, materializing the whole document as an
        // array is not — and this runs on every read verb, on pages with tens of
        // thousands of elements.
        let shadowRoots = 0
        for (const el of document.querySelectorAll('*')) if (el.shadowRoot) shadowRoots++
        return { frames: document.querySelectorAll('iframe, frame').length, shadowRoots }
      }
    """#

/// Guest-side fragment defining `isVisible(el)`: "the page actually shows this": a
/// non-empty box, not `visibility: hidden`, not `display: none`.
///
/// One definition rather than an inlined copy per script, because three verbs
/// *promise* to agree on it: `read-page` lists what it says is visible, a semantic
/// `click` filters its candidate pool by it (so a hidden mobile-nav duplicate can't
/// make every visible control ambiguous), and `wait-for --selector` resolves on it.
/// Nothing typechecks a JS source string, so a fourth spelling would silently let
/// `wait-for` resolve on an element `read-page` won't list.
let visibleElementJS = #"""
      const visibleRect = (el) => {
        const rect = el.getBoundingClientRect()
        if (rect.width <= 0 || rect.height <= 0) return null
        const style = getComputedStyle(el)
        return style.visibility !== 'hidden' && style.display !== 'none' ? rect : null
      }
      const isVisible = (el) => visibleRect(el) !== null
    """#

/// Guest-side fragment defining `mintRef(el)` and `roundRect(rect)`: the ref
/// registry's write discipline, next to the constants it writes through.
/// `roundRect` takes an already-measured rect rather than the element, so a caller
/// that has one in hand doesn't pay a second layout read for it.
///
/// The registry's global *names* are shared (`BrowserLimits`) so a second spelling
/// can't open a ref namespace that never resolves; this shares the *discipline*
/// around them for the same reason one level up. `read-page`, `find` and `wait-for
/// --selector` all mint refs, and a change to the counter semantics, the ref format
/// or the eviction order that reached only one would surface as refs mysteriously
/// failing to resolve rather than as an error.
///
/// **A ref names its document**, `e<n>-<tag>`, the tag minted once per document. The
/// counter lives in the page's globals, so it restarts with every document: and
/// refs used to be bare `e<n>`: after a navigation and a fresh `read-page`, a ref an
/// agent still held from the old page resolved to whatever the new page had minted
/// under the same number, a silent rebind the skill promises never happens. A ref
/// from another document now carries another tag, so it is simply not in this
/// registry and fails as stale. The tag is random rather than a count because
/// nothing outside the document can number documents reliably. `getRandomValues`
/// rather than `randomUUID`: the latter exists only in secure contexts, and
/// plain-http pages are exactly what agents drive.
let mintRefJS = #"""
      const mintRef = (el) => {
        const registry = window.\#(BrowserLimits.refRegistry) instanceof Map ? window.\#(BrowserLimits.refRegistry) : new Map()
        window.\#(BrowserLimits.refRegistry) = registry
        let documentTag = window.\#(BrowserLimits.refDocument)
        if (typeof documentTag !== 'string' || documentTag === '') {
          const bytes = new Uint8Array(5)
          try {
            crypto.getRandomValues(bytes)
          } catch {
            for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
          }
          documentTag = Array.from(bytes, (byte) => (byte % 36).toString(36)).join('')
          window.\#(BrowserLimits.refDocument) = documentTag
        }
        const base = typeof window.\#(BrowserLimits.refCounter) === 'number' ? window.\#(BrowserLimits.refCounter) : 0
        const ref = 'e' + (base + 1) + '-' + documentTag
        window.\#(BrowserLimits.refCounter) = base + 1
        registry.set(ref, el)
        while (registry.size > \#(BrowserLimits.refCapacity)) registry.delete(registry.keys().next().value)
        return ref
      }

      const roundRect = (rect) => ({
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      })
    """#

/// Guest-side helper definitions shared by every script that describes an element:
/// `roleFor`/`nameFor` (the pragmatic accessible-name approximation documented on
/// `readPageScript`) plus `describeEl`, the `{role, name, tag}` shape `click`
/// reports a hit in: the same vocabulary `read-page` speaks, so a caller can compare
/// the two directly.
let describeElementJS = #"""
      const roleFor = (el) => {
        const explicit = el.getAttribute('role')
        if (explicit) return explicit
        const tag = el.tagName.toLowerCase()
        if (tag === 'a') return 'link'
        if (tag === 'button' || tag === 'summary') return 'button'
        if (tag === 'select') return 'combobox'
        if (tag === 'textarea') return 'textbox'
        if (/^h[1-6]$/.test(tag)) return 'heading'
        // HTML-AAM: an image with alt="" and no label is decoration, any other an image.
        if (tag === 'img') {
          const unlabelled = !el.hasAttribute('aria-label') && !el.hasAttribute('aria-labelledby')
          return el.getAttribute('alt') === '' && unlabelled ? 'presentation' : 'img'
        }
        if (tag === 'input') {
          const type = (el.getAttribute('type') || 'text').toLowerCase()
          if (type === 'checkbox') return 'checkbox'
          if (type === 'radio') return 'radio'
          if (type === 'submit' || type === 'button' || type === 'reset') return 'button'
          if (type === 'range') return 'slider'
          return 'textbox'
        }
        return 'generic'
      }

      // The text a label (or an aria-labelledby target) contributes to the name
      // of `self`. Not plain textContent, which for a label wrapped around a
      // <select> is every option run together ("Colour RedGreenBlue"). The
      // accessible-name rule, checked against Chromium's own computation: the
      // control being named contributes nothing to its own name ("Colour"), and
      // any *other* control embedded in the label contributes its current value
      // — a select its chosen option, a text field its text ("Qty of kg" for
      // <label>Qty <input> of <select>kg</select></label>, naming the input).
      // Spaces around each value keep it from fusing with the text beside it;
      // text nodes are otherwise joined as textContent joins them.
      const labelText = (container, self) => {
        let text = ''
        const walk = (node) => {
          for (const child of node.childNodes) {
            if (child.nodeType === 3) {
              text += child.textContent || ''
              continue
            }
            if (child.nodeType !== 1 || child === self) continue
            const tag = child.tagName
            if (tag === 'SCRIPT' || tag === 'STYLE') continue
            if (tag === 'SELECT') {
              const chosen = child.selectedOptions && child.selectedOptions[0]
              text += ' ' + (chosen ? chosen.label || chosen.textContent || '' : '') + ' '
              continue
            }
            if (tag === 'TEXTAREA' || (tag === 'INPUT' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden'].includes((child.getAttribute('type') || 'text').toLowerCase()))) {
              text += ' ' + (child.value || '') + ' '
              continue
            }
            if (tag === 'INPUT') continue
            walk(child)
          }
        }
        walk(container)
        return text
      }

      const nameFor = (el) => {
        const aria = el.getAttribute('aria-label')
        if (aria && aria.trim()) return aria
        const labelledBy = el.getAttribute('aria-labelledby')
        if (labelledBy) {
          const text = labelledBy.split(/\s+/)
            .map((id) => {
              const target = document.getElementById(id)
              return target ? labelText(target, el) : ''
            })
            .join(' ').trim()
          if (text) return text
        }
        if (el.labels && el.labels.length) {
          const text = Array.from(el.labels).map((l) => labelText(l, el)).join(' ').trim()
          if (text) return text
        }
        for (const attr of ['title', 'placeholder', 'alt', 'name']) {
          const value = el.getAttribute(attr)
          if (value && value.trim()) return value
        }
        // A select's content is its option list, never its name — an unlabelled
        // one was named "Alpha Beta" for its two options, where Chromium names it
        // nothing. Its chosen option is what read-page's value reports.
        if (el.tagName === 'SELECT') return ''
        return (el.innerText || el.textContent || '').trim()
      }

      // Whether a checkbox-like control is on: true, false, or 'mixed' for an
      // indeterminate one — undefined for anything that isn't checkable. A
      // native checkbox/radio answers from its live state (its HTML value
      // attribute, which read-page used to report as "on", says nothing about
      // that); an ARIA one (role checkbox/switch/radio/menuitemcheckbox) from
      // aria-checked.
      const checkedStateOf = (el) => {
        if (el.tagName === 'INPUT') {
          const type = (el.getAttribute('type') || 'text').toLowerCase()
          if (type === 'checkbox' || type === 'radio') return el.indeterminate ? 'mixed' : el.checked
        }
        const aria = el.getAttribute('aria-checked')
        if (aria === 'true') return true
        if (aria === 'false') return false
        if (aria === 'mixed') return 'mixed'
        return undefined
      }

      const describeEl = (el) => ({
        role: roleFor(el),
        name: nameFor(el).replace(/\s+/g, ' ').slice(0, \#(maxNameLength)),
        tag: el.tagName.toLowerCase()
      })
    """#

/// Guest-side fragment defining `candidatePool(selector, role)` and `roleMatcher(role)`:
/// the two narrowing rules `read-page` and a semantic `click`/`hover` *promise* to
/// share, for the same reason `visibleElementJS` is one fragment rather than a copy
/// per script. The skill tells an agent to discover a control with `read-page --role
/// X --selector Y` and then act on it with `click --role X --selector Y`; if those
/// two spelled the pool or the role comparison separately they would agree only by
/// coincidence.
///
/// `candidatePool` answers `{ error }` instead of an array for a selector the page
/// rejects, matching the resolver contract the callers already speak; test it with
/// `Array.isArray`. It depends on `roleFor` from `describeElementJS`.
let candidatePoolJS = #"""
      // The selector *replaces* the candidate set rather than filtering it — the
      // interactive-and-headings default is a guess at what matters, and a caller
      // naming a selector has a better one (an <img>, a table row, a card
      // container), none of which the default would ever have listed. Images
      // aren't in the default either (they aren't controls, and a page of them
      // would crowd the controls out of a read), but a caller asking for one by
      // role has said it wants them.
      const candidatePool = (selector, role) => {
        const imageRole = ['img', 'presentation', 'none'].includes(String(role ?? '').toLowerCase())
        try {
          return Array.from(document.querySelectorAll(selector ?? \#(jsonQuoted(candidateSelector)) + (imageRole ? ',img' : '')))
        } catch {
          return { error: 'invalid selector: ' + selector }
        }
      }

      // 'none' and 'presentation' are one role under two names (WAI-ARIA).
      const canonicalRole = (role) => {
        const lower = String(role).toLowerCase()
        return lower === 'none' ? 'presentation' : lower
      }

      // Role is a *hard* filter on both sides: a read that quietly widened would
      // hand back elements the caller then has to re-filter, having been told it
      // hadn't to, and a click that widened would click across roles. Returns null
      // for "no role asked for", i.e. keep everything.
      const roleMatcher = (role) => {
        if (role === undefined || role === null) return null
        const wanted = canonicalRole(role)
        return (el) => canonicalRole(roleFor(el)) === wanted
      }
    """#

/// How a `read-page` call narrows what it extracts. Every field is optional; none
/// is the default.
struct ReadPageFilter: Equatable {
    /// Widens or narrows the candidate pool to any element matching this CSS selector.
    var selector: String?
    /// Keeps only candidates whose derived role matches, compared case-insensitively.
    var role: String?
    /// How many matching candidates to skip before the page of 200 returned.
    var offset: Int?

    init(selector: String? = nil, role: String? = nil, offset: Int? = nil) {
        self.selector = selector
        self.role = role
        self.offset = offset
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let selector { object["selector"] = .string(selector) }
        if let role { object["role"] = .string(role) }
        if let offset { object["offset"] = .int(Int64(offset)) }
        return .object(object)
    }
}

/// Extracts a structured, ref-addressable view of the page: role, accessible name,
/// tag and viewport rect per element. The accessible-name derivation is a pragmatic
/// approximation of the real accessible-name algorithm (aria-label → aria-labelledby
/// → associated <label> → title/placeholder/alt/name → visible text), not a
/// spec-complete implementation.
///
/// Two rules make the narrowing worth having.
///
/// **The slice happens before minting**, so skipping a page costs no refs: the
/// registry holds `refCapacity` entries and paging a large document would otherwise
/// evict the very refs the caller is walking toward. (Past 1000 elements it evicts
/// anyway: the caller's cue is `total`, which is why that is reported rather than
/// left to be inferred from `truncated`.)
///
/// **`truncated` means "there are more after this page"**, not "more than fit":
/// with no offset the two are the same claim, and with an offset it stays the
/// actionable one (raise `--offset`). What it deliberately does *not* say is that
/// elements were skipped *before* the page: that is what `offset` itself reports.
func readPageScript(_ filter: ReadPageFilter) -> String {
    let filter = filter.json
    return #"""
        (() => {
          \#(describeElementJS)
          \#(visibleElementJS)
          \#(candidatePoolJS)
          \#(mintRefJS)
          \#(readinessJS)
          \#(documentShapeJS)
          const criteria = \#(jsLiteral(filter))
          const pool = candidatePool(criteria.selector, criteria.role)
          if (!Array.isArray(pool)) return pool
          const matchesRole = roleMatcher(criteria.role)
          const visible = []
          for (const el of pool) {
            // The rect measured by the visibility check is the one reported, so a
            // candidate is only ever laid out once.
            const rect = visibleRect(el)
            if (!rect) continue
            if (matchesRole !== null && !matchesRole(el)) continue
            visible.push([el, rect])
          }

          const offset = typeof criteria.offset === 'number' ? criteria.offset : 0
          const elements = visible.slice(offset, offset + \#(maxElements)).map(([el, rect]) => {
            const checked = checkedStateOf(el)
            // A checkbox or radio's value is its submit token ("on" unless set), not
            // anything about its state — `checked` is what reports that.
            const value = typeof el.value === 'string' && checked === undefined ? el.value : undefined
            const element = {
              ref: mintRef(el),
              ...describeEl(el),
              rect: roundRect(rect)
            }
            if (value) element.value = value.slice(0, \#(maxNameLength))
            if (checked !== undefined) element.checked = checked
            return element
          })

          return {
            elements,
            total: visible.length,
            offset,
            truncated: offset + elements.length < visible.length,
            ...readiness(),
            ...documentShape()
          }
        })()
        """#
}

/// `find`'s first half: the candidates `read-page` would list with no filter (the
/// same pool, the same visibility rule, the same first 200), each described (role,
/// name, tag, rect) but **without a ref**.
///
/// `find` used to run `read-page`'s own extraction, which mints a ref for every
/// element it describes: one call that returned a single match spent up to 200 refs
/// (measured: two finds with one match between them advanced the counter from e34
/// to e70), and the registry is bounded, so every find evicted refs a caller was
/// still holding. Ranking needs names, not refs, so the elements are kept page-side
/// under `token` and only the ones the ranking returns get refs, in
/// `mintFindRefsScript`.
func findCandidatesScript(token: String) -> String {
    #"""
    (() => {
      \#(describeElementJS)
      \#(visibleElementJS)
      \#(candidatePoolJS)
      \#(mintRefJS)
      \#(readinessJS)
      \#(documentShapeJS)
      const pool = candidatePool(undefined)
      const kept = []
      for (const el of pool) {
        const rect = visibleRect(el)
        if (!rect) continue
        kept.push([el, rect])
        if (kept.length === \#(maxElements)) break
      }
      window.\#(findPool) = { token: \#(jsonQuoted(token)), elements: kept.map(([el]) => el) }
      return {
        candidates: kept.map(([el, rect]) => ({ ...describeEl(el), rect: roundRect(rect) })),
        ...readiness(),
        ...documentShape()
      }
    })()
    """#
}

/// `find`'s second half: refs for the candidates at `indices`, in that order, minted
/// through the same `mintRefJS` discipline `read-page` uses. An element that left the
/// document between the two halves gets `null` rather than a ref that could only
/// ever fail as stale; a pool from some other find (or a page that navigated in
/// between, taking the pool with it) is refused.
func mintFindRefsScript(token: String, indices: [Int]) -> String {
    #"""
    (() => {
      \#(mintRefJS)
      const stash = window.\#(findPool)
      if (!stash || stash.token !== \#(jsonQuoted(token))) {
        return { error: 'the page changed while find was ranking it — run find again' }
      }
      delete window.\#(findPool)
      return {
        refs: \#(jsLiteral(.array(indices.map { .int(Int64($0)) }))).map((index) => {
          const el = stash.elements[index]
          return el && el.isConnected ? mintRef(el) : null
        })
      }
    })()
    """#
}

/// `get-page-text`'s extraction: innerText rather than textContent because it
/// reflects what's actually rendered (no <script>/<style> bodies, collapsed
/// whitespace, line breaks where the layout puts them), which is what a caller
/// reading a page wants. Length limiting stays host-side, where the shared caps
/// live. Carries the same readiness pair as `read-page`, from the same tracker.
let pageTextScript = #"""
    (() => {
      \#(readinessJS)
      \#(documentShapeJS)
      return {
        text: (document.body ?? document.documentElement)?.innerText ?? '',
        ...readiness(),
        ...documentShape()
      }
    })()
    """#

/// A semantic target's criteria as prose: `role="button" name="Save"`: used as the
/// label in every error the resolver can produce, and by the host for the
/// hit-mismatch error, so both ends name the target the same way.
func describeSemanticTarget(_ target: SemanticTarget) -> String {
    var parts: [String] = []
    if let role = target.role { parts.append("role=\(jsonQuoted(role))") }
    if let name = target.name { parts.append("name=\(jsonQuoted(name))") }
    if let selector = target.selector { parts.append("selector=\(jsonQuoted(selector))") }
    return parts.joined(separator: " ")
}

/// The semantic-shaped instance of the resolver contract `refResolverExpression`
/// documents: a page expression evaluating to `Element | null | { error }`, for
/// interpolation into a script that supplies `describeElementJS`
/// (`hitTestPointScript`, `elementRectScript` or `focusTargetScript`) because it
/// calls `roleFor`/`nameFor`/`describeEl` from that scope. It brings its own
/// `visibleElementJS` and `candidatePoolJS`, scoped to its own IIFE.
///
/// Matching (decided, not incidental): the selector defines the pool and `role`
/// hard-filters it, both through the same fragment `read-page` uses; visibility
/// filters it with `read-page`'s exact predicate (literally the same fragments, so
/// the two cannot drift), so a hidden mobile-nav duplicate can't make every visible
/// control ambiguous; and `name` walks the strictness ladder (exact,
/// case-insensitive exact, case-insensitive substring, whitespace-normalized
/// throughout) taking the strictest non-empty tier, so an exact name is never
/// ambiguous merely because it prefixes a longer one. Ambiguity within that tier
/// *fails*, listing the candidates with the 0-based indices `nth` indexes into;
/// guessing the first match would reintroduce exactly the wrong-target class this
/// form exists to remove. The caller pre-validates shape (at least one criterion,
/// `nth` a non-negative integer), so the page only ever reports match outcomes.
///
/// `role` stays a **hard** filter: it never falls back to a looser match on its own,
/// because silently clicking across roles is exactly the guessing this form exists
/// to remove (non-semantic markup, where a click target is a `<div>` with an
/// ARIA-derived role like "group" rather than a real `button`, is the norm on real
/// sites, not the exception). What it gets instead is a *diagnosis*: when role+name
/// together match nothing, the same name ladder re-runs against the
/// visibility-filtered pool with the role filter lifted, in this same page pass: no
/// extra round trip. A hit there means the name is right and only the role was too
/// strict, so the error says exactly that (naming the role(s) actually found)
/// instead of the generic no-match message.
func semanticResolverExpression(_ target: SemanticTarget) -> String {
    var object: [String: JSONValue] = [:]
    if let role = target.role { object["role"] = .string(role) }
    if let name = target.name { object["name"] = .string(name) }
    if let selector = target.selector { object["selector"] = .string(selector) }
    if let nth = target.nth { object["nth"] = .int(Int64(nth)) }
    let criteria = JSONValue.object(object)
    return #"""
        (() => {
            \#(visibleElementJS)
            \#(candidatePoolJS)
            const criteria = \#(jsLiteral(criteria))
            const label = \#(jsonQuoted(describeSemanticTarget(target)))
            const pool = candidatePool(criteria.selector, criteria.role)
            if (!Array.isArray(pool)) return pool
            const visible = pool.filter(isVisible)
            const collapse = (text) => text.replace(/\s+/g, ' ').trim()
            // Applies the name ladder to whatever candidate set is passed in — used
            // both for the real match (against the role-filtered set) and, on a
            // role+name miss, for the near-miss diagnosis (against the full visible
            // pool, role filter lifted) — one ladder, so the two can never disagree
            // about what "matches the name" means.
            const nameTiered = (candidates) => {
              if (criteria.name === undefined) return candidates
              const wanted = collapse(String(criteria.name))
              const wantedLower = wanted.toLowerCase()
              const named = candidates.map((el) => ({ el, name: collapse(nameFor(el)) }))
              const tiers = [
                named.filter((entry) => entry.name === wanted),
                named.filter((entry) => entry.name.toLowerCase() === wantedLower),
                named.filter((entry) => entry.name.toLowerCase().includes(wantedLower))
              ]
              return (tiers.find((tier) => tier.length > 0) ?? []).map((entry) => entry.el)
            }
            const matchesRole = roleMatcher(criteria.role)
            const roleFiltered = matchesRole === null ? visible : visible.filter(matchesRole)
            const matches = nameTiered(roleFiltered)
            if (matches.length === 0) {
              // Near-miss diagnosis, role+name only (see the doc above for why): does
              // the name match under some other role? role stays a hard filter even
              // here — this only changes what the *error* says, never what a call
              // resolves to.
              if (criteria.role !== undefined && criteria.name !== undefined) {
                const nameOnly = nameTiered(visible)
                if (nameOnly.length > 0) {
                  const wantedRole = String(criteria.role).toLowerCase()
                  const roles = Array.from(new Set(nameOnly.map((el) => roleFor(el).toLowerCase())))
                  if (roles.length === 1) {
                    return {
                      error: 'no ' + wantedRole + ' named ' + JSON.stringify(criteria.name) + '; a ' + roles[0] + ' with that name exists — retry without --role'
                    }
                  }
                  const listedRoles = roles.slice(0, \#(ambiguityListMax)).join(', ')
                  const moreRoles = roles.length > \#(ambiguityListMax) ? ', and ' + (roles.length - \#(ambiguityListMax)) + ' more' : ''
                  return {
                    error: 'no ' + wantedRole + ' named ' + JSON.stringify(criteria.name) + '; found with roles: ' + listedRoles + moreRoles + ' — retry without --role'
                  }
                }
              }
              return { error: 'no element matches ' + label + ' — read-page shows what the page calls its controls' }
            }
            if (typeof criteria.nth === 'number') {
              if (criteria.nth >= matches.length) {
                return { error: 'nth ' + criteria.nth + ' is out of range: only ' + matches.length + ' element(s) match ' + label + ' (nth is 0-based)' }
              }
              return matches[criteria.nth]
            }
            if (matches.length > 1) {
              const listed = matches.slice(0, \#(ambiguityListMax)).map((el, index) => {
                const d = describeEl(el)
                const r = el.getBoundingClientRect()
                return '[' + index + '] ' + d.role + ' "' + d.name + '" <' + d.tag + '> at (' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ')'
              })
              const more = matches.length > \#(ambiguityListMax) ? '; and ' + (matches.length - \#(ambiguityListMax)) + ' more' : ''
              return { error: matches.length + ' elements match ' + label + ': ' + listed.join('; ') + more + ' — pass nth (a 0-based index into this list) or tighten the criteria' }
            }
            return matches[0]
          })()
        """#
}

/// The shared opening of every resolver-driven script: evaluate the resolver (an
/// expression yielding `Element | null | { error }`, with `describeElementJS` already
/// in scope for it), surface the resolver's own error under the script's failure
/// key, refuse a disconnected match, and scroll the element to center:
/// `behavior: 'instant'` because a page's own `scroll-behavior: smooth` would leave
/// the element still travelling when the next line reads geometry or moves focus.
/// Leaves `el` (a connected Element) in scope for whatever the script does next.
private func resolvedElementPrologue(_ resolver: String, failKey: String) -> String {
    #"""
    const found = (\#(resolver))
        if (found && typeof found === 'object' && typeof found.error === 'string' && !(found instanceof Element)) {
          return { \#(failKey): false, reason: found.error }
        }
        const el = found instanceof Element ? found : null
        if (!el || !el.isConnected) return { \#(failKey): false }
        el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' })
    """#
}

/// Resolves an element and hit-tests its click point, in one script so no layout
/// shift can slip between the two. Scrolls the element into view with `behavior:
/// 'instant'` (deliberately not the default, which follows the page's own
/// `scroll-behavior: smooth` and would leave the element still travelling when the
/// rect is read), then re-reads the rect and asks `elementFromPoint` what actually
/// sits at its center.
///
/// `matched` follows the rule real event dispatch does: the hit element must be the
/// resolved element or a descendant of it (a descendant's events bubble through the
/// target; an ancestor hit means the target isn't actually hittable at that point:
/// covered by an overlay, `pointer-events: none`, or a line-wrapped inline whose box
/// center falls between its lines).
///
/// Deliberately fully synchronous: no requestAnimationFrame, no timers: a
/// backgrounded or hidden page throttles both, and agents routinely drive panes that
/// aren't visible, so an in-page wait could hang the verb until its budget fires.
/// The caller retries a transient mismatch instead: host-side timing, which no page
/// state can starve.
func hitTestPointScript(_ resolver: String) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        \#(resolvedElementPrologue(resolver, failKey: "resolved"))
        const rect = el.getBoundingClientRect()
        if (rect.width <= 0 || rect.height <= 0) return { resolved: false }
        const x = rect.x + rect.width / 2
        const y = rect.y + rect.height / 2
        const hit = document.elementFromPoint(x, y)
        return {
          resolved: true,
          x,
          y,
          matched: hit !== null && (hit === el || el.contains(hit)),
          intended: describeEl(el),
          element: hit ? describeEl(hit) : null
        }
      })()
    """#
}

/// `hitTestPointScript`'s rect-shaped sibling: takes the same resolver contract and
/// reports the element's viewport rect rather than a click point.
///
/// No hit test here, deliberately. A capture is not a press: nothing is dispatched
/// at the rect, so "is something covering it" is not a question this needs answered;
/// an overlay sitting above the element is part of what the caller asked to see.
/// Scrolling into view *is* shared, and matters more than for a click: a snapshot
/// can only ever return pixels the page is actually showing, so an element below the
/// fold would otherwise clip to nothing.
func elementRectScript(_ resolver: String) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        \#(resolvedElementPrologue(resolver, failKey: "resolved"))
        const rect = el.getBoundingClientRect()
        if (rect.width <= 0 || rect.height <= 0) return { resolved: false }
        return {
          resolved: true,
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          element: describeEl(el)
        }
      })()
    """#
}

/// Describes whatever sits at a viewport point: the reporting half of a coordinate
/// click, which never gates on what it finds: the caller named the exact point, so
/// refusing it would be second-guessing them, but telling them what was there makes
/// a miss detectable without a follow-up read.
func describePointScript(x: Double, y: Double) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        const hit = document.elementFromPoint(\#(jsNumber(x)), \#(jsNumber(y)))
        return hit ? describeEl(hit) : null
      })()
    """#
}

/// The focus-path twin of `hitTestPointScript`: takes the same resolver contract and
/// focuses the resolved element directly, never via a synthesized click an overlay
/// could swallow: used by `type` for refs and semantic targets alike. No hit test
/// here because focus targets the element itself; a shifted layout cannot redirect
/// it. `reason` distinguishes "the resolver failed, and says why" from "matched, but
/// focus() didn't take": both worth a caller's while, and only the page can tell
/// them apart.
func focusTargetScript(_ resolver: String) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        \#(resolvedElementPrologue(resolver, failKey: "focused"))
        el.focus()
        if (document.activeElement !== el) {
          const d = describeEl(el)
          return { focused: false, reason: 'matched ' + d.role + ' "' + d.name + '" <' + d.tag + '> but it did not take focus — it may not be a focusable element' }
        }
        return { focused: true }
      })()
    """#
}

/// Wraps caller-supplied code so a throw comes back as *data*: `Name: message`, then
/// the stack's frames (JavaScriptCore's `error.stack` is only the frames). Only frames
/// with a location are kept: JavaScriptCore gives the injected code no URL or line, so
/// its frames, and this wrapper's, are a bare `@` (or a bare name), and a built-in's is
/// `name@[native code]`. What is left is the page's own code, `name@url:line:column`.
/// (WebKit reports a rejected evaluation's error by itself; the wrapper is what gives
/// the message, the stack and the "not an expression" refusal their form.)
///
/// **The code is evaluated as an expression**, which is what makes this possible
/// without `eval`: a page with a `script-src` policy lacking `unsafe-eval` would
/// refuse it, while the embedder's own injection is not subject to the page's CSP. A
/// statement sequence goes in an IIFE, `(() => { ... })()`; anything that isn't a
/// valid expression fails as a syntax error, which is reported as exactly that.
func executeScript(_ code: String) -> String {
    #"""
    (async () => {
        try {
          return { ok: true, value: await (\#(code)) }
        } catch (error) {
          return {
            ok: false,
            error: error instanceof Error
              ? [error.name + ': ' + error.message, ...String(error.stack ?? '').split('\n').filter((frame) => /:\d+:\d+$/.test(frame.trim()))].join('\n')
              : String(error)
          }
        }
      })()
    """#
}

/// Fills the focused element with `value` entirely in-script, and reports what the
/// element actually holds afterwards.
///
/// No path here types characters: the key pipeline cannot carry `\n` (and every
/// other key-less character), so values are written whole instead, per element kind:
///
/// - A `<select>` picks the option whose value or visible label equals the
///   requested value, and reports the valid options if none matches.
/// - An `<input>`/`<textarea>` is set through the **native prototype setter**, then
///   `input`/`change` are dispatched with `bubbles: true`. The prototype setter (not
///   `el.value = ...`) is what keeps React and friends honest: their value tracker
///   dedupes events against the last value it saw, and a direct assignment updates
///   that tracker so the dispatched event reads as "no change" and is ignored.
///   `length` is the element's own value length *after* the set: the engine
///   sanitizes on write (a single-line `<input>` strips `\n`, a date input rejects
///   non-dates to empty), and the read-back is what lets the host report that instead
///   of counting the field filled.
/// - A contenteditable host gets `selectAll` + `insertText` (or `delete` for an empty
///   value): real editing commands that fire the `beforeinput`/`input` events rich
///   editors listen for, and the only route by which multiline text lands as line
///   breaks. Its `length` is measured on `innerText`, which normalizes blank lines,
///   so it is advisory rather than exact.
///
/// Anything else focused (a button, a plain div) is `unfillable`, described in
/// `read-page`'s vocabulary; a set that throws (an exotic input) comes back as
/// `error` data.
func fillFocusedScript(_ value: String) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        const el = document.activeElement
        const wanted = \#(jsonQuoted(value))
        if (!el || ((el === document.body || el === document.documentElement) && !el.isContentEditable)) {
          return { mode: 'none' }
        }
        if (el.tagName === 'SELECT') {
          const options = Array.from(el.options)
          const match = options.find((option) => option.value === wanted)
            || options.find((option) => (option.label || option.textContent || '').trim() === wanted.trim())
          if (!match) {
            return {
              mode: 'select',
              matched: false,
              options: options.slice(0, 20).map((o) => ({
                value: o.value,
                label: (o.label || o.textContent || '').trim()
              }))
            }
          }
          Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(el, match.value)
          el.dispatchEvent(new Event('input', { bubbles: true }))
          el.dispatchEvent(new Event('change', { bubbles: true }))
          return { mode: 'select', matched: true, length: el.value.length }
        }
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
          const inputType = el.tagName === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase() : null
          if (inputType !== null && \#(jsLiteral(.array(unfillableInputTypes.map { .string($0) }))).includes(inputType)) {
            return { mode: 'unfillable', element: describeEl(el) }
          }
          const proto = el.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype
          try {
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, wanted)
          } catch (error) {
            return { mode: 'error', error: error instanceof Error ? error.message : String(error) }
          }
          el.dispatchEvent(new Event('input', { bubbles: true }))
          el.dispatchEvent(new Event('change', { bubbles: true }))
          return { mode: 'set', length: el.value.length, tag: el.tagName.toLowerCase() }
        }
        if (el.isContentEditable) {
          document.execCommand('selectAll')
          if (wanted === '') document.execCommand('delete')
          else document.execCommand('insertText', false, wanted)
          return { mode: 'editable', length: (el.innerText || '').length }
        }
        return { mode: 'unfillable', element: describeEl(el) }
      })()
    """#
}

/// Runs one of the browser's editing commands against whatever the page has focused,
/// and reports whether it took: in the page, via `execCommand`.
///
/// It is also the route `fillFocusedScript` already takes for a contenteditable, so
/// the two agree about what an editing command is. `execCommand` returns false when
/// it declines outright. It returns *true* for an `undo` with nothing on the stack,
/// which is why the caller documents the limitation rather than trying to report it.
func editingCommandScript(_ command: String) -> String {
    #"""
    (() => {
        \#(describeElementJS)
        const el = document.activeElement
        const applied = document.execCommand(\#(jsonQuoted(command)))
        return { applied, element: el instanceof Element ? describeEl(el) : null }
      })()
    """#
}

/// Scrolls the document and reports where it actually ended up. Nested scroll
/// containers are out of scope.
///
/// **`behavior: 'instant'`, explicitly.** A two-argument `window.scrollBy(x, y)`
/// resolves to `behavior: 'auto'`, which defers to the page's own `scroll-behavior`:
/// so on a `scroll-behavior: smooth` page the scroll animates and the
/// `scrollX/scrollY` read on the next line reports where the page *had been*.
///
/// **The step is computed from the page's own `innerHeight`/`innerWidth`**, not the
/// host's view rect: a backgrounded tab's view has no size, so a step derived from it
/// would scroll nothing while reporting success.
enum ScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

func scrollScript(direction: ScrollDirection, amount: Double? = nil) -> String {
    let vertical = direction == .up || direction == .down
    let sign = direction == .down || direction == .right ? 1 : -1
    // Just under a full screen by default, so successive scrolls keep a strip of
    // overlap rather than skipping content between them.
    let step: String
    if let amount, amount.isFinite, amount > 0 {
        step = String(Int64(amount.rounded()))
    } else {
        step = "Math.round((\(vertical ? "window.innerHeight" : "window.innerWidth")) * 0.8)"
    }
    return #"""
        (() => {
            const step = \#(step)
            window.scrollBy({
              left: \#(vertical ? 0 : sign) * step,
              top: \#(vertical ? sign : 0) * step,
              behavior: 'instant'
            })
            return { x: window.scrollX, y: window.scrollY }
          })()
        """#
}
