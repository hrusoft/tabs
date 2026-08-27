/**
 * Scripts evaluated inside a browser pane's guest page, via
 * `webview.executeJavaScript`. They are plain source strings rather than
 * functions because there is no shared realm to pass a closure into — the
 * guest is a different process running a different document.
 *
 * Two things follow from that, both deliberate:
 *
 * - **They run in the page's own main world.** `<webview>`'s
 *   `executeJavaScript` has no isolated-world option (unlike
 *   `webContents.executeJavaScript`), so a hostile page can observe or
 *   redefine anything these touch. Nothing here is a security boundary; the
 *   boundary is pane ownership, enforced in src/main/externalControl.ts.
 * - **Only JSON-serializable values can come back.** A DOM node can't cross,
 *   which is why `readPage` returns opaque refs and keeps the actual elements
 *   in a map on the guest side (`REF_REGISTRY`) for a later input verb to
 *   resolve.
 */

import { WAIT_IDLE_QUIET_MS } from '../shared/externalControl'

/**
 * The ref registry's guest-global names live in ../shared/pageRefs.ts so main
 * can read the same registry (save-resource resolves a `--ref` to its
 * element's src there). `refResolverExpression` is re-exported for
 * browserExternalControl.ts, which resolves refs from the verb side.
 */
import { REF_CAPACITY, REF_COUNTER, REF_REGISTRY, refResolverExpression } from '../shared/pageRefs'

export { refResolverExpression }

/**
 * Where the persistent DOM-activity tracker lives: a pair of timestamps —
 * `installedAt`, and `lastAt` for the most recent mutation — stamped by a
 * MutationObserver that is installed on first use and stays for the
 * document's lifetime (navigation drops it with the rest of the page's
 * globals, like the ref registry above). One tracker serves two consumers:
 * the read verbs' `settled` field is computed from these timestamps at read
 * time, and `waitFor --idle` polls them until the quiet period holds (see
 * domIdleScript in waitScripts.ts) — a single definition of "the DOM is
 * quiet", not two clocks that could disagree.
 */
const DOM_ACTIVITY = '__tabsDomActivity'

/**
 * Guest-side fragment ensuring the tracker exists, leaving it in scope as
 * `activity`. Idempotent per document: a second run finds the global and
 * attaches nothing, so repeated reads never restart the observation window —
 * which is exactly what lets a *re*-read report `settled: true`.
 */
export const ENSURE_DOM_ACTIVITY_JS = `
  const existing = window.${DOM_ACTIVITY}
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
          window.${DOM_ACTIVITY} = created
          return created
        })()
`

/**
 * Defines `readiness()`, the `{ readyState, settled }` pair every read verb
 * folds into its result. `settled` is "no observed mutation in the last
 * WAIT_IDLE_QUIET_MS" — measured from `max(installedAt, lastAt)`, so a page
 * that has only just come under observation cannot certify quiet: the first
 * read of any page reports `settled: false` by construction, and a later
 * read is the one that can vouch for it. That is the honest direction — the
 * field exists to tell a caller "read again", never to promise stillness it
 * never watched.
 */
const READINESS_JS = `
  ${ENSURE_DOM_ACTIVITY_JS}
  const readiness = () => ({
    readyState: document.readyState,
    settled: Date.now() - Math.max(activity.installedAt, activity.lastAt) >= ${WAIT_IDLE_QUIET_MS}
  })
`

/**
 * Defines `documentShape()`, `{ frames, shadowRoots }` — always-present
 * integers (0 included) reported alongside every read, so an agent learns the
 * fields exist rather than only noticing them once they matter. Both count
 * what the read verbs cannot otherwise hint at: content one level below the
 * top document that `querySelectorAll`/`innerText` structurally never reach
 * (see readPageScript's and PAGE_TEXT_SCRIPT's docs), so an unexpectedly
 * empty result next to a nonzero count is the caller's cue that the content
 * may live there rather than not existing.
 *
 * `frames` counts `<iframe>`/`<frame>` elements in the top document.
 * `shadowRoots` counts only **open** shadow roots — a closed one returns
 * `null` from `el.shadowRoot` and is invisible to page script by design, the
 * same boundary that makes it invisible to every read verb; there is no way
 * to count what closed mode exists specifically to hide. Only top-level
 * shadow hosts are counted: `querySelectorAll('*')` from `document` does not
 * descend into any shadow tree, so a shadow root nested inside another one
 * would need a recursive walk this deliberately doesn't do — one level down
 * is the case that bites (a widget library's host element), and the caller
 * has `execute-js` for anything deeper.
 */
