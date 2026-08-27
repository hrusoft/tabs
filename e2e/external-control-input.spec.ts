import type { Page } from '@playwright/test'
import type { PageElement } from '../src/plugins/browser/shared/externalControl'
import {
  closeAgentSession,
  createAgentPane,
  expectRefusedForForeignPane,
  openAgentSession,
  type PaneEnv,
  runTabsCtl
} from './helpers/agentSession'
import { guestEval, guestText } from './helpers/guest'
import { expect, test } from './helpers/launch'
import { paneById } from './helpers/pane'
import { testServerForSpec } from './helpers/testServer'

// The input verbs: click, hover, scroll, type, key, form-input, and the
// element-targeting machinery (refs, semantic targets, layout shifts)
// they share. Session scaffolding is helpers/agentSession.ts.

/**
 * One fixture origin for the whole file — see helpers/testServer.ts for why
 * these tests can't use the `data:` URLs browser.spec.ts relies on.
 */
const server = testServerForSpec()

/**
 * Both halves of the editing-command gap, pinned together because they only
 * make sense as a pair: the chord genuinely cannot work, so the note has to
 * say so, and --command has to be the thing that does work.
 *
 * The chord assertion is deliberately a *pin on the broken behaviour*. If
 * Chromium ever started honouring a synthesized chord, this fails — which is
 * what should happen, because the note would then be lying.
 */
test('a modifier chord cannot reach the editing commands, and --command can', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  const fill = (value: string) =>
    runTabsCtl(
      [
        'form-input',
        '--pane',
        paneId,
        '--fields',
        JSON.stringify([{ target: { selector: '#name' }, value }])
      ],
      env
    )
  const selection = () =>
    runTabsCtl(
      [
        'execute-js',
        '--pane',
        paneId,
        '--code',
        "(() => { const el = document.getElementById('name'); return el.selectionStart + '-' + el.selectionEnd })()"
      ],
      env
    )

  await fill('anti-fog')

  // The chord arrives for real — the page's own handlers would see it — and
  // changes nothing about the selection. Measured: 8-8 on an 8-character value.
  const chord = await runTabsCtl(
    ['key', '--pane', paneId, '--key', 'a', '--modifiers', 'meta'],
    env
  )
  expect(chord.ok).toBe(true)
  expect((await selection()).result?.value).toBe('8-8')
  // …and the response says so, rather than reporting a bare success that a
  // follow-up Backspace would turn into a silently truncated field.
  expect(chord.result?.note).toContain('synthesized chord')
  expect(chord.result?.note).toContain('--command')

  // The trap in full, kept visible: Backspace after the chord eats one char.
  await runTabsCtl(['key', '--pane', paneId, '--key', 'Backspace'], env)
  await expect
    .poll(() => guestEval(electronApp, "document.getElementById('name').value"))
    .toBe('anti-fo')

  // --command goes through the real pipeline: select-all actually selects.
  await fill('anti-fog')
  const selectAll = await runTabsCtl(['key', '--pane', paneId, '--command', 'select-all'], env)
  expect(selectAll.ok, selectAll.error).toBe(true)
  expect(selectAll.result?.command).toBe('select-all')
  expect((await selection()).result?.value).toBe('0-8')

  // …so the follow-up Backspace now clears the field, which is the whole point.
  await runTabsCtl(['key', '--pane', paneId, '--key', 'Backspace'], env)
  await expect.poll(() => guestEval(electronApp, "document.getElementById('name').value")).toBe('')

  // undo/redo ride the browser's own undo stack, which only real keystrokes
  // fill — so they work after `type` and are a documented no-op after a
  // programmatic fill. Pinned because the docs promise exactly this asymmetry.
  await runTabsCtl(['type', '--pane', paneId, '--selector', '#name', '--text', 'hello'], env)
  expect((await runTabsCtl(['key', '--pane', paneId, '--command', 'undo'], env)).ok).toBe(true)
  await expect
    .poll(() => guestEval(electronApp, "document.getElementById('name').value"))
    .toBe('hell')
  expect((await runTabsCtl(['key', '--pane', paneId, '--command', 'redo'], env)).ok).toBe(true)
  await expect
    .poll(() => guestEval(electronApp, "document.getElementById('name').value"))
    .toBe('hello')

  // A plain key still answers with no note — the note is for the chord that
  // cannot work, not decoration on every keystroke.
  const plain = await runTabsCtl(['key', '--pane', paneId, '--key', 'Enter'], env)
  expect(plain.ok).toBe(true)
  expect(plain.result?.note).toBeUndefined()

  // Exactly one of key/command.
  const neither = await runTabsCtl(['key', '--pane', paneId], env)
  expect(neither.ok).toBe(false)
  expect(neither.error).toContain('one of --key, --command')

  // The clipboard commands are deliberately absent from the surface.
  const clipboard = await runTabsCtl(['key', '--pane', paneId, '--command', 'paste'], env)
  expect(clipboard.ok).toBe(false)

  await closeAgentSession(page, env, paneId)
})

