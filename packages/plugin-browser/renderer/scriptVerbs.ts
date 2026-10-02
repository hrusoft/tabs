import type { ControlResponse } from '@tabs/plugin-sdk/shared/externalControl'
import { compilePattern, patternFilterError } from '@tabs/plugin-sdk/shared/ringLog'
import type { WebviewTag } from 'electron'
import type { BrowserControlRequest } from '../shared/externalControl'
import { EXECUTE_OUTPUT_KEY, EXECUTE_RESULT_MAX } from '../shared/externalControl'
import { executeScript } from './pageScripts'
import { resolveBrowserHandle } from './verbSupport'

/**
 * The page's own script surface: running caller code in it, and reading back
 * what it logged.
 */

/**
 * Runs caller-supplied code in the guest page and returns its value.
 *
 * Two failure modes are turned into clean errors rather than letting them
 * escape: the script throwing (a rejected promise from `executeJavaScript`),
 * and it returning something JSON can't represent (a DOM node, a circular
 * object). The latter matters because the value has a long way still to
 * travel — across contextBridge to main, then through `JSON.stringify` onto
 * the socket — and failing at the far end would surface as an unhelpful
 * serialization error instead of "your script returned a DOM node".
 *
 * Note this runs in the page's *own* main world; `<webview>`'s
 * executeJavaScript has no isolated-world option. See pageScripts.ts.
 */
export async function handleExecuteJavaScript(
  webview: WebviewTag,
  request: Extract<BrowserControlRequest, { type: 'executeJavaScript' }>
): Promise<ControlResponse> {
  let outcome: { ok: true; value: unknown } | { ok: false; error: string }
  try {
    outcome = await webview.executeJavaScript(executeScript(request.code))
  } catch {
    // Runtime throws are caught inside the guest by executeScript, so the only
    // way to land here is code that isn't a valid expression — and Electron's
    // own message for that says nothing useful, so it isn't repeated.
    return {
      ok: false,
      error:
        'the code is not a valid expression — wrap a sequence of statements in an IIFE, e.g. (() => { ... })()'
    }
  }
  if (!outcome.ok) return { ok: false, error: `script threw: ${outcome.error}` }
  const value = outcome.value

  // File output requested: hand main the *full* serialization instead of
  // applying the cap — the caller asked for a file precisely because the
  // value is large. A plain string goes raw (`text`): the common case is an
  // extracted document, and a JSON-quoted file would force every caller to
  // unquote it. Anything else is pretty-printed JSON (`json`), still valid
  // for a parser; `undefined` keeps its inline-path meaning as JSON null.
  //
  // Answered before the compact serialization below, not after it: this branch
  // never looks at that string, and building it anyway would cost a second
  // full copy of exactly the large values `--out` exists for (a 30MB result
  // measured at ~25ms of wasted renderer main-thread time). The pretty form
  // refuses a cycle or a DOM node identically, so the friendly error below is
  // unchanged — it just arrives from whichever stringify ran.
  let serialized: string | undefined
  try {
    serialized =
      request.outPath !== undefined
        ? typeof value === 'string'
          ? value
          : JSON.stringify(value ?? null, null, 2)
        : JSON.stringify(value)
  } catch {
    return {
      ok: false,
      error: 'the script returned a value that cannot be serialized (a DOM node, or a cycle)'
    }
  }
  if (request.outPath !== undefined) {
    return {
      ok: true,
      result: {
        [EXECUTE_OUTPUT_KEY]: serialized,
        format: typeof value === 'string' ? 'text' : 'json',
        truncated: false
      }
    }
  }
  if (serialized !== undefined && serialized.length > EXECUTE_RESULT_MAX) {
    return {
      ok: true,
      result: { value: serialized.slice(0, EXECUTE_RESULT_MAX), truncated: true }
    }
  }
  // `undefined` (a script ending in a statement, or returning a function)
  // has no JSON form; report it as null rather than dropping the key, so a
  // caller can tell "ran, returned nothing" from "no result field".
  return { ok: true, result: { value: value === undefined ? null : value, truncated: false } }
}

/**
 * Console output captured for the pane's current page. Resolves the pane
 * handle itself (the one verb that doesn't go through `withWebview`) because
 * it reads the handle rather than driving the guest: the buffer is filled by
 * the `<webview>` element's own `console-message` events as they happen — a
 * page's console history isn't something the page can be asked for after the
 * fact.
 */
export function handleReadConsoleMessages(
  request: Extract<BrowserControlRequest, { type: 'readConsoleMessages' }>
): ControlResponse {
  const resolved = resolveBrowserHandle(request.targetPaneId)
  if ('error' in resolved) return { ok: false, error: resolved.error }
  const patternError = patternFilterError(request.pattern)
  if (patternError !== undefined) return { ok: false, error: patternError }
  const matches = compilePattern(request.pattern)
  const messages = resolved.handle
    .consoleMessages(request.sinceSeq)
    .filter((entry) => matches(entry.text))
  return { ok: true, result: { messages } }
}
