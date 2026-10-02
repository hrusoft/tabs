import type { WebviewTag } from 'electron'
import { WAIT_IDLE_QUIET_MS } from '../shared/externalControl'
import { domIdleScript, type WaitConditionSpec, waitConditionScript } from './waitScripts'

/**
 * The renderer half of `waitFor`: a supervisor over the in-guest wait scripts
 * (waitScripts.ts) that owns everything the guest structurally cannot.
 *
 * The guest polls itself — one `executeJavaScript` round trip per page,
 * however long the wait runs — but three things only this side can provide:
 *
 * - **The deadline.** A hidden guest's timers are throttled, so the guest's
 *   own budget timer can fire arbitrarily late; the host-side deadline here
 *   is exact, and always under main's relay budget for the verb (both derive
 *   from the same clampWaitTimeout — see the shared constants' doc).
 * - **Surviving navigation.** A cross-document navigation destroys the guest
 *   context mid-wait, and the already-pending `executeJavaScript` promise
 *   **never settles — measured directly (twice) with a probe: a pending
 *   promise stayed pending 4s after the guest demonstrably navigated,
 *   neither resolving nor rejecting.** Nothing renderer-side may therefore
 *   await the guest promise alone: every injection is raced against the
 *   guest's disruption events (`did-navigate` for a navigation, `did-attach`
 *   for the guest churning on a pane reparent, `destroyed` for the pane
 *   going away) and re-injected into whatever document emerges, with
 *   whatever budget remains. That is also what the auth-bounce case *needs*
 *   — the condition is satisfied by the page a mid-wait navigation lands on
 *   (pinned by the navigation test in e2e/external-control.spec.ts's
 *   wait-for block).
 * - **Failing fast when the pane vanishes.** `invalidReason` is re-checked
 *   between injections, so a closed pane aborts the wait with the standard
 *   pane-gone error instead of burning the rest of a five-minute budget.
 *
 * An injection that *throws* (a document mid-load, a Chromium error page) is
 * retried on a short host-side delay until the deadline — an error page can
 * still become the requested page when the app behind it comes up.
 *
 * `urlContains` never injects at all: `getURL()` plus the navigation events
 * answer it from this side, which also makes it work against pages script
 * cannot run on. In-page route changes (`did-navigate-in-page`) matter only
 * here — for the guest scripts they are invisible by design, since the
 * context survives them and the MutationObserver keeps watching.
 */

/** An element rect in the guest's CSS-pixel viewport space (readPage's shape). */
interface ElementRect {
  x: number
  y: number
  width: number
  height: number
}

/** What a wait settles to. `ref`/`tag`/`rect` for a selector match, `url` for urlContains. */
type PageWaitOutcome =
  | {
      settled: true
      elapsedMs: number
      ref?: string
      tag?: string
      rect?: ElementRect
      url?: string
    }
  | { settled: false; elapsedMs: number }
  | { error: string }

export interface PageWaitSpec extends WaitConditionSpec {
  urlContains?: string
  idle?: boolean
}

export interface PageWaitOptions {
  timeoutMs: number
  pollMs: number
  /**
   * Re-checked between steps; a non-null answer aborts the wait with that
   * error. The caller's place to say "this pane no longer exists" — transient
   * states (a guest mid-reattach) must answer null, or a pane drag mid-wait
   * would abort a wait that re-arming was about to save.
   */
  invalidReason?: (() => string | null) | undefined
}

/** How long to back off before retrying an injection the guest refused. */
const INJECT_RETRY_MS = 100

/** Sleep, as a promise. Exported because this module already owns the timing machinery. */
export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * Polls `condition` every `everyMs` until it answers true or `deadlineAt`
 * passes, resolving with the final answer. The renderer's bounded busy-waits
 * (a webview mounting, a revealed pane becoming paintable) share this rather
 * than each spelling its own Date.now() loop — five copies of deadline
 * arithmetic is where a negative one eventually appears.
 */
export async function pollUntil(
  condition: () => boolean | Promise<boolean>,
  deadlineAt: number,
  everyMs = 50
): Promise<boolean> {
  let satisfied = await condition()
  while (!satisfied && Date.now() < deadlineAt) {
    await delay(everyMs)
    satisfied = await condition()
  }
  return satisfied
}

/** A cancellable timer as a race participant. */
function timerRace<T>(ms: number, value: T): { promise: Promise<T>; dispose: () => void } {
  let timer: ReturnType<typeof setTimeout> | undefined
  let settle: ((v: T) => void) | undefined
  const promise = new Promise<T>((resolve) => {
    settle = resolve
    timer = setTimeout(() => resolve(value), ms)
  })
  return {
    promise,
    dispose: () => {
      clearTimeout(timer)
      // Settle so an abandoned race participant can't hold the promise chain
      // alive; the race has already been decided by whoever disposed us.
      settle?.(value)
    }
  }
}

/**
 * Resolves on the next event that invalidates the current guest context (or
 * the current URL, for the url wait): a cross-document navigation, the guest
 * being rebuilt on reparent, or destroyed outright. `inPage` adds the
 * same-document route changes only the URL wait cares about.
 */
function nextDisruption(
  webview: WebviewTag,
  inPage: boolean
): { promise: Promise<'disrupted'>; dispose: () => void } {
  let settle: ((v: 'disrupted') => void) | undefined
  const promise = new Promise<'disrupted'>((resolve) => {
    settle = resolve
  })
  const onEvent = (): void => settle?.('disrupted')
  const events = [
    'did-navigate',
    'did-attach',
    'destroyed',
    ...(inPage ? ['did-navigate-in-page'] : [])
  ]
  for (const event of events) webview.addEventListener(event as 'did-navigate', onEvent)
  return {
    promise,
    dispose: () => {
      for (const event of events) webview.removeEventListener(event as 'did-navigate', onEvent)
    }
  }
}

