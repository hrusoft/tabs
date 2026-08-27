import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  closeAgentSession,
  createAgentPane,
  deadOrigin,
  expectRefusedForForeignPane,
  openAgentSession,
  runTabsCtl
} from './helpers/agentSession'
import { guestText } from './helpers/guest'
import { expect, test } from './helpers/launch'
import { paneById } from './helpers/pane'
import { testServerForSpec } from './helpers/testServer'

// Scripting and flow: execute-js, batch, wait-for, assert, and the
// navigation verbs. Session scaffolding is helpers/agentSession.ts.

/**
 * One fixture origin for the whole file — see helpers/testServer.ts for why
 * these tests can't use the `data:` URLs browser.spec.ts relies on.
 */
const server = testServerForSpec()

test('an agent can run script in a pane and fill a form, and gets clean errors when it cannot', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  const sum = await runTabsCtl(['execute-js', '--pane', paneId, '--code', '1 + 1'], env)
  expect(sum.result?.value).toBe(2)

  // A structured value, and one that proves the script ran in the real page.
  const title = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', '({ title: document.title })'],
    env
  )
  expect(title.result?.value).toEqual({ title: 'Fixture' })

  // A promise is awaited rather than returned as a pending object.
  const awaited = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', 'Promise.resolve("resolved")'],
    env
  )
  expect(awaited.result?.value).toBe('resolved')

  // A script that throws fails with its *own* message, not Electron's opaque
  // "Script failed to execute" — that's the whole point of catching in-guest.
  const threw = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', '(() => { throw new Error("deliberate") })()'],
    env
  )
  expect(threw.ok).toBe(false)
  expect(threw.error).toContain('deliberate')

  // Code that isn't an expression is told so, actionably.
  const statement = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', 'const x = 1; x'],
    env
  )
  expect(statement.ok).toBe(false)
  expect(statement.error).toContain('IIFE')

  // So does one returning something JSON cannot represent.
  const circular = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', '(() => { const a = {}; a.self = a; return a })()'],
    env
  )
  expect(circular.ok).toBe(false)
  expect(circular.error).toContain('cannot be serialized')

  // A DOM node — the shape a caller is most likely to reach for by accident —
  // does *not* error: Electron flattens it during its own result
  // serialization, so what arrives is an ordinary (useless) object rather
  // than a node. Pinned so the docs' advice to return a property instead of
  // an element stays accurate.
  const node = await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'document.body'], env)
  expect(node.ok).toBe(true)
  expect(node.result?.value).toEqual({})

  // form-input replaces a field's contents rather than appending to them.
  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const field = read.result?.elements?.find((el) => el.name === 'Your name')
  if (!field) throw new Error('readPage did not surface the name field')

  await runTabsCtl(['type', '--pane', paneId, '--ref', field.ref, '--text', 'stale'], env)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:stale')

  const filled = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: field.ref }, value: 'grace' }])
    ],
    env
  )
  expect(filled.ok).toBe(true)
  expect(filled.result?.filled).toBe(1)
  // 'grace', not 'stalegrace' — the previous value was selected and replaced.
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:grace')

  // A field that can't be focused is reported and skipped, not fatal.
  const partial = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([
        { target: { ref: 'not-a-real-ref' }, value: 'x' },
        { target: { ref: field.ref }, value: 'ada' }
      ])
    ],
    env
  )
  expect(partial.result?.filled).toBe(1)
  expect(partial.result?.errors).toHaveLength(1)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:ada')

  await closeAgentSession(page, env, paneId)
})

test('scripting verbs refuse a pane this caller does not own', async ({ page }) => {
  await expectRefusedForForeignPane(page, (foreign) => [
    ['execute-js', '--pane', foreign, '--code', 'document.title'],
    ['form-input', '--pane', foreign, '--fields', '[]']
  ])
})