/**
 * Both halves of scroll's honesty, on the two pages that expose them.
 *
 * The smooth page is the reported bug: the old two-argument scrollBy resolved
 * to the page's own `scroll-behavior: smooth`, so the position was read while
 * the page was still travelling. The backgrounded pane is the second half
 * found alongside it — the default step used to be measured from the host
 * element's rect, which is 0×0 for a tab the user has switched away from, so
 * the scroll moved nothing and said it worked.
 */
test('scroll reports where it landed, on a smooth page and on a hidden one', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/smooth'))

  const scrolled = await runTabsCtl(['scroll', '--pane', paneId, '--direction', 'down'], env)
  expect(scrolled.ok, scrolled.error).toBe(true)
  const reported = scrolled.result?.position?.y ?? 0
  expect(reported).toBeGreaterThan(0)

  // The reported number is the page's real position, not a pre-animation
  // snapshot — read from the guest itself, an independent path.
  expect(await guestEval<number>(electronApp, 'window.scrollY')).toBe(reported)

  // …and it is still that number once any animation would have finished, which
  // is what proves the read wasn't merely lucky timing.
  await page.waitForTimeout(600)
  expect(await guestEval<number>(electronApp, 'window.scrollY')).toBe(reported)

  // Successive scrolls advance, so comparing positions is a usable
  // "have I reached the bottom" test — the loop SKILL.md now recommends.
  const again = await runTabsCtl(['scroll', '--pane', paneId, '--direction', 'down'], env)
  expect(again.result?.position?.y).toBeGreaterThan(reported)

  // A backgrounded pane still scrolls a real screenful: the step comes from
  // the guest's own innerHeight, not from the host element's (zero) rect.
  const before = await guestEval<number>(electronApp, 'window.scrollY')
  // Backgrounded the way a user does it — clicking the terminal's tab — since
  // activate-pane only works on panes this caller owns.
  await page.locator('.tab:not(.tab-active)').first().click()
  await expect(paneById(page, paneId)).toBeHidden()
  const hidden = await runTabsCtl(['scroll', '--pane', paneId, '--direction', 'down'], env)
  expect(hidden.ok, hidden.error).toBe(true)
  expect(hidden.result?.position?.y).toBeGreaterThan(before)
  expect(await guestEval<number>(electronApp, 'window.scrollY')).toBe(hidden.result?.position?.y)

  await closeAgentSession(page, env, paneId)
})

/**
 * The pattern `click` structurally cannot reach: a menu that opens on hover
 * and navigates on click. The fixture's submenu is `display: none` until
 * `mouseenter`, so read-page genuinely cannot see it beforehand — which is
 * what makes the post-hover read prove the hover landed, rather than merely
 * agreeing with a page that was always showing it.
 */
