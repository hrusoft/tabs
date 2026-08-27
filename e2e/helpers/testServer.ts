import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { test } from './launch'

/**
 * A throwaway localhost origin for the external-control tests.
 *
 * `data:` URLs (what browser.spec.ts uses to stay hermetic) can't serve here
 * for two reasons: `createBrowserPane` only accepts http(s)/about:blank, so
 * an agent can't load one at all, and a single self-contained document has no
 * sub-resource request lifecycle for the network-capture verbs to observe.
 * This is still hermetic — it binds 127.0.0.1 on an ephemeral port and never
 * leaves the machine.
 *
 * The fixture page is deliberately busy: named/labelled controls whose
 * interactions mutate a single status element (so an input verb's effect can
 * be asserted against the real guest DOM rather than a `{ok:true}`), console
 * output at three levels including one that arrives late, and a sub-resource
 * plus a `fetch` so a request log has more than the document in it.
 */
export interface TestServer {
  /** Absolute URL for `path` (default `/page`). */
  url: (path?: string) => string
  close: () => Promise<void>
}

const FIXTURE_PAGE = `<!doctype html>
<html>
<head><title>Fixture</title></head>
<body>
  <h1>Hello from the fixture</h1>
  <p id="status" data-testid="status">idle</p>
  <button id="go" aria-label="Do the thing">Do the thing</button>
  <input id="name" aria-label="Your name" placeholder="Your name">
  <a id="link" href="/other">Go elsewhere</a>
  <select id="pick" aria-label="Pick one">
    <option value="one">One</option>
    <option value="two">Two</option>
  </select>
  <!-- Semantic-targeting cases: a name that prefixes a longer one (the
       ladder's exact tier must keep "Do the thing" unambiguous), a genuinely
       duplicated name (ambiguity must fail listing both), and a hidden
       duplicate (which must not count — display:none never matches). -->
  <button id="do-twice" aria-label="Do the thing twice">Do the thing twice</button>
  <button id="dup-a" aria-label="Duplicate">Duplicate</button>
  <button id="dup-b" aria-label="Duplicate">Duplicate</button>
  <button id="dup-hidden" aria-label="Duplicate" style="display: none">Duplicate</button>
  <!-- Non-semantic markup, mirroring a real production case: a click target
       that is a <div role="group">, not a <button>. role=button/name="Add to
       Cart" must miss (role stays a hard filter) but diagnose the near-miss
       by name alone; name="Add to Cart" with no role must reach and click it. -->
  <div id="cart-add" role="group" aria-label="Add to Cart" tabindex="0">Add to Cart</div>
  <!-- Verbatim-fill cases: a textarea with existing content form-input must
       replace with a multiline value intact, and a contenteditable with
       preset text for the editing-command path. Both start non-empty so a
       fill that appends instead of replacing is caught. -->
  <textarea id="notes" aria-label="Notes">stale draft</textarea>
  <div id="editor" contenteditable="true" aria-label="Editor">preset words</div>
  <div style="height: 3000px"></div>
  <script src="/script.js"></script>
  <script>
    const status = document.getElementById('status')
    const name = document.getElementById('name')
    document.getElementById('go').addEventListener('click', () => { status.textContent = 'clicked' })
    name.addEventListener('input', () => { status.textContent = 'typed:' + name.value })
    name.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') status.textContent = 'submitted:' + name.value
    })
    document.getElementById('pick').addEventListener('change', (event) => {
      status.textContent = 'picked:' + event.target.value
    })
    const notes = document.getElementById('notes')
    notes.addEventListener('input', () => { status.textContent = 'noted:' + notes.value.length })
    document.getElementById('do-twice').addEventListener('click', () => { status.textContent = 'twice-clicked' })
    document.getElementById('dup-a').addEventListener('click', () => { status.textContent = 'dup-a-clicked' })
    document.getElementById('dup-b').addEventListener('click', () => { status.textContent = 'dup-b-clicked' })
    document.getElementById('cart-add').addEventListener('click', () => { status.textContent = 'cart-added' })
    console.log('fixture ready')
    console.warn('a warning happened')
    console.error('an error happened')
    setTimeout(() => console.log('delayed message'), 300)
    fetch('/api/secret').then((response) => response.json()).catch(() => {})
  </script>
</body>
</html>`