const DOCUMENT_SHAPE_JS = `
  const documentShape = () => {
    // Counted in a loop rather than Array.from(...).filter(...).length: the
    // walk is inherent to the count, materializing the whole document as an
    // array is not — and this runs on every read verb, on pages with tens of
    // thousands of elements.
    let shadowRoots = 0
    for (const el of document.querySelectorAll('*')) if (el.shadowRoot) shadowRoots++
    return { frames: document.querySelectorAll('iframe, frame').length, shadowRoots }
  }
`

/**
 * Guest-side fragment defining `isVisible(el)` — "the page actually shows
 * this": a non-empty box, not `visibility: hidden`, not `display: none`.
 *
 * One definition rather than an inlined copy per script, because three verbs
 * *promise* to agree on it: `read-page` lists what it says is visible, a
 * semantic `click` filters its candidate pool by it (so a hidden mobile-nav
 * duplicate can't make every visible control ambiguous), and `wait-for
 * --selector` resolves on it. Nothing typechecks a JS source string, so a
 * fourth spelling would silently let `wait-for` resolve on an element
 * `read-page` won't list — a disagreement with no gate to catch it.
 */
export const VISIBLE_ELEMENT_JS = `
  const visibleRect = (el) => {
    const rect = el.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return null
    const style = getComputedStyle(el)
    return style.visibility !== 'hidden' && style.display !== 'none' ? rect : null
  }
  const isVisible = (el) => visibleRect(el) !== null
`

/**
 * Guest-side fragment defining `mintRef(el)` and `roundRect(rect)` — the ref
 * registry's write discipline, next to the constants it writes through.
 * `roundRect` takes an already-measured rect rather than the element, so a
 * caller that has one in hand doesn't pay a second layout read for it.
 *
 * `pageRefs.ts` shares the global *names* so a second spelling can't open a
 * ref namespace that never resolves; this shares the *discipline* around them
 * for the same reason one level up. `read-page` and `wait-for --selector` both
 * mint refs, and a change to the counter semantics, the ref format or the
 * eviction order that reached only one would surface as refs mysteriously
 * failing to resolve rather than as an error.
 */
export const MINT_REF_JS = `
  const mintRef = (el) => {
    const registry = window.${REF_REGISTRY} instanceof Map ? window.${REF_REGISTRY} : new Map()
    window.${REF_REGISTRY} = registry
    const base = typeof window.${REF_COUNTER} === 'number' ? window.${REF_COUNTER} : 0
    const ref = 'e' + (base + 1)
    window.${REF_COUNTER} = base + 1
    registry.set(ref, el)
    while (registry.size > ${REF_CAPACITY}) registry.delete(registry.keys().next().value)
    return ref
  }

  const roundRect = (rect) => ({
    x: Math.round(rect.x),
    y: Math.round(rect.y),
    width: Math.round(rect.width),
    height: Math.round(rect.height)
  })
`

/** Elements worth reporting: everything interactive, plus headings for orientation. */
const CANDIDATE_SELECTOR = [
  'a[href]',
  'button',
  'input',
  'select',
  'textarea',
  'summary',
  '[role]',
  '[onclick]',
  '[tabindex]',
  '[contenteditable="true"]',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6'
].join(',')

/** Response-size discipline: a caller's context is the real budget here, not memory. */
const MAX_ELEMENTS = 200
const MAX_NAME_LENGTH = 120

