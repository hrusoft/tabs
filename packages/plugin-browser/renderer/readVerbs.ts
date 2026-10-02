import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import type { WebviewTag } from 'electron'
import { roleFilterError } from '../shared/ariaRoles'
import type {
  BrowserControlRequest,
  ElementDescription,
  PageElement,
  SemanticTarget
} from '../shared/externalControl'
import {
  DEFAULT_PAGE_TEXT_MAX,
  PAGE_TEXT_HARD_MAX,
  SCREENSHOT_BYTES_KEY
} from '../shared/externalControl'
import { findElements } from './findElements'
import {
  elementRectScript,
  findCandidatesScript,
  mintFindRefsScript,
  PAGE_TEXT_SCRIPT,
  type ReadPageFilter,
  readPageScript
} from './pageScripts'
import { delay, pollUntil } from './pageWait'
import { browserCtx } from './pluginContext'
import { namedTargetResolver } from './targeting'
import {
  evalInGuest,
  evalOutcomeInGuest,
  type GuestViewport,
  guestViewport,
  namedString
} from './verbSupport'

/**
 * The verbs that read a page without driving it: screenshot, getPageText,
 * readPage and find, plus the readiness fields each read reports.
 */

/**
 * How long `screenshot` gives a pane it just revealed to become paintable:
 * React's commit removes the tab panel's `hidden`, then the compositor has to
 * produce a first frame, neither of which is done the instant the store
 * updates. Local to the renderer because main's relay budget for this verb is
 * the read tier's (READ_VERB_BUDGET_MS in main/browserExternalControl.ts) —
 * this must stay far under it so the bounded failure below reaches the caller
 * instead of a relay timeout.
 */
const REVEAL_CAPTURE_WAIT_MS = 3000

/** What `elementRectScript` reports back — see its doc in pageScripts.ts. */
type ElementRectOutcome =
  | { resolved: false; reason?: string }
  | {
      resolved: true
      rect: { x: number; y: number; width: number; height: number }
      element: ElementDescription
    }

/**
 * Resolves `screenshot`'s optional `selector`/`ref` into the rect to clip to,
 * or null when the caller asked for the whole viewport.
 *
 * Two things the guest cannot do for itself happen here. The rect is
 * **clamped to the viewport**, because `capturePage` can only ever return
 * pixels the guest is showing — an element taller than the screen would
 * otherwise request rows that do not exist, which Electron answers with a
 * blank or short image rather than an error. And the rect is **rounded
 * outward** to whole CSS pixels: a fractional rect (a `translateY(0.5px)`, a
 * `zoom`) would otherwise cut a sliver off the element's own edge, which reads
 * as a rendering bug in the page rather than as rounding here.
 */
async function resolveCaptureClip(
  webview: WebviewTag,
  target: { ref: string } | SemanticTarget,
  viewport: GuestViewport
): Promise<
  | {
      rect: { x: number; y: number; width: number; height: number }
      element: ElementDescription
    }
  | { error: string }
> {
  const named = namedTargetResolver(target)
  if ('error' in named) return named
  const run = await evalOutcomeInGuest<ElementRectOutcome>(
    webview,
    elementRectScript(named.resolver)
  )
  if ('error' in run) return run
  const outcome = run.value
  if (!outcome.resolved) return { error: outcome.reason ?? named.notResolved }

  const described = named.described
  const left = Math.max(0, Math.floor(outcome.rect.x))
  const top = Math.max(0, Math.floor(outcome.rect.y))
  const right = Math.min(viewport.width, Math.ceil(outcome.rect.x + outcome.rect.width))
  const bottom = Math.min(viewport.height, Math.ceil(outcome.rect.y + outcome.rect.height))
  if (right <= left || bottom <= top) {
    return {
      error: `${described} is outside the visible viewport, so there is nothing to capture — scroll it into view first`
    }
  }
  return {
    rect: { x: left, y: top, width: right - left, height: bottom - top },
    element: outcome.element
  }
}