/**
 * A page whose layout the click tests shift *after* taking a ref, driven
 * deterministically from the test via execute-js (a page-side setTimeout
 * would race the verb): growing `#lead` moves the target button, and
 * `#overlay` (a fixed full-viewport div) covers it. The buttons report which
 * one a click actually reached, so "landed on the right element" is asserted
 * against the guest DOM rather than the response alone.
 */
const SHIFTY_PAGE = `<!doctype html>
<html>
<head><title>Shifty</title></head>
<body>
  <p id="status" data-testid="status">idle</p>
  <div id="lead"></div>
  <button id="target" aria-label="Shifty target">Shifty target</button>
  <button id="decoy" aria-label="Decoy">Decoy</button>
  <script>
    const status = document.getElementById('status')
    document.getElementById('target').addEventListener('click', () => {
      status.textContent = 'target-clicked'
    })
    document.getElementById('decoy').addEventListener('click', () => {
      status.textContent = 'decoy-clicked'
    })
  </script>
</body>
</html>`

/**
 * A page for the wait-for tests. Deliberately inert on its own — every change
 * the tests wait on is driven *from the test* through execute-js (the same
 * determinism stance as SHIFTY_PAGE: page-side timers would race the verb),
 * via the helpers this page installs:
 *
 * - `window.appendReady(text)` adds a paragraph with the given text.
 * - `window.hideSpinner()` / `#spinner` — the --gone case.
 * - `window.revealPanel()` unhides `#panel`, whose selector must not match
 *   while it is display:none (visibility is part of the selector contract).
 * - `window.churn(ms)` mutates the DOM every 100ms for `ms` — the --idle
 *   case waits out the churn plus the quiet period.
 */
const WAITY_PAGE = `<!doctype html>
<html>
<head><title>Waity</title></head>
<body>
  <h1>Waity fixture</h1>
  <div id="spinner">spinner is spinning</div>
  <div id="panel" style="display: none">hidden panel</div>
  <div id="churn-target"></div>
  <script>
    window.appendReady = (text) => {
      const p = document.createElement('p')
      p.textContent = text
      document.body.appendChild(p)
      return true
    }
    window.hideSpinner = () => {
      document.getElementById('spinner').style.display = 'none'
      return true
    }
    window.revealPanel = () => {
      document.getElementById('panel').style.display = 'block'
      return true
    }
    window.churn = (ms) => {
      const target = document.getElementById('churn-target')
      const stopAt = Date.now() + ms
      const tick = () => {
        target.textContent = 'churn ' + Date.now()
        if (Date.now() < stopAt) setTimeout(tick, 100)
      }
      tick()
      return true
    }
  </script>
</body>
</html>`

/**
 * The frames/shadowRoots counting fixture, and the capability it exists to
 * pin: real input (`sendInputEvent`, dispatched by `click`) reaches inside an
 * `<iframe>` and an **open** shadow root even though the read verbs cannot
 * see either — `querySelectorAll`/`innerText` never descend into a frame or
 * a shadow tree, but `sendInputEvent` operates at the guest's compositor
 * level, the same as a real mouse, which routes into both.
 *
 * One iframe (same-origin, at NESTED_FRAME_PATH) and one open shadow host,
 * each holding a button that flips a `window` flag the test can read back —
 * the frame's button can't set a flag on the *top* document directly (it's a
 * different `window`), so it goes through `postMessage`; the shadow button is
 * still the top document's own `window` and sets the flag directly.
 */
const NESTED_FRAME_PATH = '/nested-frame'

const NESTED_PAGE = `<!doctype html>
<html>
<head><title>Nested content</title></head>
<body>
  <h1>Nested content fixture</h1>
  <button id="top-button">Top button</button>
  <iframe id="the-frame" title="the frame" src="${NESTED_FRAME_PATH}" style="width:300px;height:150px;border:1px solid #000"></iframe>
  <div id="shadow-host"></div>
  <script>
    window.frameButtonClicked = false
    window.addEventListener('message', (event) => {
      if (event.data === 'frame-button-clicked') window.frameButtonClicked = true
    })
    window.shadowButtonClicked = false
    const host = document.getElementById('shadow-host')
    const root = host.attachShadow({ mode: 'open' })
    const btn = document.createElement('button')
    btn.id = 'shadow-button'
    btn.textContent = 'Shadow button'
    btn.addEventListener('click', () => { window.shadowButtonClicked = true })
    root.appendChild(btn)
  </script>
</body>
</html>`