/**
 * Guest-side helper definitions shared by every script that describes an
 * element: `roleFor`/`nameFor` (the pragmatic accessible-name approximation
 * documented on readPageScript) plus `describeEl`, the `{role, name, tag}`
 * shape `click` reports a hit in — the same vocabulary readPage speaks, so a
 * caller can compare the two directly (see ElementDescription in
 * ../shared/externalControl.ts). This is JS source interpolated into script
 * strings, not code that runs in this process.
 */
const DESCRIBE_ELEMENT_JS = `
  const roleFor = (el) => {
    const explicit = el.getAttribute('role')
    if (explicit) return explicit
    const tag = el.tagName.toLowerCase()
    if (tag === 'a') return 'link'
    if (tag === 'button' || tag === 'summary') return 'button'
    if (tag === 'select') return 'combobox'
    if (tag === 'textarea') return 'textbox'
    if (/^h[1-6]$/.test(tag)) return 'heading'
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

  const nameFor = (el) => {
    const aria = el.getAttribute('aria-label')
    if (aria && aria.trim()) return aria
    const labelledBy = el.getAttribute('aria-labelledby')
    if (labelledBy) {
      const text = labelledBy.split(/\\s+/)
        .map((id) => (document.getElementById(id) || {}).textContent || '')
        .join(' ').trim()
      if (text) return text
    }
    if (el.labels && el.labels.length) {
      const text = Array.from(el.labels).map((l) => l.textContent || '').join(' ').trim()
      if (text) return text
    }
    for (const attr of ['title', 'placeholder', 'alt', 'name']) {
      const value = el.getAttribute(attr)
      if (value && value.trim()) return value
    }
    return (el.innerText || el.textContent || '').trim()
  }

  const describeEl = (el) => ({
    role: roleFor(el),
    name: nameFor(el).replace(/\\s+/g, ' ').slice(0, ${MAX_NAME_LENGTH}),
    tag: el.tagName.toLowerCase()
  })
`

/**
 * Guest-side fragment defining `candidatePool(selector)` and
 * `roleMatcher(role)` — the two narrowing rules `read-page` and a semantic
 * `click`/`hover` *promise* to share, for the same reason VISIBLE_ELEMENT_JS
 * above is one fragment rather than a copy per script. The skill tells an
 * agent to discover a control with `read-page --role X --selector Y` and then
 * act on it with `click --role X --selector Y`; if those two spelled the pool
 * or the role comparison separately they would agree only by coincidence, and
 * a later refinement (role synonyms, a better invalid-selector message) that
 * reached one and not the other would surface as a control that lists but
 * cannot be clicked — a disagreement with no gate to catch it.
 *
 * `candidatePool` answers `{ error }` instead of an array for a selector the
 * page rejects, matching the resolver contract the callers already speak; test
 * it with `Array.isArray`. It depends on `roleFor` from DESCRIBE_ELEMENT_JS,
 * so interpolate it into a scope that has one.
 */
const CANDIDATE_POOL_JS = `
  // The selector *replaces* the candidate set rather than filtering it — the
  // interactive-and-headings default is a guess at what matters, and a caller
  // naming a selector has a better one (an <img>, a table row, a card
  // container), none of which the default would ever have listed.
  const candidatePool = (selector) => {
    try {
      return Array.from(document.querySelectorAll(selector ?? ${JSON.stringify(CANDIDATE_SELECTOR)}))
    } catch {
      return { error: 'invalid selector: ' + selector }
    }
  }

  // Role is a *hard* filter on both sides: a read that quietly widened would
  // hand back elements the caller then has to re-filter, having been told it
  // hadn't to, and a click that widened would click across roles. Returns null
  // for "no role asked for", i.e. keep everything.
  const roleMatcher = (role) => {
    if (role === undefined || role === null) return null
    const wanted = String(role).toLowerCase()
    return (el) => roleFor(el).toLowerCase() === wanted
  }
`

/** How a `readPage` call narrows what it extracts. Every field is optional; none is the default. */
export interface ReadPageFilter {
  /** Widens or narrows the candidate pool to any element matching this CSS selector. */
  selector?: string | undefined
  /** Keeps only candidates whose derived role matches, compared case-insensitively. */
  role?: string | undefined
  /** How many matching candidates to skip before the page of MAX_ELEMENTS returned. */
  offset?: number | undefined
}