test('a batch runs its requests in order, stops at the first failure, and refuses nesting', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const button = read.result?.elements?.find((el) => el.name === 'Do the thing')
  if (!button) throw new Error('readPage did not surface the button')

  // Ordering is the point: the click must land before the text is read back.
  const batched = await runTabsCtl(
    [
      'batch',
      '--requests',
      JSON.stringify([
        { type: 'click', targetPaneId: paneId, target: { ref: button.ref } },
        { type: 'getPageText', targetPaneId: paneId }
      ])
    ],
    env
  )
  expect(batched.ok).toBe(true)
  expect(batched.exitCode).toBe(0)
  const steps = batched.result?.steps
  expect(steps).toHaveLength(2)
  // The transcript names what ran and how long it took, per step.
  expect(steps?.map((step) => step.type)).toEqual(['click', 'getPageText'])
  for (const step of steps ?? []) {
    expect(step.ok).toBe(true)
    expect(step.durationMs).toBeGreaterThanOrEqual(0)
  }
  expect(steps?.[1]?.result?.text).toContain('clicked')

  // A failing step stops the batch, and the caller can see exactly where: the
  // transcript stays aligned to what was sent, with the unrun tail marked
  // skipped rather than absent.
  const stopped = await runTabsCtl(
    [
      'batch',
      '--requests',
      JSON.stringify([
        { type: 'getPaneInfo', targetPaneId: paneId },
        { type: 'click', targetPaneId: paneId, target: { ref: 'not-a-real-ref' } },
        { type: 'getPageText', targetPaneId: paneId }
      ])
    ],
    env
  )
  expect(stopped.result?.stoppedAt).toBe(1)
  expect(stopped.exitCode).toBe(1)
  expect(stopped.result?.steps).toHaveLength(3)
  expect(stopped.result?.steps?.[0]?.ok).toBe(true)
  expect(stopped.result?.steps?.[1]?.ok).toBe(false)
  expect(stopped.result?.steps?.[2]).toEqual({ type: 'getPageText', skipped: true })

  // --continue-on-error runs the same sequence to the end: the failure stays
  // visible in its step, nothing is skipped, and the exit code still reports.
  const continued = await runTabsCtl(
    [
      'batch',
      '--continue-on-error',
      '--requests',
      JSON.stringify([
        { type: 'getPaneInfo', targetPaneId: paneId },
        { type: 'click', targetPaneId: paneId, target: { ref: 'not-a-real-ref' } },
        { type: 'getPageText', targetPaneId: paneId }
      ])
    ],
    env
  )
  expect(continued.ok).toBe(true)
  expect(continued.exitCode).toBe(1)
  expect(continued.result?.stoppedAt).toBeUndefined()
  expect(continued.result?.steps).toHaveLength(3)
  expect(continued.result?.steps?.[1]?.ok).toBe(false)
  expect(continued.result?.steps?.[2]?.ok).toBe(true)
  expect(continued.result?.steps?.[2]?.result?.text).toContain('clicked')

  // A sub-request naming somebody else's pane is refused like any other.
  const foreign = await runTabsCtl(
    [
      'batch',
      '--requests',
      JSON.stringify([{ type: 'getPageText', targetPaneId: env.TABS_PANE_ID }])
    ],
    env
  )
  expect(foreign.result?.steps?.[0]?.error).toContain('not the owner')

  for (const [label, sub] of [
    ['nested batch', { type: 'batch', requests: [] }],
    ['createBrowserPane', { type: 'createBrowserPane', url: 'about:blank' }]
  ] as const) {
    const rejected = await runTabsCtl(['batch', '--requests', JSON.stringify([sub])], env)
    expect(rejected.ok, `${label} should be refused`).toBe(false)
  }

  await closeAgentSession(page, env, paneId)
})

/**
 * The wait-for tests drive every change *from the test* through the /waity
 * fixture's helpers (see testServer.ts) rather than from page-side timers, so
 * "the wait was already pending when the condition arrived" is a matter of
 * test-side sequencing: start the wait, give its subprocess a generous head
 * start, then trigger the change. The elapsedMs floors assert exactly that
 * pendingness — they are sized to the head start, not to guessed page timing.
 */
