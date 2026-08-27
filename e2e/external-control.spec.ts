import { createConnection } from 'node:net'
import {
  closeAgentSession,
  createAgentPane,
  openAgentSession,
  openForeignPane,
  readPaneEnv,
  runTabsCtl,
  setControlledPanePlacement
} from './helpers/agentSession'
import { requireBox } from './helpers/geometry'
import { guestText } from './helpers/guest'
import { expect, test, withApp } from './helpers/launch'
import {
  closeInactiveRootTab,
  closePane,
  initialPane,
  paneById,
  splitHorizontal
} from './helpers/pane'
import { openSettingsWindow } from './helpers/settings'
import { openTerminal } from './helpers/terminal'
import { testServerForSpec } from './helpers/testServer'

// The agent-control surface itself: session/transport plumbing, pane
// creation and placement, the ownership ledger and its refusals, and the
// protocol-level gates. Read/input/flow verbs live in the sibling
// external-control-*.spec.ts files; the shared scaffolding is
// helpers/agentSession.ts.

/**
 * One fixture origin for the whole file — see helpers/testServer.ts for why
 * these tests can't use the `data:` URLs browser.spec.ts relies on.
 */
const server = testServerForSpec()

test('a skill running outside Tabs is rejected before it can do anything', async () => {
  const response = await runTabsCtl(['create-browser-pane', '--url', 'about:blank'], {})
  expect(response.ok).toBe(false)
  expect(response.error).toContain('not running inside a Tabs terminal pane')
})

test('an agent can create and control a browser pane it owns, but no other', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const created = await runTabsCtl(['create-browser-pane', '--url', 'about:blank'], env)
  expect(created.ok).toBe(true)
  const paneId = created.result?.paneId
  if (!paneId) throw new Error('createBrowserPane did not return a paneId')

  const browserPane = paneById(page, paneId)
  await expect(browserPane).toBeVisible()
  await expect(browserPane.getByTestId('browser')).toBeVisible()
  // The control indicator (see Pane.tsx) — the product call was
  // autonomous-but-marked, not a silent creation. Full coverage (the pulse
  // animation, non-propagation to the tab) lives in the dedicated test below.
  await expect(browserPane).toHaveClass(/pane-controlled/)
  await expect(browserPane.getByTestId('pane-control-icon')).toBeVisible()

  const navigated = await runTabsCtl(['navigate', '--pane', paneId, '--url', 'about:blank'], env)
  expect(navigated.ok).toBe(true)

  const rejected = await runTabsCtl(
    ['navigate', '--pane', 'not-a-pane-this-agent-created', '--url', 'about:blank'],
    env
  )
  expect(rejected.ok).toBe(false)
  expect(rejected.error).toContain('not the owner')

  // The browser pane joined the terminal as a sibling tab of root's own
  // group, so its pane header (and pane-close-button) is now
  // backgrounded/hidden — close it from the tab strip's own control instead
  // (see closeInactiveRootTab's doc comment). See openTerminal's doc comment on
  // why a test shouldn't leave a live shell behind for the shared app's
  // eventual quit to trip over.
  await closeInactiveRootTab(page)
})

// Generalizes bell.spec.ts's real-wiring coverage to the control indicator:
// a genuine ownership grant travelling ownerOf → broadcastOwnership →
// controlStore.ts (see src/main/externalControl.ts), rather than the
// simulated push src/renderer/src/__tests__/control.test.tsx drives through
// the fake bridge. The one thing worth a real end-to-end check that the
// jsdom tier can't give for free: the browser pane really does join the
// terminal as a sibling tab (same shape as the "created by an agent" test
// above), and that real tab really does carry no control marker.
test('an agent-owned pane pulses the control indicator, and it never propagates to its tab', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', 'about:blank')

  const browserPane = paneById(page, paneId)
  await expect(browserPane).toHaveClass(/pane-controlled/)
  const icon = browserPane.getByTestId('pane-control-icon')
  await expect(icon).toBeVisible()
  expect(await icon.evaluate((el) => getComputedStyle(el).animationName)).toContain('control-pulse')
  expect(
    await browserPane.evaluate((el) => getComputedStyle(el, '::after').animationName)
  ).toContain('control-pulse')

  const tabs = page.getByRole('tab')
  await expect(tabs).toHaveCount(2)
  for (const tab of await tabs.all()) {
    await expect(tab.getByTestId('tab-control-icon')).toHaveCount(0)
  }

  await closeAgentSession(page, env, paneId)
})

