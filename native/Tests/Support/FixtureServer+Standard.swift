import Foundation

/// The pages of the Electron external-control tests' fixture origin (`e2e/helpers/testServer.ts`), served
/// by a `FixtureServer`: one busy page, and one page per behaviour a verb is measured against. Bodies are
/// the Electron server's, verbatim (HTML, script and CSS are engine-neutral); the routes keep its paths.
///
/// ```swift
/// let server = try await FixtureServer.startStandard()
/// try await page.load(server.url("/page"))
/// ```
///
/// Routes: `/page` (the busy fixture, title "Fixture"; the Electron server's default path, so `/` and every
/// path nothing else claims answer it too), `/other` ("Elsewhere"), `/shifty`, `/waity`, `/nested` and
/// `/nested-frame`, `/listing`, `/smooth`, `/hovery`, `/form`, `/controls`, `/blobpage` (strict CSP),
/// `/asset.png` (`Standard.assetBytes`), `/script.js`, `/api/secret`, `/api/big`, `/slow`
/// (`Standard.slowResponseDelay`), `/bigtext` (`Standard.bigTextSize` characters, then an end marker),
/// `/missing` (404), `/redirect` (302 to `/other`), `/late-title` (a title set by script a second after the
/// load) and `/bounce-once/<token>` (redirects the first request per token, serves "Deep link" after).
extension FixtureServer {
    /// A server with every standard page installed.
    static func startStandard() async throws -> FixtureServer {
        let server = try await start()
        server.installStandardPages()
        return server
    }

    /// An origin that refuses connections (`deadOrigin()` of `e2e/helpers/agentSession.ts`): a port briefly owned and
    /// closed again, as `http://127.0.0.1:<port>/`. Not a fixed low port: an engine may refuse its unsafe ports before
    /// ever dialing, which is a different failure than the connection refused a down dev server gives.
    static func deadOrigin() async throws -> String {
        "http://127.0.0.1:\(try await closedPort())/"
    }

