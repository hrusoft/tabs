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
import { expect, test } from './helpers/launch'
import { paneById } from './helpers/pane'
import { FIXTURE_ASSET_BYTES, testServerForSpec } from './helpers/testServer'

// The read-back verbs: pane-info, get-text, screenshot, read-page,
// save-resource, console and network capture. Session scaffolding is
// helpers/agentSession.ts; creation/ownership live in
// external-control.spec.ts.

/**
 * One fixture origin for the whole file — see helpers/testServer.ts for why
 * these tests can't use the `data:` URLs browser.spec.ts relies on.
 */
const server = testServerForSpec()

test('an agent can read back a pane it owns: info, text, and a real PNG on disk', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The guest loads asynchronously, so poll rather than assuming the first
  // read lands after the page has parsed.
  await expect
    .poll(async () => (await runTabsCtl(['get-page-text', '--pane', paneId], env)).result?.text)
    .toContain('Hello from the fixture')

  const info = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(info.ok).toBe(true)
  expect(info.result?.title).toBe('Fixture')
  expect(info.result?.viewport?.width).toBeGreaterThan(0)

  const shot = await runTabsCtl(['screenshot', '--pane', paneId], env)
  expect(shot.ok).toBe(true)
  const shotPath = shot.result?.path
  if (!shotPath) throw new Error('screenshot did not return a path')
  // The bytes must never come back over the socket — only a path to them.
  expect(shot.result?.pngBytes).toBeUndefined()
  // A pane that was visible all along reports no `activated` key — its
  // absence is the promise that the user's visible tabs were not touched.
  expect(shot.result?.activated).toBeUndefined()
  const png = readFileSync(shotPath)
  expect(png.subarray(0, 8)).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))

  // The two coordinate spaces must stay honestly distinct: `width`/`height`
  // describe the actual PNG (device pixels), `viewport` describes the space
  // an {x,y} input target lives in (CSS pixels), and `scaleFactor` is exactly
  // the ratio between them. Asserted rather than assumed — on a 1x machine
  // these numbers coincide, so a conflation would pass unnoticed there and
  // put every coordinate-based click off by 2x on a real HiDPI screen.
  expect(shot.result?.width).toBe(png.readUInt32BE(16))
  expect(shot.result?.height).toBe(png.readUInt32BE(20))
  expect(shot.result?.viewport).toEqual(info.result?.viewport)
  expect(shot.result?.scaleFactor).toBe(
    (shot.result?.width ?? 0) / (shot.result?.viewport?.width ?? 1)
  )

  await closeAgentSession(page, env, paneId)
})

test('screenshot clips to one element, in CSS pixels, at the same scale factor', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  const full = await runTabsCtl(['screenshot', '--pane', paneId], env)
  expect(full.ok, full.error).toBe(true)

  const clipped = await runTabsCtl(['screenshot', '--pane', paneId, '--selector', '#go'], env)
  expect(clipped.ok, clipped.error).toBe(true)
  expect(clipped.result?.element?.name).toBe('Do the thing')

  const rect = clipped.result?.clipped
  if (!rect) throw new Error('a clipped screenshot did not report its rect')
  const clipPath = clipped.result?.path
  if (!clipPath) throw new Error('screenshot did not return a path')

  // The clip is a real, much smaller PNG — not a full capture with a rect
  // reported beside it. Read the dimensions out of the file itself.
  const png = readFileSync(clipPath)
  expect(png.readUInt32BE(16)).toBe(clipped.result?.width)
  expect(png.readUInt32BE(20)).toBe(clipped.result?.height)
  expect(clipped.result?.width).toBeLessThan(full.result?.width ?? 0)
  expect(clipped.result?.height).toBeLessThan(full.result?.height ?? 0)

  // The rect is CSS pixels and the image device pixels — the same split the
  // unclipped capture reports, and the reason scaleFactor must stay measured
  // against what was asked for rather than against the full viewport. A
  // clipped capture that reported a fractional scaleFactor would scale every
  // coordinate derived from it to nothing.
  expect(clipped.result?.scaleFactor).toBe(full.result?.scaleFactor)
  expect(clipped.result?.width).toBe(rect.width * (clipped.result?.scaleFactor ?? 1))
  // viewport still describes the pane, not the clip — it is the space click
  // coordinates live in, which clipping does not change.
  expect(clipped.result?.viewport).toEqual(full.result?.viewport)

  // A ref clips identically; the two forms name one element two ways.
  const read = await runTabsCtl(['read-page', '--pane', paneId, '--role', 'button'], env)
  const goRef = read.result?.elements?.find((element) => element.name === 'Do the thing')?.ref
  const byRef = await runTabsCtl(['screenshot', '--pane', paneId, '--ref', String(goRef)], env)
  expect(byRef.ok, byRef.error).toBe(true)
  expect(byRef.result?.clipped).toEqual(rect)

  // Refusals: both forms at once, and an element that isn't showing.
  const both = await runTabsCtl(
    ['screenshot', '--pane', paneId, '--selector', '#go', '--ref', String(goRef)],
    env
  )
  expect(both.ok).toBe(false)
  expect(both.error).toContain('only one of selector or ref')

  const missing = await runTabsCtl(['screenshot', '--pane', paneId, '--selector', '#nope'], env)
  expect(missing.ok).toBe(false)
  expect(missing.error).toContain('no element matches')

  await closeAgentSession(page, env, paneId)
})

test('read-back verbs refuse a pane this caller does not own', async ({ page }) => {
  await expectRefusedForForeignPane(page, (foreign) => [
    ['pane-info', '--pane', foreign],
    ['screenshot', '--pane', foreign],
    ['get-page-text', '--pane', foreign],
    ['assert', '--pane', foreign, '--text', 'anything'],
    ['save-resource', '--pane', foreign, '--url', 'https://example.com/x.png']
  ])
})