test('list-panes shows only the panes this caller created, and close-pane revokes ownership', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  // A browser pane the *user* opened by hand, which must never show up in an
  // agent's listing however many browser panes are on screen.
  await openForeignPane(page, env)

  const paneId = await createAgentPane(env, '--url', 'about:blank')

  const listed = await runTabsCtl(['list-panes'], env)
  expect(listed.ok).toBe(true)
  expect(listed.result?.panes?.map((pane) => pane.paneId)).toEqual([paneId])

  const closed = await runTabsCtl(['close-pane', '--pane', paneId], env)
  expect(closed.ok).toBe(true)
  await expect(paneById(page, paneId)).toHaveCount(0)

  // Ownership is dropped with the pane, so the same id is no longer targetable
  // — but the caller who closed it is told the pane is *gone*, not that it was
  // never theirs. "not the owner" here used to send an agent hunting a
  // permissions problem instead of reading the documented recovery.
  const afterClose = await runTabsCtl(['navigate', '--pane', paneId, '--url', 'about:blank'], env)
  expect(afterClose.ok).toBe(false)
  expect(afterClose.error).toContain('no longer exists')
  expect(afterClose.error).not.toContain('not the owner')

  await expect.poll(async () => (await runTabsCtl(['list-panes'], env)).result?.panes).toEqual([])

  // The hand-opened foreign pane from above is still standing, backgrounded
  // beside the terminal in root's own tab group — close via the tab strip,
  // not the terminal's own (hidden) header.
  await closeInactiveRootTab(page)
})

test('close-pane refuses a pane this caller does not own', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const response = await runTabsCtl(['close-pane', '--pane', env.TABS_PANE_ID], env)
  expect(response.ok).toBe(false)
  expect(response.error).toContain('not the owner')
  // The caller's own terminal pane is still standing.
  await expect(paneById(page, env.TABS_PANE_ID)).toBeVisible()

  await closeAgentSession(page, env)
})

test('createBrowserPane grants ownership as soon as the pane exists, not only once its own relay resolves', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  // The fixture delays its response, so create-browser-pane's own relay —
  // which waits for the guest's load to settle — is still pending when
  // list-panes probes for ownership through a second, independent socket
  // connection. Proves the grant lands the instant the pane exists in the
  // tree, not only once that wait finally resolves.
  const created = createAgentPane(env, '--url', server.url('/slow'))
  await page.waitForTimeout(300)

  const owned = await runTabsCtl(['list-panes'], env)
  expect(owned.result?.panes).toHaveLength(1)

  const paneId = await created
  await closeAgentSession(page, env, paneId)
})

// A split, not a tab: the terminal stays visible beside the new pane instead
// of being backgrounded into an inactive tab (contrast the default 'tab'
// placement — see 'activate-pane brings a backgrounded pane…' below). The
// separator itself is real but rendered at 0 width by design (see the comment
// on .split-separator in global.css), so it's asserted attached rather than
// visible — the actual proof of the direction is the two panes' geometry: for
// a horizontal split they share a top edge and sit apart along x, and for a
// vertical one the axes swap. One parameterized test rather than two copies
// precisely because the axes are all that differ: a later assertion added to
// only one of them would leave the other silently weaker.
for (const { placement, direction, shared, apart } of [
  { placement: 'split-horizontal', direction: 'horizontal', shared: 'y', apart: 'x' },
  { placement: 'split-vertical', direction: 'vertical', shared: 'x', apart: 'y' }
] as const) {
  test(`create-browser-pane splits ${direction}ly when placement is set to ${placement}`, async ({
    page,
    electronApp
  }) => {
    const { env } = await openAgentSession(page)
    await setControlledPanePlacement(page, electronApp, placement)

    const paneId = await createAgentPane(env, '--url', 'about:blank')

    const browserPane = paneById(page, paneId)
    const terminalPane = paneById(page, env.TABS_PANE_ID)
    await expect(browserPane).toBeVisible()
    await expect(terminalPane).toBeVisible()
    await expect(
      page.locator(`.split-separator[data-split-direction="${direction}"]`)
    ).toBeAttached()
    const browserBox = await requireBox(browserPane)
    const terminalBox = await requireBox(terminalPane)
    expect(Math.abs(browserBox[shared] - terminalBox[shared])).toBeLessThan(2)
    expect(Math.abs(browserBox[apart] - terminalBox[apart])).toBeGreaterThan(50)

    await closeAgentSession(page, env, paneId)
  })
}