const NESTED_FRAME_PAGE = `<!doctype html>
<html>
<head><title>Inner frame</title></head>
<body>
  <button id="frame-button" onclick="parent.postMessage('frame-button-clicked', '*')">Frame button</button>
</body>
</html>`

/**
 * A deterministic binary asset the save-resource tests fetch and compare byte
 * for byte. It opens with the PNG signature so extension inference lands on
 * `.png` for the element-src case, and is served both directly (`/asset.png`)
 * and, wrapped in a `blob:` under a strict CSP, by BLOB_PAGE below.
 */
export const FIXTURE_ASSET_BYTES = (() => {
  const head = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
  const body = Array.from({ length: 512 }, (_, i) => i % 256)
  return Buffer.from([...head, ...body])
})()

/**
 * The reported incident's shape: a resource shown in an iframe via a `blob:`
 * URL, behind a `connect-src 'self'` CSP that blocks any in-page fetch of that
 * blob — the exact wall save-resource's CDP route is the only thing that beats.
 * A same-origin `<img>` and a download `<a>` give the element-src route (by
 * `--selector` and by a read-page `--ref`) something http to resolve. Every
 * resource here is the same FIXTURE_ASSET_BYTES, so one expected value checks
 * all three routes.
 */
const BLOB_PAGE = `<!doctype html>
<html>
<head><title>Blob holder</title></head>
<body>
  <h1>Blob holder</h1>
  <iframe id="viewer" title="viewer"></iframe>
  <img id="pic" src="/asset.png" alt="pic">
  <a id="dl" href="/asset.png">download</a>
  <script>
    window.__blobReady = false
    fetch('/asset.png').then((r) => r.blob()).then((b) => {
      const url = URL.createObjectURL(new Blob([b], { type: 'application/pdf' }))
      document.getElementById('viewer').src = url
      window.__blobUrl = url
      window.__blobReady = true
    }).catch((e) => { window.__blobReady = 'error:' + e.message })
  </script>
</body>
</html>`

/**
 * The shape read-page's narrowing exists for, reproduced deterministically:
 * far more filter checkboxes than the 200-element cap, with the one control
 * that actually matters (`#sort`, a `<select>`) sitting *after* them in
 * document order. A bare read therefore spends its whole budget on checkboxes
 * and never reaches the select — which is exactly the reported failure — while
 * `--role combobox` reaches it in one call.
 *
 * The images are here for the other half of the same ticket: `<img>` is not in
 * read-page's default candidate set, so these are invisible to a bare read and
 * reachable only through `--selector`.
 */
const LISTING_PAGE = `<!doctype html>
<html>
<head><title>Listing</title></head>
<body>
  <h1>Listing fixture</h1>
  ${Array.from(
    { length: 240 },
    (_, i) =>
      `<label for="brand${i}">Brand ${i}</label><input type="checkbox" id="brand${i}" aria-label="Brand ${i}">`
  ).join('\n  ')}
  <select id="sort" aria-label="Sort by">
    <option value="rank">Rank</option>
    <option value="price">Price</option>
  </select>
  <img id="hero" src="/asset.png" alt="Hero image">
  <img id="thumb" src="/asset.png" alt="Thumb image">
</body>
</html>`

/**
 * A page whose own CSS opts into smooth scrolling — the condition under which
 * `window.scrollBy(x, y)` animates and an immediate `window.scrollY` read
 * reports where the page *was*. Measured in plain Chromium before the fix:
 * immediate `{y: 0}` for a scroll that settled at `{y: 800}`.
 */
const SMOOTH_PAGE = `<!doctype html>
<html>
<head><title>Smooth</title><style>html { scroll-behavior: smooth; }</style></head>
<body>
  <h1>Smooth fixture</h1>
  <div style="height: 5000px">tall</div>
</body>
</html>`