test('save-resource gets bytes out of a page: a blob behind a strict CSP, and element srcs', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/blobpage'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Wait until the page has minted its blob and pointed the iframe at it.
  await expect
    .poll(
      async () =>
        (await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.__blobReady'], env))
          .result?.value
    )
    .toBe(true)

  // The premise this verb exists for: connect-src 'self' blocks an in-page
  // fetch of the blob, so its bytes are genuinely unreachable from execute-js.
  const inPage = await runTabsCtl(
    [
      'execute-js',
      '--pane',
      paneId,
      '--code',
      "fetch(window.__blobUrl).then(() => 'reached', (e) => 'blocked:' + e.name)"
    ],
    env
  )
  expect(String(inPage.result?.value)).toContain('blocked')

  const blobUrl = (
    await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.__blobUrl'], env)
  ).result?.value
  expect(typeof blobUrl).toBe('string')

  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-save-'))

  // 1) blob: via --url --out — the reported incident, and the only route that
  //    beats the CSP (the CDP getResourceContent path).
  const blobOut = path.join(dir, 'doc.pdf')
  const savedBlob = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--url', String(blobUrl), '--out', blobOut],
    env
  )
  expect(savedBlob.ok, savedBlob.error).toBe(true)
  expect(savedBlob.result?.path).toBe(blobOut)
  expect(savedBlob.result?.bytes).toBe(FIXTURE_ASSET_BYTES.length)
  expect(readFileSync(blobOut)).toEqual(FIXTURE_ASSET_BYTES)

  // 2) an http element src by --selector — a generated path whose extension is
  //    sniffed/typed to png, and the http net route (any origin, page cookies).
  const savedImg = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--selector', 'img#pic'],
    env
  )
  expect(savedImg.ok, savedImg.error).toBe(true)
  expect(savedImg.result?.contentType).toBe('image/png')
  expect(savedImg.result?.path?.endsWith('.png')).toBe(true)
  expect(readFileSync(savedImg.result?.path ?? '')).toEqual(FIXTURE_ASSET_BYTES)

  // 3) the same asset by --ref: read-page returns the download link, whose
  //    href resolves to it.
  const structure = await runTabsCtl(['read-page', '--pane', paneId], env)
  const link = structure.result?.elements?.find((el) => el.tag === 'a')
  if (!link) throw new Error('read-page did not return the download link')
  const refOut = path.join(dir, 'via-ref.bin')
  const savedRef = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--ref', link.ref, '--out', refOut],
    env
  )
  expect(savedRef.ok, savedRef.error).toBe(true)
  expect(readFileSync(refOut)).toEqual(FIXTURE_ASSET_BYTES)

  // --out never clobbers: a second save to the same path is refused, not
  // silently overwritten.
  const clobber = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--url', String(blobUrl), '--out', blobOut],
    env
  )
  expect(clobber.ok).toBe(false)
  expect(clobber.error).toContain('refusing to overwrite')

  // file: is refused on the front door — the load-bearing overlap with the
  // http(s) net route, which could otherwise read a local file.
  const refusedFile = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--url', 'file:///etc/hosts'],
    env
  )
  expect(refusedFile.ok).toBe(false)
  expect(refusedFile.error).toContain('not allowed')

  // The one genuinely unreachable blob: minted but never loaded, on a page
  // whose CSP blocks blob fetches — the resource tree can't see it and the
  // in-page fetch is refused. The error must name BOTH failed routes, because
  // "no longer available" alone once sent a caller whose blob was alive the
  // whole time chasing revocation.
  const unloaded = (
    await runTabsCtl(
      [
        'execute-js',
        '--pane',
        paneId,
        '--code',
        "(() => { window.__unloaded = URL.createObjectURL(new Blob(['x'])); return window.__unloaded })()"
      ],
      env
    )
  ).result?.value
  const unreachable = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--url', String(unloaded)],
    env
  )
  expect(unreachable.ok).toBe(false)
  expect(unreachable.error).toContain("not among the page's loaded resources")
  expect(unreachable.error).toContain('fetching it inside the page failed')

  rmSync(dir, { recursive: true, force: true })
  await closeAgentSession(page, env, paneId)
})

test('save-resource reads a blob the page only minted — the about:blank cases the resource tree cannot see', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', 'about:blank')
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // Deterministic bytes minted inside the page; the test mirrors the formula,
  // so both saves below are compared byte for byte against this buffer.
  const expected = Buffer.from(Array.from({ length: 600 }, (_, i) => (i * 7 + 3) % 256))
  const blobUrl = (
    await runTabsCtl(
      [
        'execute-js',
        '--pane',
        paneId,
        '--code',
        '(() => { window.__u = URL.createObjectURL(new Blob([Uint8Array.from({ length: 600 }, (_, i) => (i * 7 + 3) % 256)], { type: "application/pdf" })); return window.__u })()'
      ],
      env
    )
  ).result?.value
  expect(String(blobUrl)).toMatch(/^blob:/)

  // Case 1 (as reported): the blob was created but never loaded anywhere, so
  // it is in no frame's resource tree — only the in-page fetch route reaches
  // it, and about:blank has no CSP to block that.
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-save-'))
  const out = path.join(dir, 'minted.pdf')
  const saved = await runTabsCtl(
    ['save-resource', '--pane', paneId, '--url', String(blobUrl), '--out', out],
    env
  )
  expect(saved.ok, saved.error).toBe(true)
  expect(saved.result?.bytes).toBe(expected.length)
  expect(saved.result?.contentType).toBe('application/pdf')
  expect(readFileSync(out)).toEqual(expected)

  // Case 2 (as reported): the same blob as an iframe's src, targeted by
  // --selector. Loaded, but a blob:null document on about:blank still lists
  // no resources (measured), so this too rides the fetch fallback. No --out:
  // the generated name takes its extension from the blob's own type.
  await runTabsCtl(
    [
      'execute-js',
      '--pane',
      paneId,
      '--code',
      '(() => { const f = document.createElement("iframe"); f.id = "fr"; f.src = window.__u; document.body.appendChild(f); return true })()'
    ],
    env
  )
  const savedFrame = await runTabsCtl(['save-resource', '--pane', paneId, '--selector', '#fr'], env)
  expect(savedFrame.ok, savedFrame.error).toBe(true)
  expect(savedFrame.result?.path?.endsWith('.pdf')).toBe(true)
  expect(readFileSync(savedFrame.result?.path ?? '')).toEqual(expected)

  rmSync(dir, { recursive: true, force: true })
  await closeAgentSession(page, env, paneId)
})