test('hover opens a hover-only menu without committing the click', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/hovery'))

  // Before: the submenu is display:none, so it is invisible to read-page's
  // visibility predicate and its link cannot be targeted at all.
  const before = await runTabsCtl(['read-page', '--pane', paneId, '--selector', '#submenu a'], env)
  expect(before.ok).toBe(true)
  expect(before.result?.elements).toEqual([])

  const hovered = await runTabsCtl(['hover', '--pane', paneId, '--name', 'Products'], env)
  expect(hovered.ok).toBe(true)
  expect(hovered.result?.element?.name).toBe('Products')

  // The menu opened, and — the whole point — the label was *not* clicked.
  await expect.poll(() => guestText(electronApp, '#status')).toBe('menu-open')

  // The revealed link is now readable and targetable, and the hover survives
  // the read: no second hover is needed to keep the menu open.
  const after = await runTabsCtl(['read-page', '--pane', paneId, '--selector', '#submenu a'], env)
  expect(after.ok).toBe(true)
  expect(after.result?.elements?.map((element) => element.name)).toEqual(['Widgets'])

  // For contrast: clicking the same target commits the press, which is the
  // behaviour that made a hover-to-open menu unreachable before this verb.
  const clicked = await runTabsCtl(['click', '--pane', paneId, '--name', 'Products'], env)
  expect(clicked.ok).toBe(true)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('label-clicked')

  await closeAgentSession(page, env, paneId)
})

test('an agent can read the page structure and drive it: click, type, submit, scroll', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Every assertion below reads the guest's own DOM (see guestText) rather
  // than trusting tabs-ctl's `{ok:true}` — the point is that a synthesized
  // input event really reached the page, not that the request round-tripped.
  const status = (): Promise<string | null> => guestText(electronApp, '#status')
  await expect.poll(status).toBe('idle')

  await expect
    .poll(async () => (await runTabsCtl(['read-page', '--pane', paneId], env)).result?.elements)
    .toEqual(expect.arrayContaining([expect.objectContaining({ name: 'Do the thing' })]))

  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const button = read.result?.elements?.find((el) => el.name === 'Do the thing')
  const field = read.result?.elements?.find((el) => el.name === 'Your name')
  if (!button || !field) throw new Error('readPage did not surface the fixture controls')
  expect(button.role).toBe('button')
  expect(field.role).toBe('textbox')
  expect(button.rect.width).toBeGreaterThan(0)

  // find() is a heuristic over a fresh extraction, so its top match carries a
  // *new* ref — refs accumulate per page rather than rebinding (see
  // pageScripts.ts's REF_REGISTRY).
  const found = await runTabsCtl(['find', '--pane', paneId, '--description', 'do the thing'], env)
  expect(found.result?.matches?.[0]?.name).toBe('Do the thing')

  // The pre-find ref still names exactly the element it did — find's
  // re-extraction cannot silently retarget it. The result reports the element
  // the click landed on, in readPage's own vocabulary.
  const clicked = await runTabsCtl(['click', '--pane', paneId, '--ref', button.ref], env)
  expect(clicked.result?.element).toEqual({ role: 'button', name: 'Do the thing', tag: 'button' })
  await expect.poll(status).toBe('clicked')

  await runTabsCtl(['type', '--pane', paneId, '--ref', field.ref, '--text', 'ada'], env)
  await expect.poll(status).toBe('typed:ada')

  // --submit sends a real Enter after the text, which the fixture reports
  // separately from the per-character input events.
  await runTabsCtl(['type', '--pane', paneId, '--ref', field.ref, '--text', 'x', '--submit'], env)
  await expect.poll(status).toBe('submitted:adax')

  // A raw coordinate must land in the same space readPage reported the rect
  // in — and the result reports what sat at that point, since a coordinate
  // click is never refused (the caller named the exact spot).
  const atPoint = await runTabsCtl(
    [
      'click',
      '--pane',
      paneId,
      '--x',
      String(Math.round(button.rect.x + button.rect.width / 2)),
      '--y',
      String(Math.round(button.rect.y + button.rect.height / 2))
    ],
    env
  )
  expect(atPoint.result?.element?.name).toBe('Do the thing')
  await expect.poll(status).toBe('clicked')

  // A bare key lands on whatever the guest has focused — the field, after the
  // clicks above — with no help from the host: the webview element is never
  // focused by input verbs (see the focus test below).
  await runTabsCtl(['click', '--pane', paneId, '--ref', field.ref], env)
  await runTabsCtl(['key', '--pane', paneId, '--key', 'Enter'], env)
  await expect.poll(status).toBe('submitted:adax')

  // The fixture is 3000px tall, so a downward scroll must actually move —
  // `position` is read back from the page, not echoed from the request.
  const scrolled = await runTabsCtl(['scroll', '--pane', paneId, '--direction', 'down'], env)
  expect(scrolled.ok).toBe(true)
  expect((scrolled.result?.position as { y: number } | undefined)?.y).toBeGreaterThan(0)

  await closeAgentSession(page, env, paneId)
})