/**
 * Extracts a structured, ref-addressable view of the page: role, accessible
 * name, tag and viewport rect per element. The accessible-name derivation is
 * a pragmatic approximation of the real accessible-name algorithm (aria-label
 * → aria-labelledby → associated <label> → title/placeholder/alt/name →
 * visible text), not a spec-complete implementation — a full accessibility
 * tree is the one thing here that would genuinely need a CDP debugger
 * session, which this tier deliberately does without.
 *
 * Two rules make the narrowing worth having.
 *
 * **The slice happens before minting**, so skipping a page costs no refs: the
 * registry holds REF_CAPACITY entries and paging a large document would
 * otherwise evict the very refs the caller is walking toward. (Past 1000
 * elements it evicts anyway — the caller's cue is `total`, which is why that
 * is reported rather than left to be inferred from `truncated`.)
 *
 * **`truncated` means "there are more after this page"**, not "more than fit"
 * — with no offset the two are the same claim, so the field's meaning at the
 * default is byte-identical to what it always was, and with an offset it stays
 * the actionable one (raise `--offset`). What it deliberately does *not* say is
 * that elements were skipped *before* the page: that is what `offset` itself
 * reports, and folding both into one boolean would make neither answerable.
 */
export function readPageScript(filter: ReadPageFilter): string {
  return `(() => {
  ${DESCRIBE_ELEMENT_JS}
  ${VISIBLE_ELEMENT_JS}
  ${CANDIDATE_POOL_JS}
  ${MINT_REF_JS}
  ${READINESS_JS}
  ${DOCUMENT_SHAPE_JS}
  const criteria = ${JSON.stringify(filter)}
  const pool = candidatePool(criteria.selector)
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
  const elements = visible.slice(offset, offset + ${MAX_ELEMENTS}).map(([el, rect]) => {
    const value = typeof el.value === 'string' ? el.value : undefined
    const element = {
      ref: mintRef(el),
      ...describeEl(el),
      rect: roundRect(rect)
    }
    if (value) element.value = value.slice(0, ${MAX_NAME_LENGTH})
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
})()`
}

/**
 * `getPageText`'s extraction: innerText rather than textContent because it
 * reflects what's actually rendered (no <script>/<style> bodies, collapsed
 * whitespace, line breaks where the layout puts them), which is what a caller
 * reading a page wants. Length limiting stays renderer-side, where the shared
 * caps live. Carries the same readiness pair as readPage, from the same
 * tracker.
 */
export const PAGE_TEXT_SCRIPT = `(() => {
  ${READINESS_JS}
  ${DOCUMENT_SHAPE_JS}
  return {
    text: (document.body ?? document.documentElement)?.innerText ?? '',
    ...readiness(),
    ...documentShape()
  }
})()`

/** Candidates listed in an ambiguous-match error before "and N more" truncates the rest. */
const AMBIGUITY_LIST_MAX = 10

/**
 * A semantic target's criteria as prose — `role="button" name="Save"` — used
 * as the label in every error the resolver can produce, and by the host for
 * the hit-mismatch error, so both ends name the target the same way.
 */
export function describeSemanticTarget(target: {
  role?: string
  name?: string
  selector?: string
}): string {
  const parts: string[] = []
  if (target.role !== undefined) parts.push(`role=${JSON.stringify(target.role)}`)
  if (target.name !== undefined) parts.push(`name=${JSON.stringify(target.name)}`)
  if (target.selector !== undefined) parts.push(`selector=${JSON.stringify(target.selector)}`)
  return parts.join(' ')
}