/**
 * A menu that opens on hover and navigates on click — the pattern `hover`
 * exists for, and one `click` cannot reach without committing the press. The
 * submenu is `display: none` until `mouseenter`, so read-page genuinely cannot
 * see it beforehand (its visibility predicate excludes display:none).
 */
const HOVERY_PAGE = `<!doctype html>
<html>
<head><title>Hovery</title></head>
<body>
  <p id="status" data-testid="status">idle</p>
  <div id="menu" style="width:200px">
    <span id="menu-label" aria-label="Products" tabindex="0">Products</span>
    <div id="submenu" style="display:none">
      <a id="sub-widgets" href="/other">Widgets</a>
    </div>
  </div>
  <script>
    const menu = document.getElementById('menu')
    const submenu = document.getElementById('submenu')
    const status = document.getElementById('status')
    menu.addEventListener('mouseenter', () => {
      submenu.style.display = 'block'
      status.textContent = 'menu-open'
    })
    document.getElementById('menu-label').addEventListener('click', () => {
      status.textContent = 'label-clicked'
    })
  </script>
</body>
</html>`

/**
 * Every fixture that is just "200, text/html, this string" — a table rather
 * than a branch each, so adding a page is one entry instead of four lines of
 * identical plumbing in a route chain where the path→constant pair is the only
 * real information. Routes needing their own status, headers or timing
 * (/slow, /missing, /redirect, /asset.png, /blobpage, …) stay branches below,
 * and the ones declared before this lookup still win.
 */
const STATIC_PAGES: Record<string, string> = {
  '/other':
    '<!doctype html><html><head><title>Elsewhere</title></head><body>Elsewhere</body></html>',
  '/shifty': SHIFTY_PAGE,
  '/listing': LISTING_PAGE,
  '/smooth': SMOOTH_PAGE,
  '/hovery': HOVERY_PAGE,
  '/waity': WAITY_PAGE,
  '/nested': NESTED_PAGE,
  [NESTED_FRAME_PATH]: NESTED_FRAME_PAGE
}

/**
 * Long enough for a test to reliably probe main mid-load (well past a
 * localhost IPC round trip), short enough that a test awaiting the eventual
 * response isn't stuck for anywhere near LOAD_WAIT_MS.
 */
const SLOW_RESPONSE_MS = 1000

