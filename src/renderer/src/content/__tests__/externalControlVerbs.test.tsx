import { CONTROL_REQUEST_TYPES } from '@shared/externalControl'
import { expect, test } from 'vitest'
import { activate as activateBrowser } from '../../../../plugins/browser/renderer/index'
import { createRendererPluginContext } from '../../plugin/context'
import { unhandledControlVerbs } from '../externalControl'

/**
 * The replacement for a compile-time check this refactor gave up.
 *
 * `handleRequest` used to be a `switch` exhaustive over `ControlRequest`, so a
 * verb added to the union without an implementation failed to build. Dispatch
 * is now a Map keyed by verb name, which the compiler cannot check, so the
 * guarantee lives here instead. It is deliberately a *gate*, not a smoke test:
 * it fails on either side of the seam.
 *
 * - A verb added to the protocol that nothing implements → it stays in
 *   `unhandledControlVerbs()` and the coverage assertion fails.
 * - A handler that exists but whose registration never runs → the same
 *   failure, because the browser verbs are reached only through the real
 *   package `activate`, never by calling the registrar directly. Drop that
 *   entry from registerBuiltins' list, or move a verb into a module nothing
 *   invokes, and twenty-one verbs go unanswered here.
 *
 * The terminal is deliberately not registered: it contributes no verbs, and
 * importing it would pull in xterm and its CSS (see registerTerminal.ts). The
 * structural types contribute none either — so the built-ins' entire
 * contribution to this protocol is the browser's, and this file registers
 * exactly that.
 *
 * `.tsx` despite holding no JSX: the vitest `components` project is selected
 * by extension, and this needs jsdom — the modules under test read
 * `window.api` at import time through layoutStore.
 */

// Snapshotted at module scope, before any test can register anything, so the
// two tests below don't depend on each other's order (vitest isolates per
// file, not per test).
const unhandledBeforeRegistration = unhandledControlVerbs()

test('core answers only the verbs that belong to no content type', () => {
  const answeredByCore = CONTROL_REQUEST_TYPES.filter(
    (verb) => !unhandledBeforeRegistration.includes(verb)
  )
  // Guards the split itself: a browser verb drifting back into core's
  // module-scope registrations would show up here — including one main answers
  // alone, which still owes this window a handler and gets it from its own type.
  expect([...answeredByCore].sort()).toEqual(['batch', 'ping'])
})

test('every verb in the wire protocol is answered once the built-in types have registered', () => {
  // Not vacuous: the browser's verbs really are missing beforehand, so the
  // assertion below is proving that registration is what supplies them.
  expect(unhandledBeforeRegistration.length).toBeGreaterThan(0)

  // The same activation registerBuiltins performs, context and all.
  activateBrowser(createRendererPluginContext('browser'))

  expect(unhandledControlVerbs()).toEqual([])
})