/**
 * The semantic-shaped instance of the resolver contract `refResolverExpression`
 * documents: a guest expression evaluating to `Element | null | { error }`,
 * for interpolation into a script that supplies DESCRIBE_ELEMENT_JS —
 * `hitTestPointScript`, `elementRectScript` or `focusTargetScript` today —
 * because it calls `roleFor`/`nameFor`/`describeEl` from that scope. It brings
 * its own VISIBLE_ELEMENT_JS and CANDIDATE_POOL_JS, scoped to its own IIFE.
 *
 * Matching (decided, not incidental — see SemanticTarget's doc in
 * ../shared/externalControl.ts): the selector defines the pool and `role`
 * hard-filters it, both through the same CANDIDATE_POOL_JS fragment readPage
 * uses; visibility filters it with readPage's exact predicate — literally the
 * same fragments, so the two cannot drift — so a hidden mobile-nav duplicate
 * can't make every visible control ambiguous; and `name` walks the
 * strictness ladder — exact, case-insensitive exact, case-insensitive
 * substring, whitespace-normalized throughout — taking the strictest
 * non-empty tier, so an exact name is never ambiguous merely because it
 * prefixes a longer one. Ambiguity within that tier *fails*, listing the
 * candidates with the 0-based indices `nth` indexes into; guessing the first
 * match would reintroduce exactly the wrong-target class this form exists to
 * remove. The caller pre-validates shape (at least one criterion, `nth` a
 * non-negative integer), so the guest only ever reports match outcomes.
 *
 * `role` stays a **hard** filter — it never falls back to a looser match on
 * its own, because silently clicking across roles is exactly the guessing
 * this form exists to remove (non-semantic markup, where a click target is a
 * `<div>` with an ARIA-derived role like "group" rather than a real `button`,
 * is the norm on real sites, not the exception). What it gets instead is a
 * *diagnosis*: when role+name together match nothing, the same name ladder
 * re-runs against the visibility-filtered pool with the role filter lifted,
 * in this same guest pass — no extra round trip. A hit there means the name
 * is right and only the role was too strict, so the error says exactly that
 * (naming the role(s) actually found) instead of the generic no-match
 * message that gives no hint which half was wrong.
 */
export function semanticResolverExpression(target: {
  role?: string
  name?: string
  selector?: string
  nth?: number
}): string {
  const criteria = {
    ...(target.role !== undefined ? { role: target.role } : {}),
    ...(target.name !== undefined ? { name: target.name } : {}),
    ...(target.selector !== undefined ? { selector: target.selector } : {}),
    ...(target.nth !== undefined ? { nth: target.nth } : {})
  }
  return `(() => {
    ${VISIBLE_ELEMENT_JS}
    ${CANDIDATE_POOL_JS}
    const criteria = ${JSON.stringify(criteria)}
    const label = ${JSON.stringify(describeSemanticTarget(target))}
    const pool = candidatePool(criteria.selector)
    if (!Array.isArray(pool)) return pool
    const visible = pool.filter(isVisible)
    const collapse = (text) => text.replace(/\\s+/g, ' ').trim()
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
          const listedRoles = roles.slice(0, ${AMBIGUITY_LIST_MAX}).join(', ')
          const moreRoles = roles.length > ${AMBIGUITY_LIST_MAX} ? ', and ' + (roles.length - ${AMBIGUITY_LIST_MAX}) + ' more' : ''
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
      const listed = matches.slice(0, ${AMBIGUITY_LIST_MAX}).map((el, index) => {
        const d = describeEl(el)
        const r = el.getBoundingClientRect()
        return '[' + index + '] ' + d.role + ' "' + d.name + '" <' + d.tag + '> at (' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ')'
      })
      const more = matches.length > ${AMBIGUITY_LIST_MAX} ? '; and ' + (matches.length - ${AMBIGUITY_LIST_MAX}) + ' more' : ''
      return { error: matches.length + ' elements match ' + label + ': ' + listed.join('; ') + more + ' — pass nth (a 0-based index into this list) or tighten the criteria' }
    }
    return matches[0]
  })()`
}