/**
 * Captures the guest's visible viewport, or one element's rect within it. The PNG bytes are handed to main
 * under SCREENSHOT_BYTES_KEY rather than returned to the caller — see that
 * constant, and the file-writing half in
 * packages/plugin-browser/main/browserExternalControl.ts.
 *
 * A hidden pane is revealed first rather than failed: a backgrounded tab sits
 * in a `hidden` (display: none) subtree — TabsRenderer keeps every tab
 * mounted — and a display-none guest paints nothing, so `capturePage()`
 * against one has been observed to resolve empty, reject (UnknownVizError),
 * or never settle at all. That is why visibility is checked *before* any
 * capture is attempted instead of diagnosed from how the capture failed; the
 * check cannot confuse a hidden pane with a pane mid-close or mid-move,
 * because those never reach this handler at all (withWebview resolves them to
 * the "not currently mounted" error first). The reveal is the same
 * `revealPane` the activatePane verb performs — it never touches
 * setActivePane, so the no-keyboard-steal guarantee is inherited rather than
 * re-implemented — and it is reported as `activated: true` so the caller
 * knows the visible tab changed. `noActivate` opts out for a caller that
 * would rather fail than change what the user sees.
 */
export async function handleScreenshot(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'screenshot' }>
): Promise<ControlResponse> {
  // Request-shape checks come first, before anything is revealed: they need
  // nothing from the guest, and refusing after the reveal would change what
  // the user is looking at and spend the whole wait budget to answer a
  // question that was unanswerable from the start.
  const hasSelector = namedString(request.selector)
  const hasRef = namedString(request.ref)
  if (hasSelector && hasRef) {
    return {
      ok: false,
      error: 'pass only one of selector or ref — they are different ways to name one element'
    }
  }
  const clipTarget: { ref: string } | SemanticTarget | null = hasRef
    ? { ref: request.ref as string }
    : hasSelector
      ? { selector: request.selector as string }
      : null

  const deadline = Date.now() + REVEAL_CAPTURE_WAIT_MS
  let activated = false
  if (!webview.checkVisibility()) {
    if (request.noActivate) {
      return {
        ok: false,
        error:
          'the pane is hidden — it is not its tab group’s active tab, so it has no frame to capture; rerun without noActivate, or run activatePane first'
      }
    }
    browserCtx.get().layout.revealPane(request.targetPaneId)
    activated = true
    await pollUntil(() => webview.checkVisibility(), deadline)
  }
  // Resolved after the reveal, never before: an element's rect in a hidden
  // guest is meaningless, and scrollIntoView in one is a no-op.
  const view = await guestViewport(webview)
  const clip = clipTarget ? await resolveCaptureClip(webview, clipTarget, view) : null
  if (clip && 'error' in clip) return { ok: false, error: clip.error }

  let image: Electron.NativeImage
  try {
    const capture = () => (clip ? webview.capturePage(clip.rect) : webview.capturePage())
    image = await capture()
    // A freshly revealed guest can need a frame or two before a capture sees
    // pixels — retry inside the same budget rather than failing on the first
    // empty image, and give the compositor that frame before the first retry
    // rather than capturing again back-to-back. Only after a reveal: for a
    // pane that was visible all along, an empty capture is not a state that
    // waiting fixes.
    if (activated && image.isEmpty()) {
      await delay(100)
      await pollUntil(
        async () => {
          image = await capture()
          return !image.isEmpty()
        },
        deadline,
        100
      )
    }
  } catch (error) {
    // Kept a clean sentence rather than letting the rejection escape to the
    // dispatch boundary, which would prepend guest-view plumbing the caller
    // can do nothing with.
    return { ok: false, error: `could not capture the pane: ${String(error)}` }
  }
  if (image.isEmpty()) {
    return { ok: false, error: 'the pane produced no frame to capture' }
  }
  // Two different coordinate spaces, reported separately because they are not
  // the same number on a HiDPI display and conflating them silently puts
  // every coordinate-based click off by the scale factor. `getSize()` (and so
  // the encoded PNG) is in *device* pixels — measured at 2392 for a 1196 CSS
  // pixel pane on a 2x screen — while `sendInputEvent` coordinates, element
  // bounding rects, and readPage's rects are all in *CSS* pixels.
  //
  // Both describe the display and the page, not this particular PNG, and both
  // come from the page itself (see guestViewport): scaleFactor is what a
  // caller divides an image coordinate by to reach the CSS pixels `click`
  // takes, so it must be the real ratio — not the image over a rounded width,
  // which read 2.0029 for a 345.4px-wide pane — and the same whether or not
  // the capture was clipped.
  const imageSize = image.getSize()
  return {
    ok: true,
    result: {
      width: imageSize.width,
      height: imageSize.height,
      viewport: { width: view.width, height: view.height },
      scaleFactor: view.scaleFactor,
      // The rect the capture actually used, after clamping — so a caller
      // mapping a point on a clipped image back into page space has the origin
      // it needs rather than having to assume the element's own rect held.
      ...(clip ? { clipped: clip.rect, element: clip.element } : {}),
      // Present only when the reveal actually happened: absence is the
      // promise that the user's visible tabs were not touched.
      ...(activated ? { activated: true } : {}),
      [SCREENSHOT_BYTES_KEY]: image.toPNG()
    }
  }
}