export function startTestServer(): Promise<TestServer> {
  // Which /bounce-once/<token> paths have already served their one redirect —
  // per-server state, so a fresh server (one per spec file) starts clean.
  const bouncedPaths = new Set<string>()
  const server: Server = createServer((request, response) => {
    const path = (request.url ?? '/').split('?')[0]!
    if (path === '/slow') {
      // Delays the response so the guest stays "loading" for a bounded
      // window — what gives a test time to probe main's ownership ledger
      // while create-browser-pane's own relay (which waits for the load to
      // settle) is still pending, without waiting anywhere near the full
      // LOAD_WAIT_MS for it to resolve.
      setTimeout(() => {
        response.writeHead(200, { 'content-type': 'text/html' })
        response.end('<!doctype html><html><body>Eventually loaded</body></html>')
      }, SLOW_RESPONSE_MS)
      return
    }
    if (path === '/script.js') {
      response.writeHead(200, { 'content-type': 'text/javascript' })
      response.end('window.__fixtureScriptLoaded = true')
      return
    }
    if (path === '/api/secret') {
      // Headers the redaction pass must strip by default — see the
      // `unredacted` flag on readNetworkRequests.
      response.writeHead(200, {
        'content-type': 'application/json',
        'set-cookie': 'session=super-secret-value; Path=/',
        'x-fixture-header': 'fixture-value'
      })
      response.end(JSON.stringify({ ok: true }))
      return
    }
    if (path === '/api/big') {
      // A JSON body comfortably past NETWORK_BODY_MAX (16,384 chars), for the
      // explicit-truncation assertion on read-network --with-bodies.
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ filler: 'x'.repeat(20000) }))
      return
    }
    if (path === '/bigtext') {
      // A document whose innerText alone is far past the ~64KB kernel pipe
      // buffer — the pin for tabs-ctl draining stdout before exiting (a hard
      // process.exit() used to drop everything past 65536 bytes whenever
      // stdout was a pipe, which is how every real caller runs it). The end
      // marker is what proves the far end of the response arrived.
      response.writeHead(200, { 'content-type': 'text/html' })
      response.end(
        `<!doctype html><html><head><title>Big</title></head><body><p>${'x'.repeat(120000)}</p><p>END-OF-BIGTEXT</p></body></html>`
      )
      return
    }
    if (path === '/missing') {
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('nope')
      return
    }
    const staticPage = STATIC_PAGES[path]
    if (staticPage !== undefined) {
      response.writeHead(200, { 'content-type': 'text/html' })
      response.end(staticPage)
      return
    }
    if (path === '/asset.png') {
      response.writeHead(200, { 'content-type': 'image/png' })
      response.end(FIXTURE_ASSET_BYTES)
      return
    }
    if (path === '/blobpage') {
      // The strict CSP is the whole point: connect-src 'self' blocks an in-page
      // fetch of the blob, so a passing save-resource here proves the CDP route
      // rather than an in-page fetch that a laxer page would let slip.
      response.writeHead(200, {
        'content-type': 'text/html',
        'content-security-policy':
          "default-src 'self'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-src blob:; img-src 'self'"
      })
      response.end(BLOB_PAGE)
      return
    }
    if (path === '/redirect') {
      // A plain server redirect: what navigate's final-URL reporting exists
      // to make visible. Relative Location on purpose — Chromium resolves it,
      // and the reported URL must come back absolute regardless.
      response.writeHead(302, { location: '/other' })
      response.end()
      return
    }
    if (path === '/late-title') {
      // The SPA shape behind navigate's titleFromUrl flag: no <title> in the
      // HTML, the real one set by script well after the load settles. The
      // delay is generous so the verb reliably answers first even under a
      // contended parallel run; a test that wants the late title polls
      // pane-info for it.
      response.writeHead(200, { 'content-type': 'text/html' })
      response.end(
        '<!doctype html><html><body>Untitled at first<script>setTimeout(() => { document.title = "Set later" }, 1000)</script></body></html>'
      )
      return
    }
    if (path.startsWith('/bounce-once/')) {
      // An auth-bounce stand-in for --retry-on-redirect: the *first* request
      // for a given /bounce-once/<token> path redirects away (the hit that
      // "establishes the session"), every later one serves the page. Keyed by
      // full path because the server is shared across a spec file — each test
      // mints a fresh token rather than resetting shared state.
      if (!bouncedPaths.has(path)) {
        bouncedPaths.add(path)
        response.writeHead(302, { location: '/other' })
        response.end()
        return
      }
      response.writeHead(200, { 'content-type': 'text/html' })
      response.end(
        '<!doctype html><html><head><title>Deep link</title></head><body>Deep link content</body></html>'
      )
      return
    }
    response.writeHead(200, { 'content-type': 'text/html' })
    response.end(FIXTURE_PAGE)
  })

  return new Promise((resolve) => {
    // Port 0 + 127.0.0.1: an ephemeral port avoids collisions between the
    // several workers playwright.config.ts runs at once, and the loopback
    // bind keeps this off the network entirely.
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo
      resolve({
        url: (path = '/page') => `http://127.0.0.1:${port}${path}`,
        close: () =>
          new Promise<void>((done) => {
            server.closeAllConnections()
            server.close(() => done())
          })
      })
    })
  })
}

/**
 * One fixture origin for a whole spec file: registers the beforeAll/afterAll
 * pair and hands back a `url` that follows the live server, so every
 * external-control-*.spec.ts declares the lifecycle in one line rather than
 * carrying its own copy of it. Called at a spec's module scope, like the
 * hooks it wraps.
 */
export function testServerForSpec(): Pick<TestServer, 'url'> {
  let server: TestServer | undefined
  test.beforeAll(async () => {
    server = await startTestServer()
  })
  test.afterAll(async () => {
    await server?.close()
  })
  return {
    url: (path) => {
      if (!server) throw new Error('testServerForSpec: the fixture server only runs inside a test')
      return server.url(path)
    }
  }
}