/**
 * pane-info's two honesty gaps, both of which reported a plausible-looking
 * answer rather than an obviously wrong one.
 */
test('pane-info flags an error page and refuses to invent a viewport for a hidden pane', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  // A healthy, visible pane: a real viewport, and neither flag.
  const healthy = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(healthy.ok).toBe(true)
  expect(healthy.result?.viewport?.width).toBeGreaterThan(0)
  expect(healthy.result?.showingErrorPage).toBeUndefined()
  expect(healthy.result?.hidden).toBeUndefined()

  // A failed navigation leaves Chromium's error page showing while getURL()
  // keeps reporting the address that was asked for — the case that gave an
  // agent no way to tell a real page from a failure wearing its address.
  const dead = await deadOrigin()
  const failed = await runTabsCtl(['navigate', '--pane', paneId, '--url', dead], env)
  expect(failed.ok).toBe(false)

  const errored = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(errored.ok).toBe(true)
  expect(errored.result?.showingErrorPage).toBe(true)
  expect(errored.result?.loadError).toContain('ERR_')
  // url is deliberately unchanged in shape: it is still the visible address.
  expect(errored.result?.url).toContain('127.0.0.1')

  // Recovering clears the flag — it describes the load in flight, not a
  // sticky "this pane once failed" bit.
  const recovered = await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url()], env)
  expect(recovered.ok).toBe(true)
  const healed = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(healed.result?.showingErrorPage).toBeUndefined()
  expect(healed.result?.loadError).toBeUndefined()

  // Backgrounded: no viewport at all rather than a zero one, plus the flag
  // that names the remedy.
  await page.locator('.tab:not(.tab-active)').first().click()
  await expect(paneById(page, paneId)).toBeHidden()
  const backgrounded = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(backgrounded.ok).toBe(true)
  expect(backgrounded.result?.hidden).toBe(true)
  expect(backgrounded.result?.viewport).toBeUndefined()

  // …and activate-pane is what makes it answerable again, as the docs say.
  expect((await runTabsCtl(['activate-pane', '--pane', paneId], env)).ok).toBe(true)
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.hidden)
    .toBeUndefined()
  const revealed = await runTabsCtl(['pane-info', '--pane', paneId], env)
  expect(revealed.result?.viewport?.width).toBeGreaterThan(0)

  await closeAgentSession(page, env, paneId)
})

/**
 * The reported failure: read-page's 200-element cap spent on filter controls
 * before it reaches the one that matters. The fixture is built so a bare read
 * genuinely cannot see `#sort` — 240 checkboxes precede it in document order —
 * which is what makes the narrowed reads below prove something rather than
 * merely agreeing with the unnarrowed one.
 */
test('read-page narrows by role and selector, and pages by offset', async ({ page }) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/listing'))

  // Bare read: capped, and the <select> really is out of reach.
  const bare = await runTabsCtl(['read-page', '--pane', paneId], env)
  expect(bare.ok).toBe(true)
  expect(bare.result?.elements).toHaveLength(200)
  expect(bare.result?.truncated).toBe(true)
  expect(bare.result?.offset).toBe(0)
  expect(bare.result?.total).toBeGreaterThan(240)
  expect(bare.result?.elements?.some((element) => element.tag === 'select')).toBe(false)

  // --role reaches it in one call, which is the whole point of the flag.
  const byRole = await runTabsCtl(['read-page', '--pane', paneId, '--role', 'combobox'], env)
  expect(byRole.ok).toBe(true)
  expect(byRole.result?.elements?.map((element) => element.tag)).toEqual(['select'])
  expect(byRole.result?.truncated).toBe(false)
  expect(byRole.result?.total).toBe(1)

  // --selector reaches elements the default candidate set never lists at all.
  const images = await runTabsCtl(['read-page', '--pane', paneId, '--selector', 'img[alt]'], env)
  expect(images.ok).toBe(true)
  expect(images.result?.elements?.map((element) => element.name)).toEqual([
    'Hero image',
    'Thumb image'
  ])

  // Paging: offset walks past the cap and reports where it is.
  const paged = await runTabsCtl(['read-page', '--pane', paneId, '--offset', '200'], env)
  expect(paged.ok).toBe(true)
  expect(paged.result?.offset).toBe(200)
  expect(paged.result?.truncated).toBe(false)
  expect(paged.result?.elements?.some((element) => element.tag === 'select')).toBe(true)
  // Refs are minted for the returned page only, so a paged read hands back
  // usable refs rather than ones evicted by the elements it skipped.
  const sort = paged.result?.elements?.find((element) => element.tag === 'select')
  const picked = await runTabsCtl(
    [
      'form-input',
      '--pane',
      paneId,
      '--fields',
      JSON.stringify([{ target: { ref: sort?.ref }, value: 'price' }])
    ],
    env
  )
  expect(picked.ok).toBe(true)
  expect(picked.result?.filled).toBe(1)

  // A selector the page itself refuses is an error, never an empty list —
  // "nothing matched" and "that isn't a selector" are different answers.
  const bad = await runTabsCtl(['read-page', '--pane', paneId, '--selector', 'div:::nope'], env)
  expect(bad.ok).toBe(false)
  expect(bad.error).toContain('invalid selector')

  // Wire-shape validation is host-side, since the socket carries untyped input.
  const negative = await runTabsCtl(['read-page', '--pane', paneId, '--offset=-3'], env)
  expect(negative.ok).toBe(false)
  expect(negative.error).toContain('at least 0')

  await closeAgentSession(page, env, paneId)
})