test('create-browser-pane opens its own unpinned window when placement is set to unpinned', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  await setControlledPanePlacement(page, electronApp, 'unpinned')

  const paneId = await createAgentPane(env, '--url', 'about:blank')

  const floatingWindow = page.getByTestId('floating-window')
  await expect(floatingWindow).toBeVisible()
  await expect(floatingWindow.locator(`[data-dock-id="${paneId}"]`)).toBeVisible()
  // Nothing was wrapped into a tab group in the docked root — the terminal's
  // own pane never moved.
  await expect(paneById(page, env.TABS_PANE_ID)).toBeVisible()

  await closeAgentSession(page, env, paneId)
})

test('activate-pane brings a backgrounded pane to the front so it can be captured', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  // create-browser-pane opens as a new tab by default (the browser's
  // controlledPanePlacement setting — see the placement tests above), wrapping
  // the terminal and browser into a tab group with the browser active; switch
  // back to the terminal's tab like a user would (selected structurally — tab
  // titles are live and not worth pinning).
  await expect(paneById(page, paneId)).toBeVisible()
  await page.locator('.tab:not(.tab-active)').first().click()
  await expect(paneById(page, paneId)).toBeHidden()

  const activated = await runTabsCtl(['activate-pane', '--pane', paneId], env)
  expect(activated.ok).toBe(true)
  await expect(paneById(page, paneId)).toBeVisible()

  const shot = await runTabsCtl(['screenshot', '--pane', paneId], env)
  expect(shot.ok).toBe(true)
  expect(shot.result?.path).toBeTruthy()

  await closeAgentSession(page, env, paneId)
})

test('driving a pane never steals keyboard focus from the terminal', async ({
  page,
  electronApp
}) => {
  const { term, env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  // create-browser-pane opens as a new tab by default, which wraps the terminal
  // and the browser into a tab group with the browser active. Switch back to
  // the terminal's tab like a user would — the scenario where stolen focus
  // would actually bite a user is one where they can see and are typing into
  // the terminal while an agent drives the (now backgrounded) browser pane
  // alongside it. The browser pane stays mounted while hidden (TabsRenderer
  // keeps inactive tabs in the DOM, just hidden), so driving it over the
  // socket below works exactly as it would in the foreground.
  await page.locator('.tab:not(.tab-active)').first().click()

  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const button = read.result?.elements?.find((el) => el.name === 'Do the thing')
  const field = read.result?.elements?.find((el) => el.name === 'Your name')
  if (!button || !field) throw new Error('readPage did not surface the fixture controls')

  // Focus the terminal the way a user typing to their agent would have it.
  const box = await requireBox(term)
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  const focusedTag = (): Promise<string> =>
    page.evaluate(() => document.activeElement?.tagName ?? 'none')
  expect(await focusedTag()).not.toBe('WEBVIEW')
  const before = await focusedTag()
  // The active-pane highlight is the other half of "whose turn is it", and
  // since a press inside a guest now activates its pane
  // (src/plugins/browser/main/guestActivation.ts), an agent's synthesized click would
  // move it — an injected mouseDown being indistinguishable from the user's at
  // the guest. Record where it sits so the assertions below can prove it
  // didn't move; a moved highlight would drag the keyboard after it through
  // focus-follows-active, which is the theft this whole test is about.
  const activePaneId = (): Promise<string | null> =>
    page.evaluate(
      () => document.querySelector('.pane-active')?.getAttribute('data-dock-id') ?? null
    )
  const activeBefore = await activePaneId()
  expect(activeBefore).not.toBeNull()

  // Every input verb, while the user "types" in the terminal.
  await runTabsCtl(['click', '--pane', paneId, '--ref', button.ref], env)
  await runTabsCtl(['type', '--pane', paneId, '--ref', field.ref, '--text', 'quiet'], env)
  await runTabsCtl(['key', '--pane', paneId, '--key', 'Enter'], env)
  await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: field.ref }, value: 'still' }])
    ],
    env
  )

  // The inputs genuinely landed in the guest...
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:still')
  // ...and the host's focus never moved to the webview.
  expect(await focusedTag()).toBe(before)
  // ...nor did the active-pane highlight follow the agent's clicks.
  expect(await activePaneId()).toBe(activeBefore)

  await closeAgentSession(page, env, paneId)
})