/** The shape every guest read script answers with, beyond its own payload. */
interface ReadDiagnostics {
  readyState?: unknown
  settled?: unknown
  frames?: unknown
  shadowRoots?: unknown
}

/**
 * The readiness-and-shape fields every read verb folds into its result, so a
 * caller can tell "the page doesn't have it" from "the page hasn't finished
 * saying it" or "it's one level down from where this verb can see":
 *
 * - `isLoading` host-side from the webview; `readyState`/`settled` from the
 *   guest script's answer (see READINESS_JS in pageScripts.ts — `settled` is
 *   the persistent tracker's "no mutation for WAIT_IDLE_QUIET_MS", the same
 *   quiet `waitFor --idle` waits for).
 * - `frames`/`shadowRoots` (DOCUMENT_SHAPE_JS) — always-present integers, 0
 *   included, counting content one level below the top document that these
 *   verbs structurally cannot see into (querySelectorAll/innerText don't
 *   descend into a frame or a shadow tree). A nonzero count next to missing
 *   or incomplete content is the cue that it may live there rather than not
 *   exist — see "What this can't do" in SKILL.md for the workaround.
 *
 * The whole guest pair is passed through only when it has the shape our
 * scripts produce — a page that rewrote the answer gets its fields dropped,
 * never fabricated into document state.
 */
function readinessFields(
  webview: WebviewTag,
  guest: ReadDiagnostics | null | undefined
): Record<string, unknown> {
  return {
    isLoading: webview.isLoading(),
    ...(typeof guest?.readyState === 'string' ? { readyState: guest.readyState } : {}),
    ...(typeof guest?.settled === 'boolean' ? { settled: guest.settled } : {}),
    ...(typeof guest?.frames === 'number' ? { frames: guest.frames } : {}),
    ...(typeof guest?.shadowRoots === 'number' ? { shadowRoots: guest.shadowRoots } : {})
  }
}

export async function handleGetPageText(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'getPageText' }>
): Promise<ControlResponse> {
  const limit = Math.min(request.maxLength ?? DEFAULT_PAGE_TEXT_MAX, PAGE_TEXT_HARD_MAX)
  const run = await evalInGuest<({ text?: unknown } & ReadDiagnostics) | null>(
    webview,
    PAGE_TEXT_SCRIPT
  )
  if ('error' in run) return { ok: false, error: run.error }
  const raw = run.value
  const text = typeof raw?.text === 'string' ? raw.text : String(raw?.text ?? '')
  return {
    ok: true,
    result: {
      text: text.slice(0, limit),
      truncated: text.length > limit,
      ...readinessFields(webview, raw)
    }
  }
}

/**
 * Why this readPage request cannot run as it stands, or null if it can.
 * Host-side for the same reason as semanticTargetError: what arrives over the
 * socket is untyped wire input, so the union's optional-but-typed fields are a
 * promise this check keeps rather than one the compiler does. A blank string
 * counts as absent — `role=""` matches nothing and would read as "the page has
 * no controls", the least intended reading there is.
 */