test('wait-for resolves when text appears and hands back a usable ref for a selector match', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Text: the wait is pending (started, plus a head start) before the text
  // exists; one call blocks until it appears and reports how long that took.
  const textWait = runTabsCtl(
    ['wait-for', '--pane', paneId, '--text', 'MAGIC_DONE', '--timeout', '30000'],
    env
  )
  await page.waitForTimeout(1000)
  await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', 'window.appendReady("MAGIC_DONE")'],
    env
  )
  const textResult = await textWait
  expect(textResult.ok).toBe(true)
  expect(textResult.result?.elapsedMs).toBeGreaterThanOrEqual(500)
  expect(textResult.result?.elapsedMs).toBeLessThan(30000)

  // A selector only matches what the page shows: #panel is in the DOM but
  // display:none, so a bounded wait for it times out naming the condition.
  const hidden = await runTabsCtl(
    ['wait-for', '--pane', paneId, '--selector', '#panel', '--timeout', '1200'],
    env
  )
  expect(hidden.ok).toBe(false)
  expect(hidden.error).toContain('timed out after 1200ms')
  expect(hidden.error).toContain('#panel')

  // Revealed mid-wait, the match reports a readPage-compatible ref — which
  // the natural next step (click it) uses with no read-page round trip.
  const selectorWait = runTabsCtl(
    ['wait-for', '--pane', paneId, '--selector', '#panel', '--timeout', '30000'],
    env
  )
  await page.waitForTimeout(1000)
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.revealPanel()'], env)
  const selectorResult = await selectorWait
  expect(selectorResult.ok).toBe(true)
  expect(selectorResult.result?.tag).toBe('div')
  expect(selectorResult.result?.rect?.width).toBeGreaterThan(0)
  const ref = selectorResult.result?.ref
  expect(ref).toBeTruthy()
  const clicked = await runTabsCtl(['click', '--pane', paneId, '--ref', ref as string], env)
  expect(clicked.ok).toBe(true)
  expect(clicked.result?.element?.tag).toBe('div')

  await closeAgentSession(page, env, paneId)
})

test('wait-for --gone waits out a spinner, and validates its condition shape loudly', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The spinner is visible now, so the inverted condition does not hold yet;
  // hiding it (display:none — gone by the visibility rule, though still in
  // the DOM) is what resolves the wait.
  const goneWait = runTabsCtl(
    ['wait-for', '--pane', paneId, '--selector', '#spinner', '--gone', '--timeout', '30000'],
    env
  )
  await page.waitForTimeout(1000)
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.hideSpinner()'], env)
  const goneResult = await goneWait
  expect(goneResult.ok).toBe(true)
  expect(goneResult.result?.elapsedMs).toBeGreaterThanOrEqual(500)

  // A wait that never holds fails at its bound, naming the condition — and
  // the caller really did wait that long (the relay didn't fire first).
  const before = Date.now()
  const timedOut = await runTabsCtl(
    ['wait-for', '--pane', paneId, '--text', 'NEVER_THERE', '--timeout', '1500'],
    env
  )
  expect(Date.now() - before).toBeGreaterThanOrEqual(1500)
  expect(timedOut.ok).toBe(false)
  expect(timedOut.error).toContain('timed out after 1500ms')
  expect(timedOut.error).toContain('"NEVER_THERE"')
  expect(timedOut.error).toContain('appear')

  // The wire shape is validated before anything waits: no condition, two
  // conditions, and gone without something to invert are each named.
  const none = await runTabsCtl(['wait-for', '--pane', paneId], env)
  expect(none.ok).toBe(false)
  expect(none.error).toContain('needs a condition')
  const two = await runTabsCtl(['wait-for', '--pane', paneId, '--text', 'x', '--idle'], env)
  expect(two.ok).toBe(false)
  expect(two.error).toContain('exactly one condition')
  const badGone = await runTabsCtl(['wait-for', '--pane', paneId, '--idle', '--gone'], env)
  expect(badGone.ok).toBe(false)
  expect(badGone.error).toContain('gone inverts')

  await closeAgentSession(page, env, paneId)
})