/** What one supervised injection race decided. */
type RaceResult =
  | { kind: 'guest'; value: unknown }
  | { kind: 'thrown' }
  | { kind: 'disrupted' }
  | { kind: 'deadline' }

interface GuestWaitOptions {
  timeoutMs: number
  /** Builds the guest script for however much budget remains at injection. */
  buildScript: (remainingMs: number) => string
  invalidReason?: (() => string | null) | undefined
}

/**
 * The injection loop shared by every guest-script wait: inject with the
 * remaining budget, race the guest's answer against disruption and the
 * deadline, re-inject after a disruption, retry after a refusal, and enforce
 * the deadline host-side throughout.
 */
async function superviseGuestWait(
  webview: WebviewTag,
  options: GuestWaitOptions
): Promise<PageWaitOutcome> {
  const startedAt = Date.now()
  const deadlineAt = startedAt + options.timeoutMs
  const elapsed = (): number => Date.now() - startedAt

  while (true) {
    const invalid = options.invalidReason?.()
    if (invalid) return { error: invalid }
    const remaining = deadlineAt - Date.now()
    if (remaining <= 0) return { settled: false, elapsedMs: elapsed() }

    const disruption = nextDisruption(webview, false)
    const deadline = timerRace<RaceResult>(remaining, { kind: 'deadline' })
    let raced: RaceResult
    try {
      // The guest promise is folded to never reject, so when another branch
      // wins the race the loser can be abandoned without an unhandled
      // rejection — which is also the only safe stance toward a promise that
      // a navigation may have orphaned for good (see the module doc).
      const guest: Promise<RaceResult> = webview
        .executeJavaScript(options.buildScript(remaining))
        .then(
          (value: unknown) => ({ kind: 'guest', value }) as const,
          () => ({ kind: 'thrown' }) as const
        )
      raced = await Promise.race([
        guest,
        disruption.promise.then(() => ({ kind: 'disrupted' }) as const),
        deadline.promise
      ])
    } finally {
      disruption.dispose()
      deadline.dispose()
    }

    switch (raced.kind) {
      case 'guest': {
        const value = raced.value as
          | { settled?: boolean; error?: string; [key: string]: unknown }
          | null
          | undefined
        if (value && typeof value.error === 'string') return { error: value.error }
        if (value && value.settled === true) {
          const { settled: _settled, ...extras } = value
          return { settled: true, elapsedMs: elapsed(), ...extras }
        }
        if (value && value.settled === false) {
          // The guest's own budget ran out; the loop re-checks ours, which
          // in a throttled (hidden) guest can still have time left — if so,
          // re-inject rather than under-waiting.
          continue
        }
        // Not a shape our scripts produce — a hostile page rewrote the
        // answer. Retry on the shared backoff; the deadline bounds it.
        await delay(INJECT_RETRY_MS)
        continue
      }
      case 'thrown':
        await delay(INJECT_RETRY_MS)
        continue
      case 'disrupted':
        // Re-inject into whatever document emerges. If it is still loading,
        // the next injection lands on the 'thrown' backoff above.
        continue
      case 'deadline':
        return { settled: false, elapsedMs: elapsed() }
    }
  }
}

/** The URL wait: renderer-side entirely — see the module doc. */
async function waitForUrlContains(
  webview: WebviewTag,
  needle: string,
  options: PageWaitOptions
): Promise<PageWaitOutcome> {
  const startedAt = Date.now()
  const deadlineAt = startedAt + options.timeoutMs

  while (true) {
    const invalid = options.invalidReason?.()
    if (invalid) return { error: invalid }
    let url: string | undefined
    try {
      url = webview.getURL()
    } catch {
      // Not attached / not dom-ready yet — poll again below.
    }
    if (url?.includes(needle)) {
      return { settled: true, elapsedMs: Date.now() - startedAt, url }
    }
    const remaining = deadlineAt - Date.now()
    if (remaining <= 0) return { settled: false, elapsedMs: Date.now() - startedAt }

    // Event-driven with a poll fallback: the events cover every navigation
    // Chromium announces, the tick covers anything it doesn't.
    const disruption = nextDisruption(webview, true)
    const tick = timerRace(Math.min(options.pollMs, remaining), 'tick' as const)
    try {
      await Promise.race([disruption.promise, tick.promise])
    } finally {
      disruption.dispose()
      tick.dispose()
    }
  }
}

/**
 * Waits until `spec` holds against the pane: exactly one of `text`/`selector`
 * (optionally inverted via `gone`), `urlContains`, or `idle`. The caller
 * validates that shape — this function trusts it and only picks the
 * mechanism. Timeout is reported as `{ settled: false }` with the elapsed
 * time; `{ error }` is reserved for waits that cannot proceed at all (the
 * pane vanished, an invalid selector).
 */
export function waitForPageCondition(
  webview: WebviewTag,
  spec: PageWaitSpec,
  options: PageWaitOptions
): Promise<PageWaitOutcome> {
  if (spec.urlContains !== undefined) {
    return waitForUrlContains(webview, spec.urlContains, options)
  }
  if (spec.idle) {
    return superviseGuestWait(webview, {
      timeoutMs: options.timeoutMs,
      buildScript: (remainingMs) => domIdleScript(WAIT_IDLE_QUIET_MS, remainingMs),
      invalidReason: options.invalidReason
    })
  }
  return superviseGuestWait(webview, {
    timeoutMs: options.timeoutMs,
    buildScript: (remainingMs) => waitConditionScript(spec, remainingMs, options.pollMs),
    invalidReason: options.invalidReason
  })
}