test('an agent can read the console, including a message that arrives late', async ({ page }) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  await expect
    .poll(async () =>
      (await runTabsCtl(['read-console', '--pane', paneId], env)).result?.messages?.map(
        (message) => message.text
      )
    )
    .toEqual(
      expect.arrayContaining([
        'fixture ready',
        'a warning happened',
        'an error happened',
        // Emitted from a setTimeout, so it can only be here because the buffer
        // captures as messages arrive rather than being asked for after.
        'delayed message'
      ])
    )

  const all = await runTabsCtl(['read-console', '--pane', paneId], env)
  const levels = new Set(all.result?.messages?.map((message) => message.level))
  expect(levels).toContain('error')
  expect(levels).toContain('warning')

  // A pattern narrows the read, and sinceSeq makes repeat polling incremental.
  // Anchored, because an unpackaged build also gets Electron's own injected
  // CSP security warning in the guest console — a loose `warning` matches it.
  const warnings = await runTabsCtl(
    ['read-console', '--pane', paneId, '--pattern', '^a warning happened$'],
    env
  )
  expect(warnings.result?.messages?.map((m) => m.text)).toEqual(['a warning happened'])

  // An unparseable pattern is refused, not silently matched as literal text
  // — the same trap and the same fix as read-network's --pattern.
  const badPattern = await runTabsCtl(['read-console', '--pane', paneId, '--pattern', '['], env)
  expect(badPattern.ok).toBe(false)
  expect(badPattern.error).toContain('--pattern')

  const lastSeq = Math.max(...(all.result?.messages ?? []).map((m) => m.seq))
  const nothingNew = await runTabsCtl(
    ['read-console', '--pane', paneId, '--since-seq', String(lastSeq)],
    env
  )
  expect(nothingNew.result?.messages).toEqual([])

  // Navigating starts a fresh page, and so a fresh console.
  await runTabsCtl(['navigate', '--pane', paneId, '--url', server.url('/other')], env)
  await expect
    .poll(async () => (await runTabsCtl(['pane-info', '--pane', paneId], env)).result?.title)
    .toBe('Elsewhere')
  // None of the previous document's output survives. Asserted as "the old
  // messages are gone" rather than "the buffer is empty", since an unpackaged
  // build immediately re-injects Electron's own CSP warning into the new page.
  const afterNavigation = await runTabsCtl(['read-console', '--pane', paneId], env)
  const carriedOver = (afterNavigation.result?.messages ?? []).filter((message) =>
    ['fixture ready', 'a warning happened', 'an error happened', 'delayed message'].includes(
      message.text
    )
  )
  expect(carriedOver).toEqual([])

  await closeAgentSession(page, env, paneId)
})

test('an agent can read network metadata, with credential headers redacted by default', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The fixture loads a sub-resource and fires a fetch, so this is a real
  // multi-request lifecycle rather than just the document.
  await expect
    .poll(async () =>
      (await runTabsCtl(['read-network', '--pane', paneId], env)).result?.requests?.map(
        (r) => r.url
      )
    )
    .toEqual(
      expect.arrayContaining([
        server.url('/page'),
        server.url('/script.js'),
        server.url('/api/secret')
      ])
    )

  const requests = await runTabsCtl(['read-network', '--pane', paneId], env)
  // The document request survives its own log reset — it is the first entry.
  expect(requests.result?.requests?.[0]?.url).toBe(server.url('/page'))
  const secret = requests.result?.requests?.find((r) => r.url === server.url('/api/secret'))
  expect(secret?.status).toBe(200)
  expect(secret?.method).toBe('GET')
  expect(secret?.responseHeaders?.['set-cookie']).toBe('<redacted>')
  // A non-sensitive header is left alone, so redaction isn't just dropping headers.
  expect(secret?.responseHeaders?.['x-fixture-header']).toBe('fixture-value')

  const unredacted = await runTabsCtl(['read-network', '--pane', paneId, '--unredacted'], env)
  expect(
    unredacted.result?.requests?.find((r) => r.url === server.url('/api/secret'))
      ?.responseHeaders?.['set-cookie']
  ).toContain('super-secret-value')

  const filtered = await runTabsCtl(['read-network', '--pane', paneId, '--pattern', 'script'], env)
  expect(filtered.result?.requests?.map((r) => r.url)).toEqual([server.url('/script.js')])

  await closeAgentSession(page, env, paneId)
})