test('wait-for survives the page navigating mid-wait, and --url-contains rides navigation', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The URL wait: pending well before the test steers the page elsewhere.
  const urlWait = runTabsCtl(
    ['wait-for', '--pane', paneId, '--url-contains', '/other', '--timeout', '30000'],
    env
  )
  await page.waitForTimeout(1000)
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'location.href = "/other"'], env)
  const urlResult = await urlWait
  expect(urlResult.ok).toBe(true)
  expect(urlResult.result?.url).toContain('/other')
  expect(urlResult.result?.elapsedMs).toBeGreaterThanOrEqual(500)

  // The load-bearing case for the in-guest waits: a cross-document navigation
  // destroys the guest context holding the watcher (and strands the pending
  // executeJavaScript — measured: it never settles either way), so only the
  // supervisor's re-injection can let this resolve. The condition's text
  // exists solely on the page the mid-wait navigation lands on.
  await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url('/waity')], env)
  const acrossNav = runTabsCtl(
    ['wait-for', '--pane', paneId, '--text', 'Elsewhere', '--timeout', '30000'],
    env
  )
  await page.waitForTimeout(1000)
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'location.href = "/other"'], env)
  const acrossResult = await acrossNav
  expect(acrossResult.ok).toBe(true)
  expect(acrossResult.result?.elapsedMs).toBeGreaterThanOrEqual(500)

  await closeAgentSession(page, env, paneId)
})

test('wait-for --idle settles only once the DOM stops churning', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The churn is already running when the wait starts, and keeps mutating for
  // ~2.5s more; idle may only resolve after the churn ends plus the quiet
  // period, so a resolution under the churn's remaining span means the quiet
  // clock fired mid-churn — the failure this test exists to catch.
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.churn(2500)'], env)
  const idleResult = await runTabsCtl(
    ['wait-for', '--pane', paneId, '--idle', '--timeout', '30000'],
    env
  )
  expect(idleResult.ok).toBe(true)
  expect(idleResult.result?.elapsedMs).toBeGreaterThanOrEqual(1000)
  expect(idleResult.result?.elapsedMs).toBeLessThan(15000)

  await closeAgentSession(page, env, paneId)
})

test('wait-for composes inside a batch on its own per-request budget', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // click-wait-read as one call, with the wait sized past the 5s default
  // relay budget on purpose: a sub-request priced by the batch's own budget
  // (or the default) instead of the wait's function-form budget would time
  // out at 5s, so the ~6.5s elapsed here is the arithmetic composing.
  const batched = await runTabsCtl(
    [
      'batch',
      '--requests',
      JSON.stringify([
        {
          type: 'executeJavaScript',
          targetPaneId: paneId,
          code: '(setTimeout(() => window.appendReady("BATCH_DONE"), 6500), true)'
        },
        { type: 'waitFor', targetPaneId: paneId, text: 'BATCH_DONE', timeoutMs: 30000 },
        { type: 'getPageText', targetPaneId: paneId }
      ])
    ],
    env
  )
  expect(batched.ok).toBe(true)
  expect(batched.result?.stoppedAt).toBeUndefined()
  const steps = batched.result?.steps
  expect(steps).toHaveLength(3)
  expect(steps?.[1]?.ok).toBe(true)
  expect(steps?.[1]?.result?.elapsedMs).toBeGreaterThan(5000)
  // The transcript's own timing agrees with the wait it wraps.
  expect(steps?.[1]?.durationMs).toBeGreaterThan(5000)
  expect(steps?.[2]?.result?.text).toContain('BATCH_DONE')

  await closeAgentSession(page, env, paneId)
})