test('a stale element ref reports why rather than clicking something else', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  await expect
    .poll(async () => (await runTabsCtl(['read-page', '--pane', paneId], env)).result?.elements)
    .not.toEqual([])

  // Refs live in the guest page's own globals, so a navigation drops them.
  await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url('/other')], env)
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.title)
    .toBe('Elsewhere')

  const stale = await runTabsCtl(['click', '--pane', paneId, '--ref', 'e1'], env)
  expect(stale.ok).toBe(false)
  expect(stale.error).toContain('readPage')

  await closeAgentSession(page, env, paneId)
})

/**
 * The scaffold the two layout-shift click tests share: a /shifty pane, its
 * target button's ref, and the guest-side #status reader.
 */
async function openShiftyTarget(
  page: Page,
  env: PaneEnv
): Promise<{ paneId: string; target: PageElement }> {
  const paneId = await createAgentPane(env, '--url', server.url('/shifty'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  await expect
    .poll(async () => (await runTabsCtl(['read-page', '--pane', paneId], env)).result?.elements)
    .toEqual(expect.arrayContaining([expect.objectContaining({ name: 'Shifty target' })]))
  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const target = read.result?.elements?.find((el) => el.name === 'Shifty target')
  if (!target) throw new Error('readPage did not surface the shifty target')
  return { paneId, target }
}

test('a click whose target moved since read-page lands on the element, not the old point', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const { paneId, target } = await openShiftyTarget(page, env)

  // Shift the layout out from under the ref: 500px of new content above the
  // button moves it well clear of the rect readPage reported, which now holds
  // only the grown spacer.
  const grown = await runTabsCtl(
    [
      'execute-js',
      '--pane',
      paneId,
      '--code',
      "(() => { document.getElementById('lead').style.height = '500px'; return document.getElementById('target').getBoundingClientRect().y })()"
    ],
    env
  )
  expect(grown.ok).toBe(true)
  expect(grown.result?.value as number).toBeGreaterThan(target.rect.y + 400)

  // The point is re-resolved in the same guest script that dispatches from,
  // so the click follows the element rather than pressing the stale spot.
  const clicked = await runTabsCtl(['click', '--pane', paneId, '--ref', target.ref], env)
  expect(clicked.ok).toBe(true)
  expect(clicked.result?.element).toEqual({ role: 'button', name: 'Shifty target', tag: 'button' })
  await expect.poll(() => guestText(electronApp, '#status')).toBe('target-clicked')

  await closeAgentSession(page, env, paneId)
})

test('a click whose target is covered fails naming both elements instead of pressing the cover', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)
  const { paneId, target } = await openShiftyTarget(page, env)

  // A fixed full-viewport overlay now owns every point on the page — the
  // sharpest form of "something else slid into the spot".
  const covered = await runTabsCtl(
    [
      'execute-js',
      '--pane',
      paneId,
      '--code',
      "(() => { const o = document.createElement('div'); o.setAttribute('aria-label', 'Blocking overlay'); o.style.cssText = 'position:fixed;inset:0;z-index:10'; document.body.appendChild(o); return true })()"
    ],
    env
  )
  expect(covered.ok).toBe(true)

  // The failure names both sides of the mismatch — what was asked for and
  // what is actually there — instead of silently clicking the cover, which
  // is exactly what the pre-fix coordinate path did.
  const clicked = await runTabsCtl(['click', '--pane', paneId, '--ref', target.ref], env)
  expect(clicked.ok).toBe(false)
  expect(clicked.error).toContain('Shifty target')
  expect(clicked.error).toContain('Blocking overlay')
  // And no events were dispatched: the guest saw no click at all.
  expect(await guestText(electronApp, '#status')).toBe('idle')

  await closeAgentSession(page, env, paneId)
})