test('oversized results are truncated honestly, never silently', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  const big = await runTabsCtl(['execute-js', '--pane', paneId, '--code', "'x'.repeat(60000)"], env)
  expect(big.ok).toBe(true)
  expect(big.result?.truncated).toBe(true)
  expect(String(big.result?.value).length).toBeLessThanOrEqual(50000)

  const clipped = await runTabsCtl(['get-page-text', '--pane', paneId, '--max-length', '10'], env)
  expect(clipped.result?.truncated).toBe(true)
  expect(clipped.result?.text?.length).toBe(10)

  await closeAgentSession(page, env, paneId)
})

test('tabs-ctl drains a response bigger than the pipe buffer instead of truncating it', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url('/bigtext'))

  // runTabsCtl pipes stdout (execFile), exactly how real callers run tabs-ctl
  // too (`| jq`). Past ~64KB a pipe holds only what the kernel buffered: a
  // hard process.exit() after the write dropped the rest mid-string with exit
  // 0 — so the JSON.parse inside runTabsCtl is itself an assertion here, and
  // the end marker proves the far end of the response arrived.
  const big = await runTabsCtl(['get-page-text', '--pane', paneId, '--max-length', '200000'], env)
  expect(big.ok, big.error).toBe(true)
  expect(big.exitCode).toBe(0)
  const text = String(big.result?.text)
  expect(text.length).toBeGreaterThan(65536)
  expect(text).toContain('END-OF-BIGTEXT')

  await closeAgentSession(page, env, paneId)
})

test('a raw socket client sending an unknown verb gets a clean refusal', async ({ page }) => {
  const { env } = await openAgentSession(page)

  // tabs-ctl now validates verbs client-side, so go under it to prove the
  // server rejects unknown types too instead of answering `undefined`.
  const raw = await new Promise<string>((resolve, reject) => {
    const socket = createConnection(env.TABS_CONTROL_SOCKET, () => {
      socket.write(`${JSON.stringify({ type: 'nope', paneId: env.TABS_PANE_ID })}\n`)
    })
    let buffer = ''
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf-8')
    })
    socket.on('end', () => resolve(buffer.trim()))
    socket.on('error', reject)
  })
  expect(JSON.parse(raw)).toEqual({ ok: false, error: 'unknown request type: nope' })

  await closeAgentSession(page, env)
})