test('assert checks a condition right now: pass with a usable ref, fail naming the premise', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Text that is on the page: holds, exit 0.
  const pass = await runTabsCtl(['assert', '--pane', paneId, '--text', 'spinner is spinning'], env)
  expect(pass.ok).toBe(true)
  expect(pass.exitCode).toBe(0)

  // A selector match hands back a ref, like wait-for's — so "assert it's
  // there, then click it" needs no separate read-page.
  const matched = await runTabsCtl(['assert', '--pane', paneId, '--selector', '#spinner'], env)
  expect(matched.ok).toBe(true)
  expect(matched.result?.ref).toMatch(/^e\d+$/)
  expect(matched.result?.tag).toBe('div')

  // #panel exists but is hidden, so asserting it fails — quickly (the fixed
  // check budget, nowhere near wait-for's 10s default) and naming the
  // premise, which is what a batch transcript surfaces.
  const started = Date.now()
  const failed = await runTabsCtl(['assert', '--pane', paneId, '--selector', '#panel'], env)
  expect(failed.ok).toBe(false)
  expect(failed.exitCode).toBe(1)
  expect(failed.error).toContain('assertion failed')
  expect(failed.error).toContain('#panel')
  expect(Date.now() - started).toBeLessThan(8000)

  // --gone inverts: the spinner is showing, so asserting it gone fails...
  const goneFailed = await runTabsCtl(
    ['assert', '--pane', paneId, '--selector', '#spinner', '--gone'],
    env
  )
  expect(goneFailed.ok).toBe(false)
  expect(goneFailed.error).toContain('still matches')
  // ...and holds once the page hides it.
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.hideSpinner()'], env)
  const gonePass = await runTabsCtl(
    ['assert', '--pane', paneId, '--selector', '#spinner', '--gone'],
    env
  )
  expect(gonePass.ok).toBe(true)

  // The URL condition works both ways too.
  const url = await runTabsCtl(['assert', '--pane', paneId, '--url-contains', '/waity'], env)
  expect(url.ok).toBe(true)
  expect(url.result?.url).toContain('/waity')
  const urlFailed = await runTabsCtl(
    ['assert', '--pane', paneId, '--url-contains', '/nowhere'],
    env
  )
  expect(urlFailed.ok).toBe(false)
  expect(urlFailed.error).toContain('assertion failed')

  // Condition-shape validation mirrors wait-for's, naming its own verb.
  const none = await runTabsCtl(['assert', '--pane', paneId], env)
  expect(none.error).toContain('assert needs a condition')
  const two = await runTabsCtl(['assert', '--pane', paneId, '--text', 'x', '--selector', '#y'], env)
  expect(two.error).toContain('exactly one condition')

  await closeAgentSession(page, env, paneId)
})

test('an assert step makes a batch self-verifying: the transcript names the premise that broke', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  const batched = await runTabsCtl(
    [
      'batch',
      '--requests',
      JSON.stringify([
        { type: 'assert', targetPaneId: paneId, text: 'spinner is spinning' },
        { type: 'assert', targetPaneId: paneId, text: 'NOT_ON_THIS_PAGE' },
        { type: 'getPageText', targetPaneId: paneId }
      ])
    ],
    env
  )
  expect(batched.ok).toBe(true)
  expect(batched.exitCode).toBe(1)
  expect(batched.result?.stoppedAt).toBe(1)
  const steps = batched.result?.steps
  expect(steps?.[0]?.ok).toBe(true)
  expect(steps?.[1]?.error).toContain('assertion failed')
  expect(steps?.[1]?.error).toContain('NOT_ON_THIS_PAGE')
  expect(steps?.[2]).toEqual({ type: 'getPageText', skipped: true })

  await closeAgentSession(page, env, paneId)
})

test('navigation verbs wait for the page and report load failures by name', async ({ page }) => {
  const { env } = await openAgentSession(page)

  // Creation's own result is the subject here, so no createAgentPane.
  const created = await runTabsCtl(['create-browser-pane', '--url', server.url()], env)
  const paneId = created.result?.paneId
  if (!paneId) throw new Error('createBrowserPane did not return a paneId')
  // The create itself waited for the fixture page — no polling needed.
  expect(created.result?.loaded).toBe(true)
  const text = await runTabsCtl(['get-page-text', '--pane', paneId], env)
  expect(text.result?.text).toContain('Hello from the fixture')

  // A connection-refused load is a hard failure with the Chromium code in the
  // error — the "is my dev server actually up" answer an agent needs.
  const dead = await deadOrigin()
  const refused = await runTabsCtl(['navigate', '--pane', paneId, '--url', dead], env)
  expect(refused.ok).toBe(false)
  expect(refused.error).toContain('ERR_CONNECTION_REFUSED')

  // A 404 is a *successful* load of an error page, not a load failure.
  const missing = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/missing')],
    env
  )
  expect(missing.ok).toBe(true)
  expect(missing.result?.loaded).toBe(true)

  // Creating a pane against a dead origin still yields the pane, with the
  // failure reported alongside rather than instead of the paneId.
  const deadPane = await runTabsCtl(['create-browser-pane', '--url', dead], env)
  expect(deadPane.ok).toBe(true)
  expect(deadPane.result?.loaded).toBe(false)
  expect(deadPane.result?.loadError).toContain('ERR_CONNECTION_REFUSED')

  for (const id of [paneId, deadPane.result?.paneId]) {
    if (id) await runTabsCtl(['close-pane', '--pane', id], env)
  }
  await closeAgentSession(page, env)
})

