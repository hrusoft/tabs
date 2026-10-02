import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import type { WebviewTag } from 'electron'
import type { BrowserControlRequest } from '../shared/externalControl'
import {
  ASSERT_CHECK_BUDGET_MS,
  clampWaitPoll,
  clampWaitTimeout,
  WAIT_IDLE_QUIET_MS,
  WAIT_MIN_POLL_MS
} from '../shared/externalControl'
import { type PageWaitSpec, waitForPageCondition } from './pageWait'
import { browserPaneError, namedString } from './verbSupport'

/**
 * waitFor and its single-shot twin assert: validating the one condition a
 * call names, and turning the supervisor's outcome (pageWait.ts) into an
 * answer that says what never held.
 */

type WaitForRequest = Extract<BrowserControlRequest, { type: 'waitFor' }>

/**
 * The one wait/assert message that names neither verb — hoisted because the
 * two validators are deliberately separate per-verb (their other messages
 * name their own verb), and a shared string is the only part that may not
 * fork.
 */
const GONE_NEEDS_TARGET = 'gone inverts text or selector — it needs one of them to invert'

/**
 * Why this waitFor request cannot run as it stands, or null if it can.
 * Host-side for the same reason as semanticTargetError: what arrives over the
 * socket is untyped wire input, so "exactly one condition" is a promise this
 * check keeps, not one the compiler does. Exactly one is a decision, not a
 * limitation — AND-ed conditions read plausibly but hide which half never
 * held when the wait times out, and a sequence of waits (or a batch) states
 * the same thing legibly.
 */
function waitSpecError(request: WaitForRequest): string | null {
  const conditions = [
    namedString(request.text),
    namedString(request.selector),
    namedString(request.urlContains),
    request.idle === true
  ].filter(Boolean).length
  if (conditions === 0) {
    return 'waitFor needs a condition: one of text, selector, urlContains, idle'
  }
  if (conditions > 1) {
    return 'waitFor takes exactly one condition per call — run several waits (or a batch of them) to combine conditions'
  }
  if (request.gone === true && !namedString(request.text) && !namedString(request.selector)) {
    return GONE_NEEDS_TARGET
  }
  return null
}

/**
 * The wait spec, rebuilt from the validated fields rather than spread from the
 * wire, so a blank-but-present string can't reach the guest as a condition.
 *
 * Shared by `waitFor` and `assert` — unlike their validators and their prose,
 * which are deliberately per-verb (each message must name its own verb), this
 * holds no wording at all, so a condition added to one and not the other would
 * be a condition the validator accepts and the spec silently drops. `idle` is
 * absent from assert's vocabulary and simply never set for it.
 */
function buildPageWaitSpec(request: {
  text?: string
  selector?: string
  urlContains?: string
  gone?: boolean
  idle?: boolean
}): PageWaitSpec {
  if (namedString(request.urlContains)) return { urlContains: request.urlContains }
  if (request.idle === true) return { idle: true }
  return {
    ...(namedString(request.text) ? { text: request.text } : {}),
    ...(namedString(request.selector) ? { selector: request.selector } : {}),
    ...(request.gone === true ? { gone: true } : {})
  }
}

/** The condition as prose, for the timeout error naming what never held. */
function describeWaitCondition(request: WaitForRequest): string {
  if (request.idle === true) {
    return `the DOM to go idle (no mutations for ${WAIT_IDLE_QUIET_MS}ms)`
  }
  if (namedString(request.urlContains)) {
    return `the URL to contain ${JSON.stringify(request.urlContains)}`
  }
  if (namedString(request.selector)) {
    return `selector ${JSON.stringify(request.selector)} to ${request.gone ? 'stop matching' : 'match a visible element'}`
  }
  return `text ${JSON.stringify(request.text)} to ${request.gone ? 'disappear' : 'appear'}`
}

/**
 * One call in place of a caller's sleep-and-poll loop — the mechanics live in
 * pageWait.ts (the navigation-surviving supervisor) and waitScripts.ts (the
 * in-guest watchers); this handler only validates the wire shape, clamps the
 * bounds with the same shared arithmetic main prices the relay from, and
 * turns the outcome into a ControlResponse. On success the elapsed time tells
 * the caller what the page actually took; on timeout the error names the
 * condition that never held, which is the difference between a diagnosis and
 * a shrug.
 */