test('semantic targets drive the page by role, name, and selector in one call', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  const status = (): Promise<string | null> => guestText(electronApp, '#status')
  await expect.poll(status).toBe('idle')

  // The headline path: no read-page first, no ref — the match happens inside
  // the page as the verb runs, and the result reports what was hit in the
  // same {role, name, tag} vocabulary read-page speaks.
  const clicked = await runTabsCtl(
    ['click', '--pane', paneId, '--role', 'button', '--name', 'Do the thing'],
    env
  )
  expect(clicked.ok).toBe(true)
  expect(clicked.result?.element).toEqual({ role: 'button', name: 'Do the thing', tag: 'button' })
  await expect.poll(status).toBe('clicked')

  // The exact tier is what kept that unambiguous: "Do the thing" also
  // prefixes this button's name, which substring matching alone would have
  // reported as a second candidate. Case-insensitive exact reaches it.
  await runTabsCtl(['click', '--pane', paneId, '--name', 'do the thing twice'], env)
  await expect.poll(status).toBe('twice-clicked')

  // A selector target reaches an element by CSS alone.
  await runTabsCtl(['click', '--pane', paneId, '--selector', '#dup-a'], env)
  await expect.poll(status).toBe('dup-a-clicked')

  // Substring is the last tier: a fragment no name equals still targets the
  // one control containing it.
  await runTabsCtl(['click', '--pane', paneId, '--name', 'thing twice'], env)
  await expect.poll(status).toBe('twice-clicked')

  // type: matched and focused in one guest pass, then real char events.
  await runTabsCtl(
    ['type', '--pane', paneId, '--role', 'textbox', '--name', 'Your name', '--text', 'ada'],
    env
  )
  await expect.poll(status).toBe('typed:ada')

  // form-input rides the same target union: a semantic select fill.
  const form = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { role: 'combobox', name: 'Pick one' }, value: 'two' }])
    ],
    env
  )
  expect(form.ok).toBe(true)
  expect(form.result?.filled).toBe(1)
  await expect.poll(status).toBe('picked:two')

  // No match is a loud failure naming the criteria, not a no-op.
  const missing = await runTabsCtl(['click', '--pane', paneId, '--name', 'Nonexistent'], env)
  expect(missing.ok).toBe(false)
  expect(missing.error).toContain('no element matches')
  expect(missing.error).toContain('Nonexistent')

  await closeAgentSession(page, env, paneId)
})