/**
 * Resolves an element and hit-tests its click point, in one script so no
 * layout shift can slip between the two. Scrolls the element into view with
 * `behavior: 'instant'` — deliberately not the default, which follows the
 * page's own `scroll-behavior: smooth` and would leave the element still
 * travelling when the rect is read — then re-reads the rect and asks
 * `elementFromPoint` what actually sits at its center.
 *
 * `matched` follows the rule real event dispatch does: the hit element must
 * be the resolved element or a descendant of it (a descendant's events bubble
 * through the target; an ancestor hit means the target isn't actually
 * hittable at that point — covered by an overlay, `pointer-events: none`, or
 * a line-wrapped inline whose box center falls between its lines).
 *
 * The shared opening of every resolver-driven script: evaluate the resolver
 * (an expression yielding `Element | null | { error }`, with
 * DESCRIBE_ELEMENT_JS already in scope for it), surface the resolver's own
 * error under the script's failure key, refuse a disconnected match, and
 * scroll the element to center — `behavior: 'instant'` because a page's own
 * `scroll-behavior: smooth` would leave the element still travelling when
 * the next line reads geometry or moves focus. Leaves `el` (a connected
 * Element) in scope for whatever the script does next.
 */
function resolvedElementPrologue(resolver: string, failKey: 'resolved' | 'focused'): string {
  return `const found = (${resolver})
    if (found && typeof found === 'object' && typeof found.error === 'string' && !(found instanceof Element)) {
      return { ${failKey}: false, reason: found.error }
    }
    const el = found instanceof Element ? found : null
    if (!el || !el.isConnected) return { ${failKey}: false }
    el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' })`
}

/**
 * Deliberately fully synchronous — no requestAnimationFrame, no timers: a
 * backgrounded or hidden guest throttles both (the `<webview>`s here don't
 * disable backgroundThrottling), and agents routinely drive panes that aren't
 * visible, so an in-guest wait could hang the verb until main's relay budget
 * fires. The caller retries a transient mismatch instead — host-side timing,
 * which no guest state can starve.
 */
export function hitTestPointScript(resolver: string): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    ${resolvedElementPrologue(resolver, 'resolved')}
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
  })()`
}

/**
 * `hitTestPointScript`'s rect-shaped sibling: takes the same resolver contract
 * and reports the element's viewport rect rather than a click point.
 *
 * No hit test here, deliberately. A capture is not a press — nothing is
 * dispatched at the rect, so "is something covering it" is not a question this
 * needs answered; an overlay sitting above the element is part of what the
 * caller asked to see. Scrolling into view *is* shared, and matters more than
 * for a click: `capturePage` can only ever return pixels the guest is actually
 * showing, so an element below the fold would otherwise clip to nothing.
 * `behavior: 'instant'` for the same reason the click path uses it — the
 * page's own `scroll-behavior: smooth` would leave the element still
 * travelling when the rect is read.
 */
export function elementRectScript(resolver: string): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    ${resolvedElementPrologue(resolver, 'resolved')}
    const rect = el.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return { resolved: false }
    return {
      resolved: true,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      element: describeEl(el)
    }
  })()`
}

/**
 * Describes whatever sits at a viewport point — the reporting half of a
 * coordinate click, which never gates on what it finds: the caller named the
 * exact point, so refusing it would be second-guessing them, but telling them
 * what was there makes a miss detectable without a follow-up read.
 */
export function describePointScript(x: number, y: number): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    const hit = document.elementFromPoint(${Number(x)}, ${Number(y)})
    return hit ? describeEl(hit) : null
  })()`
}

/**
 * The focus-path twin of `hitTestPointScript`: takes the same resolver
 * contract (an expression evaluating to `Element | null | { error }`, with
 * DESCRIBE_ELEMENT_JS in scope for it) and focuses the resolved element
 * directly, never via a synthesized click an overlay could swallow — used by
 * `type` for refs and semantic targets alike. No hit-test here because focus targets the element
 * itself; a shifted layout cannot redirect it. `reason` distinguishes "the
 * resolver failed, and says why" from "matched, but focus() didn't take" —
 * both worth a caller's while, and only the guest can tell them apart.
 */
export function focusTargetScript(resolver: string): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    ${resolvedElementPrologue(resolver, 'focused')}
    el.focus()
    if (document.activeElement !== el) {
      const d = describeEl(el)
      return { focused: false, reason: 'matched ' + d.role + ' "' + d.name + '" <' + d.tag + '> but it did not take focus — it may not be a focusable element' }
    }
    return { focused: true }
  })()`
}