test('reload and history verbs settle on the page they land on', async ({ page, electronApp }) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  // Mutate page state, then reload: the state must be gone, proving a real
  // fresh document rather than an ok that raced the old one.
  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const button = read.result?.elements?.find((el) => el.name === 'Do the thing')
  if (!button) throw new Error('readPage did not surface the button')
  await runTabsCtl(['click', '--pane', paneId, '--ref', button.ref], env)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('clicked')

  const reloaded = await runTabsCtl(['reload', '--pane', paneId], env)
  expect(reloaded.ok).toBe(true)
  expect(reloaded.result?.loaded).toBe(true)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url('/other')], env)
  const back = await runTabsCtl(['go-back', '--pane', paneId], env)
  expect(back.ok).toBe(true)
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.title)
    .toBe('Fixture')

  const forward = await runTabsCtl(['go-forward', '--pane', paneId], env)
  expect(forward.ok).toBe(true)
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.title)
    .toBe('Elsewhere')

  // The history edge is an error that says which way was empty, not a no-op.
  const tooFar = await runTabsCtl(['go-forward', '--pane', paneId], env)
  expect(tooFar.ok).toBe(false)
  expect(tooFar.error).toContain('no later page')

  await closeAgentSession(page, env, paneId)
})

test('navigation verbs report where the pane actually ended up', async ({ page }) => {
  const { env } = await openAgentSession(page)

  // Creation's own reporting is part of the subject, so no createAgentPane.
  // The first load server-redirects: loaded says a load settled, url says
  // where it actually went, redirected says it wasn't the URL asked for —
  // the old shape answered {loaded: true} alone and read as success.
  const created = await runTabsCtl(['create-browser-pane', '--url', server.url('/redirect')], env)
  const paneId = created.result?.paneId
  if (!paneId) throw new Error('createBrowserPane did not return a paneId')
  expect(created.result?.loaded).toBe(true)
  expect(created.result?.url).toBe(server.url('/other'))
  expect(created.result?.title).toBe('Elsewhere')
  expect(created.result?.redirected).toBe(true)
  // The status describes the landing document, not the 302 hop.
  expect(created.result?.status).toBe(200)

  // navigate through the same redirect reports the same trio — and the URL
  // comes back absolute even though the Location header was relative.
  const bounced = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/redirect')],
    env
  )
  expect(bounced.ok).toBe(true)
  expect(bounced.result?.loaded).toBe(true)
  expect(bounced.result?.url).toBe(server.url('/other'))
  expect(bounced.result?.title).toBe('Elsewhere')
  expect(bounced.result?.redirected).toBe(true)
  expect(bounced.result?.status).toBe(200)

  // A straight load answers redirected: false — the caller never has to
  // string-compare to learn nothing surprising happened.
  const straight = await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url()], env)
  expect(straight.result?.loaded).toBe(true)
  expect(straight.result?.url).toBe(server.url())
  expect(straight.result?.redirected).toBe(false)
  expect(straight.result?.status).toBe(200)
  // The fixture titles itself with a real <title>, so no fallback flag.
  expect(straight.result?.titleFromUrl).toBeUndefined()

  // reload and history report the landing page too, with no redirected —
  // there is no requested URL to compare against.
  const reloaded = await runTabsCtl(['reload', '--pane', paneId], env)
  expect(reloaded.result?.url).toBe(server.url())
  expect(reloaded.result?.title).toBe('Fixture')
  expect(reloaded.result?.redirected).toBeUndefined()
  expect(reloaded.result?.status).toBe(200)
  const back = await runTabsCtl(['go-back', '--pane', paneId], env)
  expect(back.result?.url).toBe(server.url('/other'))
  expect(back.result?.title).toBe('Elsewhere')

  // A 404 loads "successfully" — an error page is a page — so status, not
  // loaded, is what answers "is this page real". This used to cost a
  // follow-up read-network: the answer was {loaded: true} and nothing else.
  const missing = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/missing')],
    env
  )
  expect(missing.result?.loaded).toBe(true)
  expect(missing.result?.status).toBe(404)
  expect(missing.result?.statusText).toBe('Not Found')
  // A plain-text 404 page never titles itself either.
  expect(missing.result?.titleFromUrl).toBe(true)

  await closeAgentSession(page, env, paneId)
})