test('an ambiguous semantic target fails listing its candidates, and --nth picks among them', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  const status = (): Promise<string | null> => guestText(electronApp, '#status')
  await expect.poll(status).toBe('idle')

  // The fixture holds three "Duplicate" buttons, one display:none. Exactly 2
  // candidates means the hidden twin was excluded — counting it would make
  // name targeting useless on any page with a hidden mobile-menu duplicate —
  // and the listing carries the 0-based indices --nth indexes into.
  const ambiguous = await runTabsCtl(['click', '--pane', paneId, '--name', 'Duplicate'], env)
  expect(ambiguous.ok).toBe(false)
  expect(ambiguous.error).toContain('2 elements match')
  expect(ambiguous.error).toContain('[0]')
  expect(ambiguous.error).toContain('[1]')
  expect(ambiguous.error).toContain('nth')
  // Refused means refused: no click reached the guest.
  expect(await guestText(electronApp, '#status')).toBe('idle')

  // nth indexes that listing — 0-based, document order.
  const second = await runTabsCtl(
    ['click', '--pane', paneId, '--name', 'Duplicate', '--nth', '1'],
    env
  )
  expect(second.ok).toBe(true)
  await expect.poll(status).toBe('dup-b-clicked')

  // Out of range names the real count instead of clamping to the last match.
  const outOfRange = await runTabsCtl(
    ['click', '--pane', paneId, '--name', 'Duplicate', '--nth', '5'],
    env
  )
  expect(outOfRange.ok).toBe(false)
  expect(outOfRange.error).toContain('out of range')

  await closeAgentSession(page, env, paneId)
})

test('a role that is too strict diagnoses the near-miss instead of a generic no-match', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()
  const status = (): Promise<string | null> => guestText(electronApp, '#status')
  await expect.poll(status).toBe('idle')

  // The fixture's "Add to Cart" is a <div role="group">, not a <button> —
  // real production markup, not a contrived edge case. role stays a hard
  // filter (silently clicking across roles is exactly the wrong-target class
  // semantic targeting exists to remove), so role=button/name="Add to Cart"
  // must still miss — but the error should say *why*: the name matched, only
  // under a different role, rather than the generic "no element matches".
  const tooStrict = await runTabsCtl(
    ['click', '--pane', paneId, '--role', 'button', '--name', 'Add to Cart'],
    env
  )
  expect(tooStrict.ok).toBe(false)
  expect(tooStrict.error).toBe(
    'no button named "Add to Cart"; a group with that name exists — retry without --role'
  )
  // Refused means refused: no click reached the guest, same as any other miss.
  expect(await guestText(electronApp, '#status')).toBe('idle')

  // The suggested retry actually works: dropping --role reaches the group and
  // clicks it for real, reported in read-page's own vocabulary.
  const retried = await runTabsCtl(['click', '--pane', paneId, '--name', 'Add to Cart'], env)
  expect(retried.ok).toBe(true)
  expect(retried.result?.element).toEqual({ role: 'group', name: 'Add to Cart', tag: 'div' })
  await expect.poll(status).toBe('cart-added')

  await closeAgentSession(page, env, paneId)
})

test('the near-miss diagnosis also reaches type/form-input, via the shared matcher', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Same criteria, routed through type's focus path (focusTargetScript)
  // instead of click's hit-test path (hitTestPointScript) — both are built on
  // the one semanticResolverExpression, so the diagnosis needed no separate
  // implementation for this side.
  const typed = await runTabsCtl(
    ['type', '--pane', paneId, '--role', 'button', '--name', 'Add to Cart', '--text', 'x'],
    env
  )
  expect(typed.ok).toBe(false)
  expect(typed.error).toBe(
    'no button named "Add to Cart"; a group with that name exists — retry without --role'
  )

  await closeAgentSession(page, env, paneId)
})

test('input verbs refuse a pane this caller does not own', async ({ page }) => {
  await expectRefusedForForeignPane(page, (foreign) => [
    ['read-page', '--pane', foreign],
    ['find', '--pane', foreign, '--description', 'anything'],
    ['click', '--pane', foreign, '--x', '10', '--y', '10'],
    ['hover', '--pane', foreign, '--x', '10', '--y', '10'],
    ['type', '--pane', foreign, '--x', '10', '--y', '10', '--text', 'hi'],
    ['key', '--pane', foreign, '--key', 'Enter'],
    ['scroll', '--pane', foreign, '--direction', 'down']
  ])
})