/**
 * Wraps caller-supplied code so a throw comes back as *data* rather than as a
 * rejected `executeJavaScript`.
 *
 * Worth the wrapper because Electron discards the real error: a guest script
 * that throws `new Error('deliberate')` surfaces only as "Script failed to
 * execute, this normally means an error was thrown. Check the renderer
 * console for the error" — advice a caller driving the pane over a socket
 * cannot act on. Catching inside the guest keeps the message and stack.
 *
 * **The code is evaluated as an expression**, which is what makes this
 * possible without `eval` — and avoiding `eval` matters, since a page with a
 * `script-src` policy lacking `unsafe-eval` would refuse it, while Electron's
 * own injection is not subject to the page's CSP. A statement sequence goes
 * in an IIFE, `(() => { ... })()`; anything that isn't a valid expression
 * fails as a syntax error, which is reported as exactly that.
 */
export function executeScript(code: string): string {
  return `(async () => {
    try {
      return { ok: true, value: await (${code}) }
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? (error.stack || error.message) : String(error)
      }
    }
  })()`
}

/**
 * Input types a text fill is meaningless for: their value is not text a user
 * would enter (a checkbox's is its submit token, a button's is its label), so
 * writing to it would report success while changing nothing the caller meant
 * to change. `file` is here too — Chromium forbids setting it at all — and
 * each gets a loud `unfillable` outcome pointing at `click` instead.
 */
const UNFILLABLE_INPUT_TYPES = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file']

/**
 * Fills the focused element with `value` entirely in-script, and reports what
 * the element actually holds afterwards.
 *
 * No path here types characters. The char-event pipeline this replaced
 * silently drops `\n` (and every other key-less character) on the floor —
 * a 42-newline value arrived with all 42 missing while the verb reported
 * success — so values are written whole instead, per element kind:
 *
 * - A `<select>` picks the option whose value or visible label equals the
 *   requested value (char events would only trigger flaky type-ahead), and
 *   reports the valid options if none matches.
 * - An `<input>`/`<textarea>` is set through the **native prototype setter**,
 *   then `input`/`change` are dispatched with `bubbles: true`. The prototype
 *   setter (not `el.value = ...`) is what keeps React and friends honest:
 *   their value tracker dedupes events against the last value it saw, and a
 *   direct assignment updates that tracker so the dispatched event reads as
 *   "no change" and is ignored. `length` is the element's own value length
 *   *after* the set — Chromium sanitizes on write (a single-line `<input>`
 *   strips `\n`, a date input rejects non-dates to empty), and the read-back
 *   is what lets the host report that instead of counting the field filled.
 * - A contenteditable host gets `selectAll` + `insertText` (or `delete` for
 *   an empty value) — real editing commands that fire the `beforeinput`/
 *   `input` events rich editors listen for, and the only route by which
 *   multiline text lands as line breaks. Its `length` is measured on
 *   `innerText`, which normalizes blank lines, so it is advisory rather than
 *   exact — the host knows not to strict-check it.
 *
 * Anything else focused (a button, a plain div) is `unfillable`, described in
 * readPage's vocabulary; a set that throws (an exotic input) comes back as
 * `error` data rather than as Electron's opaque script-failure message.
 */