test('an agent can capture response bodies: opt-in, size-capped and content-type aware', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  const readBodies = (pattern: string): ReturnType<typeof runTabsCtl> =>
    runTabsCtl(['read-network', '--pane', paneId, '--with-bodies', '--pattern', pattern], env)

  // Before capture is enabled, --with-bodies degrades to metadata plus the
  // "you forgot capture-bodies" signal, not an error.
  const before = await readBodies('api/secret')
  expect(before.ok).toBe(true)
  expect(before.result?.bodyCapture).toBe('off')
  expect(
    (before.result?.requests ?? []).every((request) => request.responseBody === undefined)
  ).toBe(true)

  const on = await runTabsCtl(['capture-bodies', '--pane', paneId], env)
  expect(on.ok).toBe(true)
  expect(on.result?.enabled).toBe(true)

  // Capture starts *now* — reload so the page's requests happen under it.
  expect((await runTabsCtl(['reload', '--pane', paneId], env)).ok).toBe(true)

  // A small same-origin JSON body arrives inline and uncut.
  await expect
    .poll(async () => (await readBodies('api/secret')).result?.requests?.[0]?.responseBody?.body)
    .toContain('"ok":true')
  const secret = await readBodies('api/secret')
  expect(secret.result?.bodyCapture).toBe('on')
  expect(secret.result?.requests?.[0]?.responseBody).toMatchObject({
    truncated: false,
    mimeType: 'application/json'
  })

  // The plain metadata read's shape is untouched by capture being on.
  const plain = await runTabsCtl(['read-network', '--pane', paneId, '--pattern', 'api/secret'], env)
  expect(plain.result?.bodyCapture).toBeUndefined()
  expect(plain.result?.requests?.[0]?.responseBody).toBeUndefined()

  // An over-cap body is cut explicitly: truncated says so, size is the whole.
  expect(
    (
      await runTabsCtl(
        [
          'execute-js',
          '--pane',
          paneId,
          '--code',
          "fetch('/api/big').then((r) => r.text()).then((t) => t.length)"
        ],
        env
      )
    ).ok
  ).toBe(true)
  await expect
    .poll(async () => (await readBodies('api/big')).result?.requests?.[0]?.responseBody?.truncated)
    .toBe(true)
  const big = (await readBodies('api/big')).result?.requests?.[0]?.responseBody
  expect(big?.body).toHaveLength(16384)
  expect(big?.size).toBeGreaterThan(16384)

  // A binary body reports type and size, never content.
  expect(
    (
      await runTabsCtl(
        [
          'execute-js',
          '--pane',
          paneId,
          '--code',
          "fetch('/asset.png').then((r) => r.blob()).then((b) => b.size)"
        ],
        env
      )
    ).ok
  ).toBe(true)
  await expect
    .poll(async () => (await readBodies('asset')).result?.requests?.[0]?.responseBody?.binary)
    .toBe(true)
  const binary = (await readBodies('asset')).result?.requests?.[0]?.responseBody
  expect(binary?.body).toBeUndefined()
  expect(binary?.mimeType).toBe('image/png')
  // Chromium pipes binary bodies straight to the page rather than buffering
  // them, so the size is the wire-level count (520 asset bytes plus a little
  // transfer framing) — best effort by design, but never a lying zero.
  expect(binary?.size).toBeGreaterThanOrEqual(520)
  expect(binary?.size).toBeLessThan(700)

  // --off detaches; reads report capture off again, still without erroring.
  const off = await runTabsCtl(['capture-bodies', '--pane', paneId, '--off'], env)
  expect(off.ok).toBe(true)
  expect(off.result?.enabled).toBe(false)
  expect((await readBodies('api/secret')).result?.bodyCapture).toBe('off')

  await closeAgentSession(page, env, paneId)
})

/**
 * The three sizes of read-network's size problem: the whole log (--brief and
 * --out), and one body that exceeds the inline cap (--max-body + --body-out).
 *
 * The cap raise has to happen *before* the request, which is the whole shape
 * of the feature — a body is capped as it arrives and the rest is released, so
 * there is nothing to recover afterwards.
 */