test('one agent cannot drive a pane another agent created', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const termA = await openTerminal(initialPane(page))
  const envA = await readPaneEnv(termA)

  const termB = await openTerminal(page.getByTestId('pane').nth(2))
  const envB = await readPaneEnv(termB)
  expect(envB.TABS_PANE_ID).not.toBe(envA.TABS_PANE_ID)

  const paneId = await createAgentPane(envA, '--url', 'about:blank')

  // Agent B holds a perfectly real pane id — the check is who created it,
  // not whether the id resolves.
  const stolen = await runTabsCtl(['navigate', '--pane', paneId, '--url', 'about:blank'], envB)
  expect(stolen.ok).toBe(false)
  expect(stolen.error).toContain('not the owner')
  const listed = await runTabsCtl(['list-panes'], envB)
  expect(listed.result?.panes).toEqual([])

  await runTabsCtl(['close-pane', '--pane', paneId], envA)

  // The tombstone is scoped to the caller who closed it. A closes its own pane
  // and is told the pane is gone; B, who never owned it, still gets the
  // uniform ownership refusal for the very same id. If B were told "no longer
  // exists" the tombstone would be a liveness oracle — a way for any caller to
  // learn whether some other agent's pane id had ever been real.
  const closerSees = await runTabsCtl(['navigate', '--pane', paneId, '--url', 'about:blank'], envA)
  expect(closerSees.error).toContain('no longer exists')
  const strangerSees = await runTabsCtl(
    ['navigate', '--pane', paneId, '--url', 'about:blank'],
    envB
  )
  expect(strangerSees.error).toContain('not the owner')
  expect(strangerSees.error).not.toContain('no longer exists')

  // Close both terminals by id, not position: the browser pane's tab group
  // collapsed on close, so each terminal pane has its own header again, but
  // root's own wrapper still counts as a pane too. Closing the first
  // collapses the split, leaving the second as the sole real pane — wait for
  // the collapse, since the close confirmation round-trips async.
  await closePane(paneById(page, envA.TABS_PANE_ID))
  await expect(page.getByTestId('pane')).toHaveCount(2)
  await closePane(paneById(page, envB.TABS_PANE_ID))
})

test('two instances sharing a userData dir keep their control surfaces apart', async ({
  userDataDir
}) => {
  // Deliberately not the shared fixture app: this needs two instances against
  // ONE userData dir — the double-launch that used to make whichever instance
  // started last unlink and re-bind the fixed control.sock path, rerouting
  // every existing terminal's control calls to the wrong app (and bricking
  // them entirely once that instance quit). Per-pid socket names are the fix
  // under test. Both apps' login shells are left for E2E_HIDDEN's quit
  // backstop, same as the terminal persistence tests — two windows' worth of
  // pane choreography isn't worth the flake surface here.
  await withApp(userDataDir, async (appA, pageA) => {
    const termA = await openTerminal(initialPane(pageA))
    const envA = await readPaneEnv(termA)
    // The socket a pty is handed names the exact instance that spawned it.
    const pidA = await appA.evaluate(() => process.pid)
    expect(envA.TABS_CONTROL_SOCKET).toContain(`control-${pidA}.sock`)

    await withApp(userDataDir, async (_appB, pageB) => {
      await pageB.getByTestId('pane').first().waitFor()

      // A's socket survived B's startup sweep — a live pid's socket is left
      // strictly alone...
      const ping = await runTabsCtl(['ping'], envA)
      expect(ping.ok).toBe(true)

      // ...and a pane created from A's terminal materializes in A's window.
      // B restored the same persisted layout, so the same pane ids exist
      // there too — with a shared socket path this request would have
      // executed in B and passed its caller check.
      const paneId = await createAgentPane(envA, '--url', 'about:blank')
      await expect(paneById(pageA, paneId)).toBeVisible()
      await expect(paneById(pageB, paneId)).toHaveCount(0)

      await runTabsCtl(['close-pane', '--pane', paneId], envA)
    })

    // With B gone, A's control surface still works — the old fixed-path
    // design left A listening on an unlinked inode nobody could reach.
    const pingAfter = await runTabsCtl(['ping'], envA)
    expect(pingAfter.ok).toBe(true)
  })
})

test('a disallowed URL scheme is rejected without touching the pane tree', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const response = await runTabsCtl(['create-browser-pane', '--url', 'file:///etc/passwd'], env)
  expect(response.ok).toBe(false)
  expect(response.error).toContain('url not allowed')

  await closeAgentSession(page, env)
})

/**
 * Creating is the only verb the user's enable/disable setting gates — the
 * refusal is a check inside the browser's own handler, not a missing
 * registration, precisely so panes an agent already owns stay readable and
 * drivable. The message has to name the remedy: this text lands in the calling
 * agent's context verbatim, and a bare refusal only makes it retry.
 */
