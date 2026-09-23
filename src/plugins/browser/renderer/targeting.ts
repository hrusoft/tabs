import type { WebviewTag } from 'electron'
import type { ElementDescription, ElementTarget, SemanticTarget } from '../shared/externalControl'
import { refResolverExpression, staleRefError } from '../shared/pageRefs'
import {
  describePointScript,
  describeSemanticTarget,
  focusTargetScript,
  hitTestPointScript,
  semanticResolverExpression
} from './pageScripts'
import { delay } from './pageWait'
import { evalInGuest, evalOutcomeInGuest, namedString } from './verbSupport'

/**
 * Naming an element for a verb: resolving a ref, a semantic target or a
 * point to where input should land, and the wording every targeting error
 * shares.
 */

/**
 * The ref-or-semantic half of naming an element: the guest expression that
 * finds it, the phrase every error about it uses, and the message for a
 * resolver that answered `null` without saying why.
 *
 * Shared by every verb that names an element rather than restated per verb,
 * because the caller-facing text is the part that drifts. The ref remedy here
 * ("refs are only valid until the page navigates") is an instruction an agent
 * acts on; a second copy phrased differently, or a verb that spells its own
 * `selector "…"` label instead of `describeSemanticTarget`'s, teaches two
 * different recoveries for one state. The `{x,y}` arm of ElementTarget is
 * deliberately not handled — there is nothing to resolve — so callers that
 * accept one branch on it first.
 */
export function namedTargetResolver(
  target: { ref: string } | SemanticTarget
): { resolver: string; described: string; notResolved: string } | { error: string } {
  if ('ref' in target) {
    return {
      resolver: refResolverExpression(target.ref),
      described: `ref ${target.ref}`,
      // A semantic resolver always states its own reason; only a ref can miss
      // silently (the registry died with the page), so this fallback is in
      // practice the ref-shaped one.
      notResolved: staleRefError(target.ref)
    }
  }
  const invalid = semanticTargetError(target)
  if (invalid) return { error: invalid }
  const described = describeSemanticTarget(target)
  return {
    resolver: semanticResolverExpression(target),
    described,
    notResolved: `no element matches ${described}`
  }
}

/** What `hitTestPointScript` reports back — see its doc in pageScripts.ts. */
type HitTestOutcome =
  | { resolved: false; reason?: string }
  | {
      resolved: true
      x: number
      y: number
      matched: boolean
      intended: ElementDescription
      element: ElementDescription | null
    }

/**
 * How long the host waits before the one hit-test retry. Host-timed rather
 * than an in-guest requestAnimationFrame on purpose: a backgrounded or hidden
 * guest throttles rAF and timers (backgroundThrottling is on for these
 * webviews), and agents routinely drive panes that aren't visible — an
 * in-guest wait could hang the verb until main's relay budget fires, while a
 * host timer is exactly as reliable as the delay(50) polls the verbs
 * already runs under e2e.
 */
const HIT_TEST_RETRY_DELAY_MS = 100

/** A hit description as prose for the mismatch error, naming what a caller can act on. */
export function describeForError(described: ElementDescription | null): string {
  if (!described) return 'no element at all (the point falls outside the document)'
  return described.name
    ? `<${described.tag}> "${described.name}"`
    : `<${described.tag}> (role ${described.role})`
}

/**
 * Why a semantic target can't be resolved as it stands, or null if it can.
 * Shape validation lives host-side, before any guest round trip: what arrives
 * over the socket is untyped wire input, so the union's "at least one
 * criterion" is a promise this check keeps, not one the compiler does. A
 * criterion present but blank (or not a string at all) counts as absent —
 * matching name="" exactly would select every unlabeled control, the least
 * intended reading there is.
 */
function semanticTargetError(target: SemanticTarget): string | null {
  const named = (['role', 'name', 'selector'] as const).some((key) => namedString(target[key]))
  if (!named) {
    return 'a semantic target needs at least one of role, name, selector'
  }
  if (target.nth !== undefined && (!Number.isInteger(target.nth) || target.nth < 0)) {
    return 'nth must be a non-negative integer (it is a 0-based index into the matches)'
  }
  return null
}