test('read-network can answer briefly, to a file, and hand back one body whole', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url())

  // --brief keeps the identity/outcome fields and drops the header maps.
  const brief = await runTabsCtl(['read-network', '--pane', paneId, '--brief'], env)
  expect(brief.ok, brief.error).toBe(true)
  const first = brief.result?.requests?.[0]
  expect(first?.seq).toEqual(expect.any(Number))
  expect(first?.method).toBeTruthy()
  expect(first?.url).toBeTruthy()
  expect(first?.requestHeaders).toBeUndefined()
  expect(first?.responseHeaders).toBeUndefined()

  // …and the full form still carries them, so --brief is a projection rather
  // than a change to what is captured.
  const fullRead = await runTabsCtl(['read-network', '--pane', paneId], env)
  expect(fullRead.result?.requests?.[0]?.responseHeaders).toBeTruthy()

  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-net-'))
  const logPath = path.join(dir, 'log.json')
  const written = await runTabsCtl(['read-network', '--pane', paneId, '--out', logPath], env)
  expect(written.ok, written.error).toBe(true)
  expect(written.result?.path).toBe(logPath)
  expect(written.result?.count).toBe(fullRead.result?.requests?.length)
  // The file is the answer, and it parses.
  const onDisk = JSON.parse(readFileSync(logPath, 'utf-8')) as { requests: unknown[] }
  expect(onDisk.requests).toHaveLength(written.result?.count ?? -1)
  expect(written.result?.requests).toBeUndefined()

  // The body path. Raise the cap first — /api/big is ~20k, past the 16,384
  // default — then make the request, then read it back whole.
  const raised = await runTabsCtl(['capture-bodies', '--pane', paneId, '--max-body', '200000'], env)
  expect(raised.ok, raised.error).toBe(true)
  expect(raised.result?.maxBodyChars).toBe(200000)

  expect(
    (
      await runTabsCtl(
        [
          'execute-js',
          '--pane',
          paneId,
          '--code',
          "fetch('/api/big').then((r) => r.text()).then((t) => t.length)"
        ],
        env
      )
    ).ok
  ).toBe(true)

  await expect
    .poll(
      async () =>
        (
          await runTabsCtl(
            ['read-network', '--pane', paneId, '--with-bodies', '--pattern', 'api/big'],
            env
          )
        ).result?.requests?.[0]?.responseBody?.truncated
    )
    .toBe(false)

  const captured = await runTabsCtl(
    ['read-network', '--pane', paneId, '--with-bodies', '--pattern', 'api/big'],
    env
  )
  const entry = captured.result?.requests?.[0]
  // The raised cap held the whole body, where the default would have cut it.
  expect(entry?.responseBody?.body?.length).toBeGreaterThan(16384)

  const bodyPath = path.join(dir, 'body.json')
  const savedBody = await runTabsCtl(
    ['read-network', '--pane', paneId, '--body-seq', String(entry?.seq), '--body-out', bodyPath],
    env
  )
  expect(savedBody.ok, savedBody.error).toBe(true)
  expect(savedBody.result?.path).toBe(bodyPath)
  expect(savedBody.result?.seq).toBe(entry?.seq)
  // The file holds the real response, in full — the point of the whole path.
  const body = JSON.parse(readFileSync(bodyPath, 'utf-8')) as { filler: string }
  expect(body.filler).toHaveLength(20000)

  // A seq that isn't there says *why* it might not be, rather than "no such
  // request": dedup remints seqs, so a stale one is an ordinary mistake.
  const stale = await runTabsCtl(
    [
      'read-network',
      '--pane',
      paneId,
      '--body-seq',
      '99999',
      '--body-out',
      path.join(dir, 'x.txt')
    ],
    env
  )
  expect(stale.ok).toBe(false)
  expect(stale.error).toContain('takes a new seq')

  // A binary body has nothing to write, and says so naming the alternative.
  expect(
    (
      await runTabsCtl(
        [
          'execute-js',
          '--pane',
          paneId,
          '--code',
          "fetch('/asset.png').then((r) => r.blob()).then((b) => b.size)"
        ],
        env
      )
    ).ok
  ).toBe(true)
  await expect
    .poll(
      async () =>
        (
          await runTabsCtl(
            ['read-network', '--pane', paneId, '--with-bodies', '--pattern', 'asset'],
            env
          )
        ).result?.requests?.[0]?.responseBody?.binary
    )
    .toBe(true)
  const binarySeq = (
    await runTabsCtl(['read-network', '--pane', paneId, '--pattern', 'asset'], env)
  ).result?.requests?.[0]?.seq
  const binaryOut = await runTabsCtl(
    [
      'read-network',
      '--pane',
      paneId,
      '--body-seq',
      String(binarySeq),
      '--body-out',
      path.join(dir, 'bin.txt')
    ],
    env
  )
  expect(binaryOut.ok).toBe(false)
  expect(binaryOut.error).toContain('save-resource')

  // --body-out without a seq is refused rather than guessing which entry.
  const seqless = await runTabsCtl(
    ['read-network', '--pane', paneId, '--body-out', path.join(dir, 'y.txt')],
    env
  )
  expect(seqless.ok).toBe(false)

  rmSync(dir, { recursive: true, force: true })
  await closeAgentSession(page, env, paneId)
})

test('read-network narrows to what broke and collapses a poll loop into one counted entry', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  const read = (...flags: string[]): ReturnType<typeof runTabsCtl> =>
    runTabsCtl(['read-network', '--pane', paneId, ...flags], env)
  const fetchFromPage = async (code: string): Promise<void> => {
    expect((await runTabsCtl(['execute-js', '--pane', paneId, '--code', code], env)).ok).toBe(true)
  }

  // Wait until the page's own single /api/secret fetch has completed, so the
  // repeats below merge into a settled entry rather than racing its start.
  await expect
    .poll(async () => (await read('--pattern', 'api/secret')).result?.requests?.[0]?.status)
    .toBe(200)

  // Three more identical fetches — with the page's own, four occurrences.
  await fetchFromPage(
    "fetch('/api/secret').then(() => fetch('/api/secret')).then(() => fetch('/api/secret')).then((r) => r.status)"
  )

  // The poll loop collapsed: one counted entry, not four slots.
  await expect
    .poll(async () => (await read('--pattern', 'api/secret')).result?.requests?.map((r) => r.count))
    .toEqual([4])
  const collapsed = (await read('--pattern', 'api/secret')).result?.requests?.[0]
  expect(collapsed?.firstStartedAt ?? Number.NaN).toBeLessThanOrEqual(collapsed?.startedAt ?? 0)

  // The collapse moved nothing else: the document is still the first entry,
  // and a lone request carries no count at all — its wire shape is unchanged.
  const all = (await read()).result?.requests
  expect(all?.[0]?.url).toBe(server.url('/page'))
  expect('count' in (all?.find((r) => r.url === server.url('/script.js')) ?? {})).toBe(false)

  // A failure to narrow to, then the filters that find it.
  await fetchFromPage("fetch('/missing').then((r) => r.status)")
  await expect
    .poll(async () => (await read('--failed')).result?.requests?.map((r) => r.url))
    .toEqual([server.url('/missing')])
  expect((await read('--status', '404')).result?.requests?.map((r) => r.url)).toEqual([
    server.url('/missing')
  ])
  expect((await read('--status', '4xx')).result?.requests?.map((r) => r.url)).toEqual([
    server.url('/missing')
  ])
  expect((await read('--resource-type', 'script')).result?.requests?.map((r) => r.url)).toEqual([
    server.url('/script.js')
  ])

  // A POST to the polled URL keeps its own entry — method is part of a
  // repeat's identity — and --method finds exactly it.
  await fetchFromPage("fetch('/api/secret', { method: 'POST' }).then((r) => r.status)")
  await expect
    .poll(async () => (await read('--method', 'post')).result?.requests?.map((r) => r.url))
    .toEqual([server.url('/api/secret')])
  expect(
    (await read('--pattern', 'api/secret')).result?.requests?.map((r) => [r.method, r.count ?? 1])
  ).toEqual([
    ['GET', 4],
    ['POST', 1]
  ])

  // A typo'd status spec is refused with the accepted forms, not answered
  // with an empty list that would read as "nothing failed".
  const refused = await read('--status', 'flaky')
  expect(refused.ok).toBe(false)
  expect(refused.error).toContain('(404)')

  // Every other filter refuses the same way, over the real socket.
  const badMethod = await read('--method', 'FROBNICATE')
  expect(badMethod.ok).toBe(false)
  expect(badMethod.error).toContain('GET')

  // The documented trap: fetch traffic reports as xhr, not "fetch" — the
  // refusal names that rather than reading as "no fetch calls happened".
  const badResourceType = await read('--resource-type', 'fetch')
  expect(badResourceType.ok).toBe(false)
  expect(badResourceType.error).toContain('xhr')

  const badPattern = await read('--pattern', '[')
  expect(badPattern.ok).toBe(false)
  expect(badPattern.error).toContain('--pattern')

  await closeAgentSession(page, env, paneId)
})