test('form-input picks select options by value with real change events', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const select = read.result?.elements?.find((el) => el.name === 'Pick one')
  if (!select) throw new Error('readPage did not surface the select')
  expect(select.role).toBe('combobox')

  const filled = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: select.ref }, value: 'two' }])
    ],
    env
  )
  expect(filled.ok).toBe(true)
  expect(filled.result?.filled).toBe(1)
  expect(filled.exitCode).toBe(0)
  // The fixture's own change listener fired — the page saw a real change,
  // not just a silently mutated value.
  await expect.poll(() => guestText(electronApp, '#status')).toBe('picked:two')

  // A value matching no option reports the options rather than guessing.
  const unmatched = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: select.ref }, value: 'three' }])
    ],
    env
  )
  expect(unmatched.result?.filled).toBe(0)
  expect(unmatched.result?.errors?.[0]?.error).toContain('no option matching')
  expect(unmatched.result?.errors?.[0]?.error).toContain('two')
  // The response stays ok:true (the report is the useful part), but the exit
  // code reflects the failed field — batch's any-step-failed rule, so a shell
  // `&&` can't read "nothing was filled" as success.
  expect(unmatched.ok).toBe(true)
  expect(unmatched.exitCode).toBe(1)

  await closeAgentSession(page, env, paneId)
})

test('form-input sets multiline values verbatim, reads them back, and refuses fields that will not hold them', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  const notes = read.result?.elements?.find((el) => el.name === 'Notes')
  const nameField = read.result?.elements?.find((el) => el.name === 'Your name')
  const button = read.result?.elements?.find((el) => el.name === 'Do the thing')
  if (!notes || !nameField || !button) {
    throw new Error('readPage did not surface the fixture controls')
  }

  // A value the old char-event path could never deliver: embedded newlines,
  // a blank line, quotes and indentation — checked byte-for-byte end to end.
  const multiline = 'line one\nline two\n\n  "quoted" & indented\nlast line'
  const filled = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: notes.ref }, value: multiline }])
    ],
    env
  )
  expect(filled.ok).toBe(true)
  expect(filled.result?.filled).toBe(1)
  // The read-back report: exactly as many characters as were sent.
  expect(filled.result?.fields).toEqual([{ index: 0, length: multiline.length }])
  // The fixture's own input listener saw the whole value in one event —
  // a framework bound to this field would have seen the same.
  await expect.poll(() => guestText(electronApp, '#status')).toBe(`noted:${multiline.length}`)
  // And the element holds it verbatim, replacing the preset content — read
  // through main → guest, an independent path from the code under test.
  expect(await guestEval(electronApp, `document.getElementById('notes').value`)).toBe(multiline)

  // A multiline value into a single-line <input> does not survive Chromium's
  // own sanitization (it strips the newline on write), and a button is not a
  // fillable field at all — both are loud errors, neither counts as filled.
  const refused = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([
        { target: { ref: nameField.ref }, value: 'first\nsecond' },
        { target: { ref: button.ref }, value: 'x' }
      ])
    ],
    env
  )
  expect(refused.result?.filled).toBe(0)
  expect(refused.result?.fields).toBeUndefined()
  expect(refused.result?.errors).toHaveLength(2)
  expect(refused.result?.errors?.[0]?.index).toBe(0)
  expect(refused.result?.errors?.[0]?.error).toContain('11 of the 12 characters')
  expect(refused.result?.errors?.[0]?.error).toContain('cannot hold newlines')
  expect(refused.result?.errors?.[1]?.index).toBe(1)
  expect(refused.result?.errors?.[1]?.error).toContain('not a fillable field')
  // Failed fields fail the exit code even on an ok:true response.
  expect(refused.exitCode).toBe(1)
  // What the input actually holds is what the error described.
  expect(await guestEval(electronApp, `document.getElementById('name').value`)).toBe('firstsecond')

  // A contenteditable is filled through real editing commands: the preset
  // text is replaced and both lines land. (Its length is measured on
  // innerText, which normalizes blank lines — reported, not strict-checked.)
  const editor = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { selector: '#editor' }, value: 'alpha\nbeta' }])
    ],
    env
  )
  expect(editor.result?.filled).toBe(1)
  expect(editor.result?.fields?.[0]?.index).toBe(0)
  const editorText = await guestEval<string>(
    electronApp,
    `document.getElementById('editor').innerText`
  )
  expect(editorText).toContain('alpha')
  expect(editorText).toContain('beta')
  expect(editorText).not.toContain('preset')

  await closeAgentSession(page, env, paneId)
})