export async function handleWaitFor(
  webview: WebviewTag,
  request: WaitForRequest
): Promise<ControlResponse> {
  const invalid = waitSpecError(request)
  if (invalid) return { ok: false, error: invalid }
  const timeoutMs = clampWaitTimeout(request.timeoutMs)
  const pollMs = clampWaitPoll(request.pollMs)
  const outcome = await waitForPageCondition(webview, buildPageWaitSpec(request), {
    timeoutMs,
    pollMs,
    // Only the pane's existence — never its mount state, which is transient
    // while a drag reparents the pane and exactly what re-arming survives.
    invalidReason: () => browserPaneError(request.targetPaneId)
  })
  if ('error' in outcome) return { ok: false, error: outcome.error }
  if (!outcome.settled) {
    return {
      ok: false,
      error: `timed out after ${timeoutMs}ms waiting for ${describeWaitCondition(request)}`
    }
  }
  const { settled: _settled, elapsedMs, ...extras } = outcome
  return { ok: true, result: { elapsedMs, ...extras } }
}

type AssertRequest = Extract<BrowserControlRequest, { type: 'assert' }>

/**
 * waitSpecError's twin, kept separate rather than parameterized: the
 * vocabularies differ (no idle here), and each message should name its own
 * verb — a validation error is the one part of a verb an agent quotes back.
 */
function assertSpecError(request: AssertRequest): string | null {
  const conditions = [
    namedString(request.text),
    namedString(request.selector),
    namedString(request.urlContains)
  ].filter(Boolean).length
  if (conditions === 0) {
    return 'assert needs a condition: one of text, selector, urlContains'
  }
  if (conditions > 1) {
    return 'assert takes exactly one condition per call — batch several asserts to combine them'
  }
  if (request.gone === true && !namedString(request.text) && !namedString(request.selector)) {
    return GONE_NEEDS_TARGET
  }
  return null
}

/** The failed premise as prose — the transcript line that says what broke. */
function describeAssertFailure(request: AssertRequest): string {
  if (namedString(request.urlContains)) {
    return `the URL does not contain ${JSON.stringify(request.urlContains)}`
  }
  if (namedString(request.selector)) {
    return request.gone === true
      ? `selector ${JSON.stringify(request.selector)} still matches a visible element`
      : `selector ${JSON.stringify(request.selector)} does not match a visible element`
  }
  return request.gone === true
    ? `page text still contains ${JSON.stringify(request.text)}`
    : `page text does not contain ${JSON.stringify(request.text)}`
}

/**
 * `waitFor`'s single-shot twin: the same conditions, evaluated once, with a
 * failure that *fails the verb* — which is what lets a failing premise stop a
 * batch and be named in its transcript, instead of coming back as data the
 * caller must inspect.
 *
 * Runs through the same supervisor as waitFor on the fixed
 * ASSERT_CHECK_BUDGET_MS rather than injecting a bare one-shot check — the
 * supervisor is what survives an injection refused by a mid-load document and
 * a navigation racing the check, and the in-guest script checks synchronously
 * on arrival, so a condition that holds settles on the first look regardless.
 * See the constant's doc for the tolerance this knowingly grants a condition
 * that arrives late. `elapsedMs` is deliberately not reported: for a bounded
 * check it is machinery noise, where for a wait it is the answer.
 */
export async function handleAssert(
  webview: WebviewTag,
  request: AssertRequest
): Promise<ControlResponse> {
  const invalid = assertSpecError(request)
  if (invalid) return { ok: false, error: invalid }
  const outcome = await waitForPageCondition(webview, buildPageWaitSpec(request), {
    timeoutMs: ASSERT_CHECK_BUDGET_MS,
    pollMs: WAIT_MIN_POLL_MS,
    invalidReason: () => browserPaneError(request.targetPaneId)
  })
  if ('error' in outcome) return { ok: false, error: outcome.error }
  if (!outcome.settled) {
    return { ok: false, error: `assertion failed: ${describeAssertFailure(request)}` }
  }
  const { settled: _settled, elapsedMs: _elapsedMs, ...extras } = outcome
  return { ok: true, result: { ...extras } }
}