test('capture verbs refuse a pane this caller does not own', async ({ page }) => {
  await expectRefusedForForeignPane(page, (foreign) => [
    ['read-console', '--pane', foreign],
    ['read-network', '--pane', foreign],
    ['capture-bodies', '--pane', foreign]
  ])
})

test('read verbs report readiness, and settled flips only with the DOM actually quiet', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/waity'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The first read of a page is what starts the observation, so it can never
  // certify quiet: settled is false by design even on this fully loaded
  // static page, while the document-level fields tell the rest of the story.
  const first = await runTabsCtl(['read-page', '--pane', paneId], env)
  expect(first.ok).toBe(true)
  expect(((first.result?.elements ?? []) as unknown[]).length).toBeGreaterThan(0)
  expect(first.result?.isLoading).toBe(false)
  expect(first.result?.readyState).toBe('complete')
  expect(first.result?.settled).toBe(false)

  // Re-reads share the tracker rather than restarting it, so once the page
  // has been observed quiet for the shared 500ms period a read says so —
  // polling with the read itself is also what pins that reads don't reset
  // the quiet clock (they'd never flip to true if they did).
  await expect
    .poll(
      async () => (await runTabsCtl(['get-page-text', '--pane', paneId], env)).result?.settled,
      { timeout: 15000 }
    )
    .toBe(true)

  // find carries the same trio, from the same extraction.
  const found = await runTabsCtl(['find', '--pane', paneId, '--description', 'waity'], env)
  expect(found.ok).toBe(true)
  expect(found.result?.isLoading).toBe(false)
  expect(found.result?.readyState).toBe('complete')
  expect(found.result?.settled).toBe(true)

  // Churn mutates immediately and every 100ms for 3s: a read landing inside
  // that window reports unsettled — the mid-hydration case the fields exist
  // for — and a later read reports the page settled again once the churn has
  // ended plus the quiet period.
  await runTabsCtl(['execute-js', '--pane', paneId, '--code', 'window.churn(3000)'], env)
  const during = await runTabsCtl(['read-page', '--pane', paneId], env)
  expect(during.ok).toBe(true)
  expect(during.result?.settled).toBe(false)
  await expect
    .poll(async () => (await runTabsCtl(['read-page', '--pane', paneId], env)).result?.settled, {
      timeout: 20000
    })
    .toBe(true)

  await closeAgentSession(page, env, paneId)
})