    /// `data:text/html,` and the percent-encoded page (`encodeURIComponent`'s alphabet): the hermetic page
    /// `e2e/helpers/browser.ts`'s `dataPage` gives a guest that needs no origin.
    static func dataPage(_ title: String, _ bodyHTML: String = "") -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let html = "<title>\(title)</title>\(bodyHTML)"
        return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: unreserved) ?? html)
    }

    /// Every route of the Electron test server, on this server. A later call replaces an earlier one's routes.
    func installStandardPages() {
        // Every fixture that is just "200, text/html, this string" is one entry; routes needing their own
        // status, headers or timing are below.
        let pages: [String: String] = [
            "/other": "<!doctype html><html><head><title>Elsewhere</title></head><body>Elsewhere</body></html>",
            "/shifty": Standard.shiftyPage,
            "/listing": Standard.listingPage,
            "/smooth": Standard.smoothPage,
            "/hovery": Standard.hoveryPage,
            "/form": Standard.formPage,
            "/controls": Standard.controlsPage,
            "/waity": Standard.waityPage,
            "/nested": Standard.nestedPage,
            Standard.nestedFramePath: Standard.nestedFramePage,
            "/page": Standard.fixturePage,
            // A text field inside a frame, where the page's input counters (main frame only) can't see the keys.
            "/framed-field": #"""
            <!doctype html><html><head><title>Framed field</title><style>body{margin:0}</style></head><body>
            <iframe id="fr" style="position:absolute;left:0;top:0;width:300px;height:60px;border:0"
              srcdoc="<style>body{margin:0}</style><input id='f' style='width:250px;height:30px'>"></iframe>
            </body></html>
            """#,
        ]
        for (path, html) in pages { route(path, Response(body: html)) }

        // Delays the response so the guest stays "loading" for a bounded window: what gives a test time to
        // probe the app's ownership ledger while create-browser-pane's own wait for the load to settle is
        // still pending, without waiting anywhere near the full load wait for it to resolve.
        route("/slow", Response(body: "<!doctype html><html><body>Eventually loaded</body></html>", delay: Standard.slowResponseDelay))
        route("/script.js", Response(contentType: "text/javascript", body: "window.__fixtureScriptLoaded = true"))
        // Headers the redaction pass must strip by default (`read-network`'s `unredacted` flag).
        route(
            "/api/secret",
            Response(
                contentType: "application/json",
                headers: ["Set-Cookie": "session=super-secret-value; Path=/", "X-Fixture-Header": "fixture-value"],
                body: #"{"ok":true}"#))
        // A JSON body comfortably past the network body cap (16,384 chars), for the explicit-truncation assertion.
        route("/api/big", Response(contentType: "application/json", body: #"{"filler":"\#(String(repeating: "x", count: 20000))"}"#))
        // A document whose innerText alone is far past the ~64KB kernel pipe buffer: the pin for tabs-ctl
        // draining stdout before exiting (a hard process.exit() used to drop everything past 65536 bytes
        // whenever stdout was a pipe, which is how every real caller runs it). The end marker is what proves
        // the far end of the response arrived.
        let filler = String(repeating: "x", count: Standard.bigTextSize)
        route(
            "/bigtext",
            Response(body: "<!doctype html><html><head><title>Big</title></head><body><p>\(filler)</p><p>END-OF-BIGTEXT</p></body></html>"))
        route("/missing", Response(status: 404, contentType: "text/plain", body: "nope"))
        route("/asset.png", Response(status: 200, contentType: "image/png", data: Standard.assetBytes))
        // The strict CSP is the whole point: connect-src 'self' blocks an in-page fetch of the blob, so a
        // passing save-resource here proves the CDP route rather than an in-page fetch that a laxer page
        // would let slip.
        route(
            "/blobpage",
            Response(
                headers: [
                    "Content-Security-Policy":
                        "default-src 'self'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-src blob:; img-src 'self'"
                ], body: Standard.blobPage))
        // A plain server redirect: what navigate's final-URL reporting exists to make visible. Relative
        // Location on purpose: the engine resolves it, and the reported URL must come back absolute regardless.
        route("/redirect", Response.redirect(to: "/other"))
        // Pages that send themselves elsewhere from script while they load, the way a client-side auth bounce does:
        // during parse, and from the load event.
        route("/js-redirect", Response(body: #"<!doctype html><title>R</title><script>location.replace("/other")</script>"#))
        route(
            "/onload-redirect",
            Response(body: #"<!doctype html><title>R</title><script>onload = () => { location.href = "/other" }</script>"#))
        // The SPA shape behind navigate's titleFromUrl flag: no <title> in the HTML, the real one set by
        // script well after the load settles. The delay is generous so the verb reliably answers first even
        // under a contended parallel run; a test that wants the late title polls pane-info for it.
        route(
            "/late-title",
            Response(
                body:
                    #"<!doctype html><html><body>Untitled at first<script>setTimeout(() => { document.title = "Set later" }, 1000)</script></body></html>"#
            ))

        // An auth-bounce stand-in for --retry-on-redirect: the *first* request for a given
        // /bounce-once/<token> path redirects away (the hit that "establishes the session"), every later
        // one serves the page. Keyed by full path because the server is shared across a spec file: each
        // test mints a fresh token rather than resetting shared state.
        let bounced = BouncedPaths()
        // Anything else is the fixture page, as on the Electron server (`/`, `/whatever?x=1`).
        fallback { request in
            if request.path.hasPrefix("/bounce-once/") {
                if bounced.first(request.path) { return .redirect(to: "/other") }
                return Response(body: "<!doctype html><html><head><title>Deep link</title></head><body>Deep link content</body></html>")
            }
            return Response(body: Standard.fixturePage)
        }
    }

    /// Which `/bounce-once/<token>` paths have already served their one redirect: per-server state, so a
    /// fresh server starts clean.
    private final class BouncedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<String>()
        /// True the first time `path` is asked about.
        func first(_ path: String) -> Bool { lock.withLock { seen.insert(path).inserted } }
    }

    /// The page bodies and the numbers tests assert against.
    enum Standard {
        static let nestedFramePath = "/nested-frame"
        /// Long enough for a test to reliably probe the app mid-load (well past a localhost round trip),
        /// short enough that a test awaiting the eventual response isn't stuck for anywhere near the load wait.
        static let slowResponseDelay = Duration.milliseconds(1000)
        /// How many `x` characters `/bigtext` holds before its end marker.
        static let bigTextSize = 120_000

        /// The fixture page is deliberately busy: named/labelled controls whose
        /// interactions mutate a single status element (so an input verb's effect can
        /// be asserted against the real guest DOM rather than a `{ok:true}`), console
        /// output at three levels including one that arrives late, and a sub-resource
        /// plus a `fetch` so a request log has more than the document in it.
        static let fixturePage = """
            <!doctype html>
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
            </html>
            """

        /// A page whose layout the click tests shift *after* taking a ref, driven
        /// deterministically from the test via execute-js (a page-side setTimeout
        /// would race the verb): growing `#lead` moves the target button, and
        /// `#overlay` (a fixed full-viewport div) covers it. The buttons report which
        /// one a click actually reached, so "landed on the right element" is asserted
        /// against the guest DOM rather than the response alone.
        static let shiftyPage = """
            <!doctype html>
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
            </html>
            """

        /// A page for the wait-for tests. Deliberately inert on its own — every change
        /// the tests wait on is driven *from the test* through execute-js (the same
        /// determinism stance as SHIFTY_PAGE: page-side timers would race the verb),
        /// via the helpers this page installs:
        ///
        /// - `window.appendReady(text)` adds a paragraph with the given text.
        /// - `window.hideSpinner()` / `#spinner` — the --gone case.
        /// - `window.revealPanel()` unhides `#panel`, whose selector must not match
        ///   while it is display:none (visibility is part of the selector contract).
        /// - `window.churn(ms)` mutates the DOM every 100ms for `ms` — the --idle
        ///   case waits out the churn plus the quiet period.
        static let waityPage = """
            <!doctype html>
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
            </html>
            """

        /// The frames/shadowRoots counting fixture, and the capability it exists to
        /// pin: real input (`sendInputEvent`, dispatched by `click`) reaches inside an
        /// `<iframe>` and an **open** shadow root even though the read verbs cannot
        /// see either — `querySelectorAll`/`innerText` never descend into a frame or
        /// a shadow tree, but `sendInputEvent` operates at the guest's compositor
        /// level, the same as a real mouse, which routes into both.
        ///
        /// One iframe (same-origin, at NESTED_FRAME_PATH) and one open shadow host,
        /// each holding a button that flips a `window` flag the test can read back —
        /// the frame's button can't set a flag on the *top* document directly (it's a
        /// different `window`), so it goes through `postMessage`; the shadow button is
        /// still the top document's own `window` and sets the flag directly.
        static let nestedPage = """
            <!doctype html>
            <html>
            <head><title>Nested content</title></head>
            <body>
              <h1>Nested content fixture</h1>
              <button id="top-button">Top button</button>
              <iframe id="the-frame" title="the frame" src="\(nestedFramePath)" style="width:300px;height:150px;border:1px solid #000"></iframe>
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
            </html>
            """

        static let nestedFramePage = """
            <!doctype html>
            <html>
            <head><title>Inner frame</title></head>
            <body>
              <button id="frame-button" onclick="parent.postMessage('frame-button-clicked', '*')">Frame button</button>
            </body>
            </html>
            """

        /// A deterministic binary asset the save-resource tests fetch and compare byte
        /// for byte. It opens with the PNG signature so extension inference lands on
        /// `.png` for the element-src case, and is served both directly (`/asset.png`)
        /// and, wrapped in a `blob:` under a strict CSP, by BLOB_PAGE below.
        static let assetBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + (0..<512).map { UInt8($0 % 256) })

        /// The reported incident's shape: a resource shown in an iframe via a `blob:`
        /// URL, behind a `connect-src 'self'` CSP that blocks any in-page fetch of that
        /// blob — the exact wall save-resource's CDP route is the only thing that beats.
        /// A same-origin `<img>` and a download `<a>` give the element-src route (by
        /// `--selector` and by a read-page `--ref`) something http to resolve. Every
        /// resource here is the same FIXTURE_ASSET_BYTES, so one expected value checks
        /// all three routes.
        static let blobPage = """
            <!doctype html>
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
            </html>
            """

        /// The shape read-page's narrowing exists for, reproduced deterministically:
        /// far more filter checkboxes than the 200-element cap, with the one control
        /// that actually matters (`#sort`, a `<select>`) sitting *after* them in
        /// document order. A bare read therefore spends its whole budget on checkboxes
        /// and never reaches the select — which is exactly the reported failure — while
        /// `--role combobox` reaches it in one call.
        ///
        /// The images are here for the other half of the same ticket: `<img>` is not in
        /// read-page's default candidate set, so these are invisible to a bare read and
        /// reachable only through `--selector`, or a `--role` only an image has (`img`, and
        /// `presentation` for the decorative one).
        static let listingPage: String = {
            let brands = (0..<240).map { i in
                #"<label for="brand\#(i)">Brand \#(i)</label><input type="checkbox" id="brand\#(i)" aria-label="Brand \#(i)">"#
            }.joined(separator: "\n  ")
            return """
                <!doctype html>
                <html>
                <head><title>Listing</title></head>
                <body>
                  <h1>Listing fixture</h1>
                  \(brands)
                  <select id="sort" aria-label="Sort by">
                    <option value="rank">Rank</option>
                    <option value="price">Price</option>
                  </select>
                  <img id="hero" src="/asset.png" alt="Hero image">
                  <img id="thumb" src="/asset.png" alt="Thumb image">
                  <img id="divider" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='4'/%3E" alt="" width="40" height="4">
                </body>
                </html>
                """
        }()

        /// A page whose own CSS opts into smooth scrolling — the condition under which
        /// `window.scrollBy(x, y)` animates and an immediate `window.scrollY` read
        /// reports where the page *was*. Measured in plain Chromium before the fix:
        /// immediate `{y: 0}` for a scroll that settled at `{y: 800}`.
        static let smoothPage = """
            <!doctype html>
            <html>
            <head><title>Smooth</title><style>html { scroll-behavior: smooth; }</style></head>
            <body>
              <h1>Smooth fixture</h1>
              <div style="height: 5000px">tall</div>
            </body>
            </html>
            """

        /// A menu that opens on hover and navigates on click — the pattern `hover`
        /// exists for, and one `click` cannot reach without committing the press. The
        /// submenu is `display: none` until `mouseenter`, so read-page genuinely cannot
        /// see it beforehand (its visibility predicate excludes display:none).
        static let hoveryPage = """
            <!doctype html>
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
            </html>
            """

        /// A plain form, the case `type --submit` and `key --key Enter` exist for: a
        /// text field inside a `<form>` with a submit button and an `onsubmit`
        /// handler, which Chromium submits implicitly from Enter's *keypress*. Every
        /// keyboard event the page sees is logged in order (`window.__keys`, one
        /// `[type, key, code, shiftKey]` tuple each) and every submit counted
        /// (`window.__submits`), so a test can assert exactly what a keystroke
        /// produced rather than only its end state. The submit handler prevents the
        /// navigation, so the counts survive it.
        static let formPage = """
            <!doctype html>
            <html>
            <head><title>Form</title></head>
            <body>
              <form id="form" onsubmit="event.preventDefault(); window.__submits++">
                <input id="query" aria-label="Query">
                <button>Go</button>
              </form>
              <textarea id="notes" aria-label="Notes"></textarea>
              <script>
                window.__submits = 0
                window.__keys = []
                for (const type of ['keydown', 'keypress', 'keyup']) {
                  document.addEventListener(type, (event) => {
                    window.__keys.push([event.type, event.key, event.code, event.shiftKey])
                  }, true)
                }
              </script>
            </body>
            </html>
            """

        /// Labelled and checkable controls, for how read-page names and describes
        /// them: a select wrapped in its label (whose text used to be every option
        /// run together), an unlabelled select, a label holding two controls, and
        /// checkboxes/radios/a switch in every state `checked` reports. The
        /// indeterminate checkbox can only be set from script, so the page does it.
        static let controlsPage = """
            <!doctype html>
            <html>
            <head><title>Controls</title></head>
            <body>
              <label>Colour <select id="colour"><option value="r">Red</option><option value="g">Green</option><option value="b">Blue</option></select></label>
              <select id="bare"><option>Alpha</option><option selected>Beta</option></select>
              <label>Qty <input id="qty" value="3"> of <select id="unit"><option>kg</option></select></label>
              <label><input type="checkbox" id="agree"> Agree</label>
              <label><input type="checkbox" id="subscribed" checked> Subscribed</label>
              <label><input type="checkbox" id="some"> Some</label>
              <label><input type="radio" name="size" id="small" value="s" checked> Small</label>
              <div role="switch" id="wifi" aria-checked="true" aria-label="Wi-Fi" tabindex="0">on</div>
              <script>document.getElementById('some').indeterminate = true</script>
            </body>
            </html>
            """
    }
}