function readPageFilterError(
  request: Extract<BrowserControlRequest, { type: 'readPage' }>
): string | null {
  for (const key of ['selector', 'role'] as const) {
    const value = request[key]
    if (value !== undefined && !namedString(value)) {
      return `${key} must be a non-empty string`
    }
  }
  // A role outside the ARIA vocabulary can never match (see ariaRoles.ts) —
  // refused rather than answered with an empty list that reads as "none here".
  const unknownRole = typeof request.role === 'string' ? roleFilterError(request.role) : undefined
  if (unknownRole) return unknownRole
  if (
    request.offset !== undefined &&
    (!Number.isInteger(request.offset) || (request.offset as number) < 0)
  ) {
    return 'offset must be a non-negative integer (it is a 0-based index into the matching elements)'
  }
  return null
}

/** Runs `readPage`'s extraction in the guest and normalizes what comes back. */
async function extractPage(
  webview: WebviewTag,
  filter: ReadPageFilter = {}
): Promise<
  | {
      elements: PageElement[]
      truncated: boolean
      total: number
      offset: number
      guest: ReadDiagnostics | null
    }
  | { error: string }
> {
  const run = await evalInGuest<
    | ({
        elements?: PageElement[]
        truncated?: boolean
        total?: number
        offset?: number
        error?: string
      } & ReadDiagnostics)
    | null
  >(webview, readPageScript(filter))
  if ('error' in run) return run
  const raw = run.value
  // Only the selector branch can report one, and only for a selector the page's
  // own querySelectorAll refused — surfaced rather than degraded to an empty
  // list, which would read as "nothing on this page matches".
  if (typeof raw?.error === 'string') return { error: raw.error }
  const elements = raw?.elements ?? []
  return {
    elements,
    truncated: raw?.truncated === true,
    total: typeof raw?.total === 'number' ? raw.total : elements.length,
    offset: typeof raw?.offset === 'number' ? raw.offset : 0,
    guest: raw
  }
}

export async function handleReadPage(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'readPage' }>
): Promise<ControlResponse> {
  const invalid = readPageFilterError(request)
  if (invalid) return { ok: false, error: invalid }
  const extracted = await extractPage(webview, {
    selector: request.selector,
    role: request.role,
    offset: request.offset
  })
  if ('error' in extracted) return { ok: false, error: extracted.error }
  const { elements, truncated, total, offset, guest } = extracted
  return {
    ok: true,
    result: { elements, total, offset, truncated, ...readinessFields(webview, guest) }
  }
}

/** One element `findCandidatesScript` described, before any ref exists for it. */
type FindCandidate = Omit<PageElement, 'ref' | 'value'>

/**
 * Ranks the page's elements against a description and returns the best,
 * minting refs for those alone — see findCandidatesScript for why the two
 * halves are separate guest calls rather than read-page's extraction.
 */
export async function handleFind(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'find' }>
): Promise<ControlResponse> {
  const token = crypto.randomUUID()
  const described = await evalOutcomeInGuest<{ candidates?: FindCandidate[] } & ReadDiagnostics>(
    webview,
    findCandidatesScript(token)
  )
  if ('error' in described) return { ok: false, error: described.error }
  const candidates = (described.value.candidates ?? []).map((candidate, index) => ({
    ...candidate,
    index
  }))
  const ranked = findElements(candidates, request.description, request.maxResults)
  let refs: (string | null)[] = []
  if (ranked.length > 0) {
    const minted = await evalOutcomeInGuest<{ refs?: (string | null)[]; error?: string }>(
      webview,
      mintFindRefsScript(
        token,
        ranked.map(({ element }) => element.index)
      )
    )
    if ('error' in minted) return { ok: false, error: minted.error }
    if (typeof minted.value.error === 'string') return { ok: false, error: minted.value.error }
    refs = minted.value.refs ?? []
  }
  // A match whose element left the page between the two halves has no ref,
  // and is dropped rather than reported with one that could only fail.
  const matches = ranked.flatMap(({ element, score }, i) => {
    const ref = refs[i]
    return typeof ref === 'string'
      ? [
          {
            ref,
            name: element.name,
            role: element.role,
            tag: element.tag,
            rect: element.rect,
            score
          }
        ]
      : []
  })
  return { ok: true, result: { matches, ...readinessFields(webview, described.value) } }
}