test('read verbs report frame/shadow counts, and coordinate clicks reach inside both even though reads cannot', async ({
  page
}) => {
  const { env } = await openAgentSession(page)
  const paneId = await createAgentPane(env, '--url', server.url('/nested'))
  await expect(paneById(page, paneId).getByTestId('browser')).toBeVisible()

  // The counts: one iframe, one open shadow root — always present (0 would
  // report the same way), so an agent learns the fields exist before it ever
  // needs them. get-page-text and find carry the same pair, from the same
  // guest extraction as read-page.
  const read = await runTabsCtl(['read-page', '--pane', paneId], env)
  expect(read.ok).toBe(true)
  expect(read.result?.frames).toBe(1)
  expect(read.result?.shadowRoots).toBe(1)
  const text = await runTabsCtl(['get-page-text', '--pane', paneId], env)
  expect(text.result?.frames).toBe(1)
  expect(text.result?.shadowRoots).toBe(1)
  const found = await runTabsCtl(['find', '--pane', paneId, '--description', 'button'], env)
  expect(found.result?.frames).toBe(1)
  expect(found.result?.shadowRoots).toBe(1)

  // The documented blindness, now measurable instead of assumed: read-page
  // lists the top-document button but neither the frame's nor the shadow
  // button, and find's matches are drawn from that same set.
  const names = (read.result?.elements ?? []).map((el) => el.name)
  expect(names).toContain('Top button')
  expect(names).not.toContain('Frame button')
  expect(names).not.toContain('Shadow button')
  const matchNames = (found.result?.matches ?? []).map((m) => m.name)
  expect(matchNames).not.toContain('Frame button')
  expect(matchNames).not.toContain('Shadow button')

  // The workaround SKILL.md documents: compute the target's viewport
  // coordinate with execute-js (frame case: the element's rect inside the
  // frame's own document, plus the <iframe> element's own offset in the top
  // document — only possible because this fixture's frame is same-origin,
  // which is what makes contentDocument reachable at all), then click by
  // coordinate. A poll guards the iframe's own document/subresource load,
  // which is not something the outer pane's `loaded` wait guarantees finished.
  await expect
    .poll(
      async () => {
        const check = await runTabsCtl(
          [
            'execute-js',
            '--pane',
            paneId,
            '--code',
            "!!document.getElementById('the-frame').contentDocument?.getElementById('frame-button')"
          ],
          env
        )
        return check.result?.value
      },
      { timeout: 10000 }
    )
    .toBe(true)
  const framePoint = (
    await runTabsCtl(
      [
        'execute-js',
        '--pane',
        paneId,
        '--code',
        `(() => {
          const frame = document.getElementById('the-frame')
          const frameRect = frame.getBoundingClientRect()
          const btn = frame.contentDocument.getElementById('frame-button')
          const btnRect = btn.getBoundingClientRect()
          return {
            x: frameRect.x + btnRect.x + btnRect.width / 2,
            y: frameRect.y + btnRect.y + btnRect.height / 2
          }
        })()`
      ],
      env
    )
  ).result?.value as { x: number; y: number }

  const frameClick = await runTabsCtl(
    ['click', '--pane', paneId, '--x', String(framePoint.x), '--y', String(framePoint.y)],
    env
  )
  expect(frameClick.ok).toBe(true)
  // Real input at the compositor level reaches inside the frame — the click
  // fires the button's own handler — but the *reporting* half only ever
  // queries the top document's elementFromPoint, which does not cross a
  // frame boundary even same-origin: it names the <iframe> itself, never the
  // element inside it. Documented as exactly that rather than implied to
  // reach as far as the click itself does.
  expect(frameClick.result?.element?.tag).toBe('iframe')
  await expect
    .poll(
      async () =>
        (
          await runTabsCtl(
            ['execute-js', '--pane', paneId, '--code', 'window.frameButtonClicked'],
            env
          )
        ).result?.value
    )
    .toBe(true)

  // Shadow DOM case: shadowRoot.querySelector then the element's own rect —
  // no host offset needed, since an open shadow tree renders inline in the
  // normal visual flow.
  const shadowPoint = (
    await runTabsCtl(
      [
        'execute-js',
        '--pane',
        paneId,
        '--code',
        `(() => {
          const btn = document.getElementById('shadow-host').shadowRoot.querySelector('#shadow-button')
          const rect = btn.getBoundingClientRect()
          return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
        })()`
      ],
      env
    )
  ).result?.value as { x: number; y: number }

  const shadowClick = await runTabsCtl(
    ['click', '--pane', paneId, '--x', String(shadowPoint.x), '--y', String(shadowPoint.y)],
    env
  )
  expect(shadowClick.ok).toBe(true)
  // Measured, not assumed from spec-reading: elementFromPoint retargets
  // across a shadow boundary the same way it stops at a frame boundary —
  // open mode governs script access to the tree (shadowRoot, querySelector),
  // not what a *document-scoped* hit test reports. The result names the
  // shadow host (a bare div here), not the button inside it. So the
  // reporting is imprecise for both routes the workaround uses, not just the
  // frame one — corrected from an earlier, wrong assumption that shadow DOM
  // would report precisely where a frame would not.
  expect(shadowClick.result?.element?.tag).toBe('div')
  expect(shadowClick.result?.element?.name).toBe('')
  expect(
    (
      await runTabsCtl(
        ['execute-js', '--pane', paneId, '--code', 'window.shadowButtonClicked'],
        env
      )
    ).result?.value
  ).toBe(true)

  await closeAgentSession(page, env, paneId)
})

test('screenshot reveals a backgrounded pane itself and says so with activated: true', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  // Background the agent's pane the way a user does — switch back to the
  // terminal's tab (see the activate-pane test above for why this shape).
  await expect(paneById(page, paneId)).toBeVisible()
  await page.locator('.tab:not(.tab-active)').first().click()
  await expect(paneById(page, paneId)).toBeHidden()

  // No activate-pane first: the reveal is the verb's own. This is also what
  // holds the checkVisibility() pre-check honest — against the old capture,
  // a hidden pane answered with a failure (or nothing until the relay
  // timeout), never a PNG.
  const shot = await runTabsCtl(['screenshot', '--pane', paneId], env)
  expect(shot.ok).toBe(true)
  expect(shot.result?.activated).toBe(true)
  const shotPath = shot.result?.path
  if (!shotPath) throw new Error('screenshot did not return a path')
  const png = readFileSync(shotPath)
  expect(png.subarray(0, 8)).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  await expect(paneById(page, paneId)).toBeVisible()

  // The reveal rides the same revealPane as activate-pane: what's visible
  // changed, but the keyboard never landed in the guest.
  expect(await page.evaluate(() => document.activeElement?.tagName)).not.toBe('WEBVIEW')

  await closeAgentSession(page, env, paneId)
})

test('screenshot --no-activate fails on a backgrounded pane and leaves the visible tab alone', async ({
  page
}) => {
  const { env } = await openAgentSession(page)

  const paneId = await createAgentPane(env, '--url', server.url())

  await expect(paneById(page, paneId)).toBeVisible()
  await page.locator('.tab:not(.tab-active)').first().click()
  await expect(paneById(page, paneId)).toBeHidden()

  const shot = await runTabsCtl(['screenshot', '--pane', paneId, '--no-activate'], env)
  expect(shot.ok).toBe(false)
  expect(shot.error).toContain('the pane is hidden')
  // The refusal is the whole point of the flag: the user's visible tab did
  // not change.
  await expect(paneById(page, paneId)).toBeHidden()

  await closeAgentSession(page, env, paneId)
})