test('--retry-on-redirect re-asserts the requested URL once after a bounce', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  // Without the flag the bounce is reported, never fought: the answer names
  // where the pane went, and re-asserting the deep link is the caller's call.
  const deep = server.url(`/bounce-once/no-retry-${Date.now()}`)
  const reported = await runTabsCtl(['navigate', '--pane', paneId, '--url', deep], env)
  expect(reported.ok).toBe(true)
  expect(reported.result?.url).toBe(server.url('/other'))
  expect(reported.result?.redirected).toBe(true)
  expect(reported.result?.retried).toBeUndefined()

  // With it: one automatic re-issue lands the deep link, and both attempts'
  // landings are visible — the final one top-level, the bounce as firstUrl.
  const deepRetry = server.url(`/bounce-once/retry-${Date.now()}`)
  const retried = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', deepRetry, '--retry-on-redirect'],
    env
  )
  expect(retried.ok).toBe(true)
  expect(retried.result?.loaded).toBe(true)
  expect(retried.result?.url).toBe(deepRetry)
  expect(retried.result?.title).toBe('Deep link')
  expect(retried.result?.redirected).toBe(false)
  expect(retried.result?.retried).toBe(true)
  expect(retried.result?.firstUrl).toBe(server.url('/other'))

  // A page that redirects every time still earns exactly one retry, and the
  // answer says the redirect stood.
  const always = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/redirect'), '--retry-on-redirect'],
    env
  )
  expect(always.result?.url).toBe(server.url('/other'))
  expect(always.result?.redirected).toBe(true)
  expect(always.result?.retried).toBe(true)
  expect(always.result?.firstUrl).toBe(server.url('/other'))

  await closeAgentSession(page, env, paneId)
})

test('a title the page sets after load-settle is flagged as a URL fallback', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  // The SPA shape: no <title> in the HTML, the real one set by script after
  // the load settles. The verb answers at settle — deliberately not waiting
  // out the page's own timers — so its title is Chromium's URL-derived
  // fallback, and titleFromUrl is what says so; without it the caller cannot
  // tell that title from a page genuinely titled "127.0.0.1:PORT/late-title".
  const late = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/late-title')],
    env
  )
  expect(late.result?.loaded).toBe(true)
  expect(late.result?.titleFromUrl).toBe(true)
  expect(late.result?.title).not.toBe('Set later')

  // The live title lands moments later exactly where the flag points.
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.title)
    .toBe('Set later')

  await closeAgentSession(page, env, paneId)
})