/**
 * Turns an `ElementTarget` into the viewport coordinate to dispatch at, plus
 * what sits there. A ref or semantic target is resolved, scrolled into view,
 * and hit-tested in one guest script immediately before dispatch, so a layout
 * shift since readPage moves the click with the element instead of leaving
 * the coordinate pointing at whatever slid into its old spot; a point that no
 * longer holds the element (an overlay, a collapse) gets one retry —
 * transient reflows settle within it — and then a loud failure naming both
 * elements, which beats silently clicking the wrong thing. A raw `{x,y}` is
 * taken as-is and only described, never refused: the caller named the exact
 * point.
 */
export async function resolveClickTarget(
  webview: WebviewTag,
  target: ElementTarget
): Promise<{ x: number; y: number; element?: ElementDescription } | { error: string }> {
  if ('x' in target) {
    // A guest that can't run script (a Chromium error page, the PDF viewer)
    // can still be clicked — the description is reporting, never a gate.
    const hit = await evalInGuest<ElementDescription | null>(
      webview,
      describePointScript(target.x, target.y)
    )
    const element = 'error' in hit ? null : hit.value
    return { x: target.x, y: target.y, ...(element ? { element } : {}) }
  }

  const named = namedTargetResolver(target)
  if ('error' in named) return named
  const described = named.described

  const script = hitTestPointScript(named.resolver)
  let run = await evalOutcomeInGuest<HitTestOutcome>(webview, script)
  if (!('error' in run) && run.value.resolved && !run.value.matched) {
    await delay(HIT_TEST_RETRY_DELAY_MS)
    run = await evalOutcomeInGuest<HitTestOutcome>(webview, script)
  }
  if ('error' in run) return run
  const outcome = run.value
  if (!outcome.resolved) return { error: outcome.reason ?? named.notResolved }
  if (!outcome.matched) {
    const remedy =
      'ref' in target
        ? 'call readPage again, or click by coordinate to press what is actually there'
        : 'dismiss what covers it, or click by coordinate to press what is actually there'
    return {
      error: `clicking ${described} (${describeForError(outcome.intended)}) would land on ${describeForError(outcome.element)} instead — the layout shifted or another element covers it; ${remedy}`
    }
  }
  return { x: outcome.x, y: outcome.y, element: outcome.intended }
}

export function clickAt(webview: WebviewTag, x: number, y: number): void {
  // A move first, so a page that only reveals a control on hover has seen the
  // pointer arrive before the press lands on it.
  webview.sendInputEvent({ type: 'mouseMove', x, y })
  webview.sendInputEvent({ type: 'mouseDown', x, y, button: 'left', clickCount: 1 })
  webview.sendInputEvent({ type: 'mouseUp', x, y, button: 'left', clickCount: 1 })
}

/**
 * Puts the guest's focus where typed text should land. A ref or semantic
 * target is focused directly rather than clicked (an overlay could swallow
 * the click) — the semantic form resolves and focuses in the same guest
 * script, so no layout shift fits between match and focus; a coordinate has
 * nothing to focus but the point itself, so that one clicks. Returns a
 * complete error string when the target can't be focused, null on success —
 * the caller decides whether that aborts the verb (type) or just skips the
 * field (formInput).
 */
export async function focusTypingTarget(
  webview: WebviewTag,
  target: ElementTarget
): Promise<string | null> {
  if ('x' in target) {
    clickAt(webview, target.x, target.y)
    return null
  }
  const named = namedTargetResolver(target)
  if ('error' in named) return named.error
  const run = await evalOutcomeInGuest<{ focused: boolean; reason?: string }>(
    webview,
    focusTargetScript(named.resolver)
  )
  if ('error' in run) return run.error
  // A resolved-but-unfocusable element always carries its own reason; only a
  // target that resolved to nothing falls through to the shared wording.
  if (!run.value.focused) return run.value.reason ?? named.notResolved
  return null
}