export function fillFocusedScript(value: string): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    const el = document.activeElement
    const wanted = ${JSON.stringify(value)}
    if (!el || ((el === document.body || el === document.documentElement) && !el.isContentEditable)) {
      return { mode: 'none' }
    }
    if (el.tagName === 'SELECT') {
      const options = Array.from(el.options)
      const match = options.find((option) => option.value === wanted)
        || options.find((option) => (option.label || option.textContent || '').trim() === wanted.trim())
      if (!match) {
        return { mode: 'select', matched: false, options: options.slice(0, 20).map((o) => o.value) }
      }
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(el, match.value)
      el.dispatchEvent(new Event('input', { bubbles: true }))
      el.dispatchEvent(new Event('change', { bubbles: true }))
      return { mode: 'select', matched: true, length: el.value.length }
    }
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const inputType = el.tagName === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase() : null
      if (inputType !== null && ${JSON.stringify(UNFILLABLE_INPUT_TYPES)}.includes(inputType)) {
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
  })()`
}

/**
 * Runs one of Chromium's editing commands against whatever the guest has
 * focused, and reports whether it took.
 *
 * **In the guest, via `execCommand` — not `WebContents.selectAll()` and
 * friends, which are inert here.** Measured on a real guest with the field
 * genuinely focused (`document.activeElement` was the input,
 * `document.hasFocus()` true): `webview.selectAll()` left the selection at
 * `8-8` on an 8-character value, and so did `selectAll()` called *directly on
 * the guest WebContents from main*, with an explicit `focus()` first. Those
 * methods route to the focused widget of a focused window, and a `<webview>`
 * guest never becomes the window's first responder on macOS — the same reason
 * `webContents.on('focus')` never fires for one (see CLAUDE.md). The identical
 * `document.execCommand('selectAll')` in the page returned `0-8`.
 *
 * This is also the route `fillFocusedScript` already takes for a
 * contenteditable, so the two agree about what an editing command is rather
 * than reaching the same page through two different layers.
 *
 * `execCommand` returns false when it declines outright. It returns *true* for
 * an `undo` with nothing on the stack, which is why the caller documents the
 * limitation rather than trying to report it: only real keystrokes populate
 * Chromium's undo stack, so an undo after a programmatic fill is a no-op that
 * honestly answers "ran".
 */
export function editingCommandScript(command: string): string {
  return `(() => {
    ${DESCRIBE_ELEMENT_JS}
    const el = document.activeElement
    const applied = document.execCommand(${JSON.stringify(command)})
    return { applied, element: el instanceof Element ? describeEl(el) : null }
  })()`
}

/**
 * Scrolls the document and reports where it actually ended up. Nested scroll
 * containers are out of scope — see SKILL.md.
 *
 * **`behavior: 'instant'` is the whole fix, and it is not a change of
 * mechanism.** The two-argument `window.scrollBy(x, y)` this replaced resolves
 * to `behavior: 'auto'`, which defers to the page's own computed
 * `scroll-behavior` — so on a page declaring `scroll-behavior: smooth` the
 * scroll animated and the `scrollX/scrollY` read on the next line reported
 * where the page *had been*. Measured in plain Chromium: an immediate
 * `{x: 0, y: 0}` for a scroll that settled at `{x: 0, y: 800}`.
 *
 * Nothing about wheel semantics changes, because there were never any wheel
 * events: this verb has always scrolled programmatically, and a programmatic
 * `scrollBy` fires no `wheel` listeners either way (measured: zero). The only
 * observable difference is that the page arrives instantly instead of over
 * ~300ms, and the position returned is now true.
 *
 * **The step is computed here rather than from the host's element rect**, and
 * that is a second bug fixed in the same line: a backgrounded tab's
 * `<webview>` sits in a `display: none` subtree, so `getBoundingClientRect()`
 * reports 0×0 and the default step came out as zero — `scroll` on a pane the
 * user had tabbed away from silently scrolled nothing and reported success.
 * The guest's own `innerHeight`/`innerWidth` are correct whether or not the
 * host has laid the element out.
 */
export function scrollScript(direction: 'up' | 'down' | 'left' | 'right', amount?: number): string {
  const vertical = direction === 'up' || direction === 'down'
  const sign = direction === 'down' || direction === 'right' ? 1 : -1
  // Just under a full screen by default, so successive scrolls keep a strip of
  // overlap rather than skipping content between them.
  const step =
    typeof amount === 'number' && Number.isFinite(amount) && amount > 0
      ? String(Math.round(amount))
      : `Math.round((${vertical ? 'window.innerHeight' : 'window.innerWidth'}) * 0.8)`
  return `(() => {
    const step = ${step}
    window.scrollBy({
      left: ${vertical ? 0 : sign} * step,
      top: ${vertical ? sign : 0} * step,
      behavior: 'instant'
    })
    return { x: window.scrollX, y: window.scrollY }
  })()`
}