test('titleFromUrl is correct on reload and history steps, not only navigate', async ({ page }) => {
  const { env } = await openAgentSession(page)

  // Starts on a URL-derived page so the very first read exercises the flag.
  const paneId = await createAgentPane(env, '--url', server.url('/missing'))

  // The bug: titleFromUrl was tracked off `page-title-updated`, an event
  // Chromium fires only when a document's title *changes* from what was
  // already showing — reset unconditionally on every committed navigation
  // by `did-frame-navigate`, but only ever set back by that event. A reload
  // (or a history step landing on a page sharing its predecessor's title)
  // routinely leaves the title unchanged, so the event never refires and the
  // flag reports the *previous* document's explicitness — exactly inverted
  // for reload, and wrong for go-back/go-forward whenever the title
  // happens to coincide. Measured directly against the real renderer
  // <webview> events before the fix. The fix reads document.title straight
  // out of the guest instead, which has no such gap.
  const missing = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/missing')],
    env
  )
  expect(missing.result?.titleFromUrl).toBe(true)

  const other = await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url('/other')], env)
  expect(other.result?.title).toBe('Elsewhere')
  expect(other.result?.titleFromUrl).toBeUndefined()

  // Reload of an explicit-title page whose title does not change — the
  // case that read as titleFromUrl: true before the fix.
  const reloadedOther = await runTabsCtl(['reload', '--pane', paneId], env)
  expect(reloadedOther.result?.title).toBe('Elsewhere')
  expect(reloadedOther.result?.titleFromUrl).toBeUndefined()

  const backToMissing = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', server.url('/missing')],
    env
  )
  expect(backToMissing.result?.titleFromUrl).toBe(true)

  // Reload of a URL-derived page — also unchanged, also must stay flagged.
  const reloadedMissing = await runTabsCtl(['reload', '--pane', paneId], env)
  expect(reloadedMissing.result?.titleFromUrl).toBe(true)

  // go-back lands on the explicit-title page — the flag must clear.
  const back = await runTabsCtl(['go-back', '--pane', paneId], env)
  expect(back.result?.title).toBe('Elsewhere')
  expect(back.result?.titleFromUrl).toBeUndefined()

  // go-forward lands back on the URL-derived page — the flag must set.
  const forward = await runTabsCtl(['go-forward', '--pane', paneId], env)
  expect(forward.result?.titleFromUrl).toBe(true)

  await closeAgentSession(page, env, paneId)
})

test('a page script cannot steer an agent pane outside the scheme allowlist', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  // The verb-level check is the front door; this is the back door — a
  // navigation the *page* starts. Without the will-navigate guard this loads
  // the local file and get-page-text becomes a local file reader.
  const escaped = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', "(location.href = 'file:///etc/hosts')"],
    env
  )
  expect(escaped.ok).toBe(true)

  // Asserting nothing changed needs a bounded wait, not a poll-until.
  await page.waitForTimeout(500)
  const info = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(info.result?.url).toBe(server.url())
  const text = await runTabsCtl(['get-page-text', '--pane', paneId], env)
  expect(text.result?.text).toContain('Hello from the fixture')

  await closeAgentSession(page, env, paneId)
})

test('execute-js --out writes the full result to a file instead of truncating', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  // Bare --out: a generated path in the app's swept directory. A string
  // result lands raw — the file is the document, not a JSON quotation of it —
  // and in full, past the cap the inline path would have applied.
  const text = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', "'x'.repeat(60000)", '--out'],
    env
  )
  expect(text.ok, text.error).toBe(true)
  expect(text.result?.truncated).toBe(false)
  expect(text.result?.format).toBe('text')
  expect(text.result?.bytes).toBe(60000)
  // The value never rides the socket on this path — only the path does.
  expect(text.result?.value).toBeUndefined()
  expect(text.result?.serializedResult).toBeUndefined()
  const generated = text.result?.path
  if (!generated) throw new Error('execute-js --out did not return a path')
  expect(generated).toContain('agent-output')
  expect(generated.endsWith('.txt')).toBe(true)
  expect(readFileSync(generated, 'utf8')).toBe('x'.repeat(60000))

  // --out <path>: written exactly there (tabs-ctl resolves against the
  // caller's cwd; this one is already absolute), pretty-printed JSON for a
  // non-string value, parseable as-is.
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-exec-'))
  const outPath = path.join(dir, 'result.json')
  const json = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', '({ n: 1, list: [1, 2] })', '--out', outPath],
    env
  )
  expect(json.ok, json.error).toBe(true)
  expect(json.result?.path).toBe(outPath)
  expect(json.result?.format).toBe('json')
  const written = readFileSync(outPath, 'utf8')
  expect(JSON.parse(written)).toEqual({ n: 1, list: [1, 2] })
  expect(written).toContain('\n')

  // A caller-named path is never clobbered — same rule as save-resource.
  const clobber = await runTabsCtl(
    ['execute-js', '--pane', paneId, '--code', '1', '--out', outPath],
    env
  )
  expect(clobber.ok).toBe(false)
  expect(clobber.error).toContain('refusing to overwrite')

  rmSync(dir, { recursive: true, force: true })
  await closeAgentSession(page, env, paneId)
})