test('type refuses text its keystrokes cannot carry, before touching the page', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  // The char pipeline silently drops a newline on the floor, so type refuses
  // the text outright instead of sending fewer keystrokes than asked.
  const rejected = await runTabsCtl(
    ['type', '--pane', paneId, '--name', 'Your name', '--text', 'one\ntwo'],
    env
  )
  expect(rejected.ok).toBe(false)
  expect(rejected.error).toContain('a newline at index 3')
  expect(rejected.error).toContain('form-input')

  // Refused before anything was focused or typed: the page is untouched.
  expect(await guestText(electronApp, '#status')).toBe('idle')
  expect(await guestEval(electronApp, `document.getElementById('name').value`)).toBe('')

  // Plain printable text still types — the refusal is not a general gate.
  const typed = await runTabsCtl(
    ['type', '--pane', paneId, '--name', 'Your name', '--text', 'ok'],
    env
  )
  expect(typed.ok).toBe(true)
  await expect.poll(() => guestText(electronApp, '#status')).toBe('typed:ok')

  await closeAgentSession(page, env, paneId)
})

test('key delivers arrow keys with an intact key/code under every modifier, alt included', async ({
  page,
  electronApp
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect.poll(() => guestText(electronApp, '#status')).toBe('idle')

  // A capture-phase listener reporting exactly what a page-level shortcut
  // handler would see: the DOM key/code strings and the modifier flags.
  await runTabsCtl(
    [
      'execute-js',
      '--pane',
      paneId,
      '--code',
      `(() => {
        window.__lastKey = null
        document.addEventListener('keydown', (event) => {
          window.__lastKey = {
            key: event.key,
            code: event.code,
            altKey: event.altKey,
            shiftKey: event.shiftKey,
            ctrlKey: event.ctrlKey
          }
        }, true)
        true
      })()`
    ],
    env
  )

  // Electron's sendInputEvent keyCode must be a valid Accelerator token
  // ('Left'), never the DOM 'ArrowLeft' spelling its own doc warns against.
  // An unrecognized token doesn't fail only under some modifier — measured
  // directly, it produced a completely null KeyboardEvent (key:'', code:'',
  // keyCode:0) under every modifier crossed here, alt included, before
  // sendKey translated it. meta is deliberately not in this matrix: Cmd+Left
  // is the app's own default "Focus Pane Left" shortcut and is consumed by
  // guestNavKeys.ts before the guest ever sees a keydown — a different,
  // already-documented mechanism, not this bug.
  for (const modifiers of [[], ['shift'], ['control'], ['alt']]) {
    await runTabsCtl(
      [
        'key',
        '--pane',
        paneId,
        '--key',
        'ArrowLeft',
        ...(modifiers.length ? ['--modifiers', modifiers.join(',')] : [])
      ],
      env
    )
    const observed = await runTabsCtl(
      ['execute-js', '--pane', paneId, '--code', 'window.__lastKey'],
      env
    )
    expect(observed.result?.value).toEqual({
      key: 'ArrowLeft',
      code: 'ArrowLeft',
      altKey: modifiers.includes('alt'),
      shiftKey: modifiers.includes('shift'),
      ctrlKey: modifiers.includes('control')
    })
  }

  await closeAgentSession(page, env, paneId)
})