test('create-browser-pane is refused while the browser content type is turned off', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const settingsPage = await openSettingsWindow(electronApp, page)
  // Stated, not inherited from DEFAULT_SETTINGS.
  await settingsPage.getByTestId('settings-content-type-browser-checkbox').check()

  // Owned before the type goes off, so the "existing panes keep working" half
  // has something real to prove.
  const paneId = await createAgentPane(env, '--url', 'about:blank')

  await settingsPage.getByTestId('settings-content-type-browser-checkbox').uncheck()
  await expect(
    page.locator('[data-dock-id]').first().getByTestId('pane-new-browser-button')
  ).toHaveCount(0)

  const refused = await runTabsCtl(['create-browser-pane', '--url', 'about:blank'], env)
  expect(refused.ok).toBe(false)
  expect(refused.error).toContain('Content types')

  // The pane created earlier is untouched: still there, still drivable.
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  expect((await runTabsCtl(['navigate', '--pane', paneId, '--url', 'about:blank'], env)).ok).toBe(
    true
  )
  expect((await runTabsCtl(['list-panes'], env)).result?.panes).toHaveLength(1)

  // And re-enabling restores creation with no restart.
  await settingsPage.getByTestId('settings-content-type-browser-checkbox').check()
  const allowed = await runTabsCtl(['create-browser-pane', '--url', 'about:blank'], env)
  expect(allowed.ok).toBe(true)

  await runTabsCtl(['close-pane', '--pane', String(allowed.result?.paneId)], env)
  await closeAgentSession(page, env, paneId)
})

// A pane the user closed by hand is a different failure from a pane that was
// never a browser, and they used to report identically. Main's ownership grant
// (`ownerOf`) survives until a close-pane *verb* succeeds, so a hand-closed
// pane still passes the ownership check and reaches the renderer as a live
// request against an id that no longer resolves — which is by far the common
// case, since main only grants ids it watched create-browser-pane create.
//
// This is the *renderer's* producer of that sentence. Core's main produces the
// identical one from its closed-pane tombstone when the caller closed the pane
// itself (see the close-pane assertions above and the two-agent test below);
// both read PANE_GONE_ERROR, so the two routes cannot drift into two spellings
// of "it's gone".
test('a pane the user closed by hand reports that, not "not a browser pane"', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', 'about:blank')

  // The happy path still works through the same shared check.
  expect((await runTabsCtl(['activate-pane', '--pane', paneId], env)).ok).toBe(true)

  // Closed through the pane's own chrome, exactly as a user would — not
  // through close-pane, which would revoke ownership and give "not the owner".
  await closePane(paneById(page, paneId))
  await expect(paneById(page, paneId)).toHaveCount(0)

  // Every verb that resolves a target agrees, not just these three: the check
  // is one helper shared by activate/close and by the handle resolution all
  // the read/input verbs go through.
  for (const args of [
    ['activate-pane', '--pane', paneId],
    ['get-page-text', '--pane', paneId],
    ['close-pane', '--pane', paneId]
  ]) {
    const response = await runTabsCtl(args, env)
    expect(response.ok).toBe(false)
    expect(response.error).toContain('no longer exists')
    expect(response.error).not.toContain('not a browser pane')
  }

  await closeAgentSession(page, env)
})

/**
 * Main's half of the verb-coverage guarantee — the twin of the renderer's
 * content/__tests__/externalControlVerbs.test.tsx.
 *
 * Each content type's verb table is exhaustive over its own request union at
 * compile time (see src/main/controlVerbs.ts), so a verb added to the protocol
 * without a handler and a relay budget fails to build. What the compiler
 * cannot see is whether the registration ever *ran*: a complete table in a
 * module dropped from contentTypes.ts, or a `registerMainControlVerbs` call
 * moved out of `register()`, builds clean and fails only when someone drives
 * that verb over the socket. This asserts against a real app, which is the
 * only tier where every content module has actually registered.
 */
test('every protocol verb is claimed by some module in the main process', async ({
  electronApp
}) => {
  // The `electronApp` fixture launches the app but does not wait for its
  // window; only the `page` fixture does. Without this the evaluate below can
  // land before whenReady has run registerE2eHooks — which shows up as the
  // hooks being absent, and only when this test runs in isolation, since any
  // earlier test in the file has already forced the window.
  await electronApp.firstWindow()
  const unhandled = await electronApp.evaluate(
    async () => globalThis.__tabsE2e?.unhandledControlVerbs() ?? ['__hooks-not-installed__']
  )
  expect(unhandled).toEqual([])
})
