import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// `save-resource` as an agent drives it (docs/BROWSER.md J-22, J-24, J-26, J-27, F-7), against the real
/// plugin in a real core runtime and the standard fixture pages. Ports of `e2e/external-control-read.spec.ts`:
/// "save-resource gets bytes out of a page: a blob behind a strict CSP, and element srcs", "save-resource reads
/// a blob the page only minted — the about:blank cases…", and the ownership half of "read-back verbs refuse a
/// pane this caller does not own" and "capture verbs refuse a pane this caller does not own".
@MainActor
@Suite struct BrowserResourceVerbTests {
    static let asset = FixtureServer.Standard.assetBytes

    private func bytes(_ path: String?) throws -> Data { try Data(contentsOf: URL(filePath: try #require(path))) }

    /// Waits until the blob page has minted its blob and pointed the iframe at it.
    private func blobReady(_ bed: ScriptVerbBed) async throws -> String {
        for _ in 0..<100 where await bed.value("window.__blobReady") != true { try await Task.sleep(for: .milliseconds(50)) }
        return try #require(await bed.value("window.__blobUrl").stringValue)
    }

    /// J-22: the premise the verb exists for: `connect-src 'self'` blocks an in-page fetch of the blob, so its
    /// bytes are genuinely unreachable from `execute-js`; then a blob by `--url --out`, an element `src` by
    /// `--selector` (a generated path, its extension typed to png), the same asset by `--ref`, `--out` never
    /// clobbering, and `file:` refused on the front door.
    @Test func saveResourceGetsBytesOutOfAPageABlobBehindAStrictCSPAndElementSrcs() async throws {
        let bed = try await ScriptVerbBed.open("/blobpage")
        let blobURL = try await blobReady(bed)

        let inPage = await bed.ctl("execute-js", ["code": "fetch(window.__blobUrl).then(() => 'reached', (e) => 'blocked:' + e.name)"])
        #expect(inPage.result["value"]?.stringValue?.contains("blocked") == true)

        let directory = try bed.scratchDirectory()

        // 1) blob: via --url --out.
        let blobOut = directory.appending(path: "doc.pdf").path
        let savedBlob = await bed.ctl("save-resource", ["url": .string(blobURL), "out": .string(blobOut)])
        #expect(savedBlob.ok, "\(savedBlob.json)")
        #expect(savedBlob.result["path"] == .string(blobOut))
        #expect(savedBlob.result["bytes"] == .int(Int64(Self.asset.count)))
        #expect(savedBlob.result["contentType"] == "application/pdf")
        #expect(try bytes(blobOut) == Self.asset)

        // 2) an http element src by --selector: a generated path whose extension is typed to png.
        let savedImage = await bed.ctl("save-resource", ["selector": "img#pic"])
        #expect(savedImage.ok, "\(savedImage.json)")
        #expect(savedImage.result["contentType"] == "image/png")
        let generated = try #require(savedImage.result["path"]?.stringValue)
        #expect(generated.hasSuffix(".png") && generated.contains("agent-resources") && generated.hasPrefix(bed.cacheDirectory.path))
        #expect(try bytes(generated) == Self.asset)

        // 3) the same asset by --ref: read-page returns the download link, whose href resolves to it.
        let structure = await bed.value(readPageScript(ReadPageFilter(role: "link")))
        let ref = try #require(structure["elements"]?[0]?["ref"]?.stringValue)
        let refOut = directory.appending(path: "via-ref.bin").path
        let savedRef = await bed.ctl("save-resource", ["ref": .string(ref), "out": .string(refOut)])
        #expect(savedRef.ok, "\(savedRef.json)")
        #expect(try bytes(refOut) == Self.asset)

        // --out never clobbers.
        let clobber = await bed.ctl("save-resource", ["url": .string(blobURL), "out": .string(blobOut)])
        #expect(!clobber.ok)
        #expect(clobber.error == "refusing to overwrite an existing file: \(blobOut)")

        // file: is refused on the front door: the load-bearing overlap with the http(s) route.
        let refusedFile = await bed.ctl("save-resource", ["url": "file:///etc/hosts"])
        #expect(!refusedFile.ok)
        #expect(refusedFile.error == "url not allowed: file:///etc/hosts (save-resource reads http, https, blob and data URLs)")

        // Deviation, measured: the combination Electron cannot reach (a blob never loaded, on a page whose CSP
        // forbids blob fetches) is read here, since the read inside the page's other world is not held to the page's CSP.
        let unloaded = await bed.ctl(
            "execute-js", ["code": "(window.__unloaded = URL.createObjectURL(new Blob(['x'])), window.__unloaded)"])
        let reached = await bed.ctl("save-resource", ["url": unloaded.result["value"] ?? .null])
        #expect(reached.ok, "\(reached.json)")
        #expect(try bytes(reached.result["path"]?.stringValue) == Data("x".utf8))
    }

    /// J-22: a blob the page only minted, on `about:blank` (`blob:null/…`): saved by URL with its own type for the
    /// name, then the same blob as an iframe's src by `--selector` (generated name, extension from the blob's type).
    @Test func saveResourceReadsABlobThePageOnlyMintedTheAboutBlankCases() async throws {
        let bed = try await ScriptVerbBed.open()
        let expected = Data((0..<600).map { UInt8(($0 * 7 + 3) % 256) })
        let minted = await bed.ctl(
            "execute-js",
            [
                "code":
                    "(() => { window.__u = URL.createObjectURL(new Blob([Uint8Array.from({ length: 600 }, (_, i) => (i * 7 + 3) % 256)], { type: 'application/pdf' })); return window.__u })()"
            ])
        let blobURL = try #require(minted.result["value"]?.stringValue)
        #expect(blobURL.hasPrefix("blob:"))

        let out = try bed.scratchDirectory().appending(path: "minted.pdf").path
        let saved = await bed.ctl("save-resource", ["url": .string(blobURL), "out": .string(out)])
        #expect(saved.ok, "\(saved.json)")
        #expect(saved.result["bytes"] == .int(Int64(expected.count)))
        #expect(saved.result["contentType"] == "application/pdf")
        #expect(try bytes(out) == expected)

        _ = await bed.ctl(
            "execute-js",
            [
                "code":
                    "(() => { const f = document.createElement('iframe'); f.id = 'fr'; f.src = window.__u; document.body.appendChild(f); return true })()"
            ])
        let savedFrame = await bed.ctl("save-resource", ["selector": "#fr"])
        #expect(savedFrame.ok, "\(savedFrame.json)")
        #expect(savedFrame.result["path"]?.stringValue?.hasSuffix(".pdf") == true)
        #expect(try bytes(savedFrame.result["path"]?.stringValue) == expected)
    }

    /// J-22: `data:` decoded in the app, the extension from its mediatype, and the answer `{path, bytes, contentType}`.
    @Test func aDataURLIsSavedWithItsOwnTypeForTheName() async throws {
        let bed = try await ScriptVerbBed.open()
        let saved = await bed.ctl("save-resource", ["url": "data:text/csv;base64,YSxiCjEsMg=="])
        #expect(saved.ok, "\(saved.json)")
        #expect(saved.result["contentType"] == "text/csv" && saved.result["bytes"] == 7)
        #expect(saved.result["path"]?.stringValue?.hasSuffix(".csv") == true)
        #expect(String(decoding: try bytes(saved.result["path"]?.stringValue), as: UTF8.self) == "a,b\n1,2")
        // No type: the answer has no contentType, and the name falls back on the bytes.
        let untyped = await bed.ctl("save-resource", ["url": "data:;base64,iVBORw0KGgo="])
        #expect(untyped.result["contentType"] == nil && untyped.result["path"]?.stringValue?.hasSuffix(".png") == true)
    }

    /// J-22: exactly one of `--url`, `--ref`, `--selector`, said in the caller's words.
    @Test func saveResourceTakesExactlyOneSource() async throws {
        let bed = try await ScriptVerbBed.open("/blobpage")
        let two = await bed.ctl("save-resource", ["url": "data:,x", "selector": "img"])
        #expect(two.error == "save-resource takes exactly one of --url, --ref or --selector — got --url and --selector")
        let three = await bed.ctl("save-resource", ["url": "data:,x", "ref": "e1-aaaaa", "selector": "img"])
        #expect(three.error == "save-resource takes exactly one of --url, --ref or --selector — got --url and --ref and --selector")
        let none = await bed.ctl("save-resource")
        #expect(none.error == "save-resource needs one of --url, --ref or --selector")
        let empty = await bed.ctl("save-resource", ["url": ""])
        #expect(empty.error == "save-resource needs one of --url, --ref or --selector", "an empty URL names nothing")
        let missing = await bed.ctl("save-resource", ["selector": "#nothing"])
        #expect(missing.error == "no element matches selector \"#nothing\"")
        let stale = await bed.ctl("save-resource", ["ref": "e9-aaaaa"])
        #expect(stale.error == staleRefError("e9-aaaaa"))
        let noSource = await bed.ctl("save-resource", ["selector": "h1"])
        #expect(noSource.error == "the element has no src/href to save")
    }

    /// F-7: the scheme allowlist is checked on the URL about to be read, including one taken from an element: a
    /// hostile `src` holding `file:` is refused, not read.
    @Test func aFileURLTakenFromAnElementIsRefusedToo() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        _ = await bed.value("(document.body.insertAdjacentHTML('beforeend', '<a id=evil href=\"file:///etc/hosts\">x</a>'), 1)")
        let answer = await bed.ctl("save-resource", ["selector": "#evil"])
        #expect(answer.error == "url not allowed: file:///etc/hosts (save-resource reads http, https, blob and data URLs)")
    }

    /// J-22: over the cap, nothing is written.
    @Test func aResourceOverTheCapIsRefusedAndNothingIsWritten() async throws {
        let bed = try await ScriptVerbBed.open()
        let big = Data(count: BrowserLimits.maxResourceBytes + 1).base64EncodedString()
        let answer = await bed.ctl("save-resource", ["url": .string("data:application/octet-stream;base64,\(big)")])
        #expect(answer.error == "resource is too large to save (50.0MB; the cap is 50.0MB)")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: bed.cacheDirectory.appending(path: "agent-resources").path))?.isEmpty
                ?? true)
    }

    /// J-22: an http(s) resource is fetched from the app, whatever the page's CSP says.
    @Test func anHTTPResourceIsFetchedWhateverThePagesCSPSays() async throws {
        let bed = try await ScriptVerbBed.open("/blobpage")
        let saved = await bed.ctl("save-resource", ["url": .string(bed.server.url("/asset.png"))])
        #expect(saved.ok, "\(saved.json)")
        #expect(saved.result["contentType"] == "image/png")
        #expect(try bytes(saved.result["path"]?.stringValue) == Self.asset)
        let missing = await bed.ctl("save-resource", ["url": .string(bed.server.url("/missing"))])
        #expect(missing.error == "the resource returned HTTP 404")
    }

    /// J-22 (guide): a PDF the built-in viewer shows is a page whose text is empty; the file comes out by the pane's own
    /// address or by its `<embed>`, whole.
    @Test func aPDFInTheBuiltInViewerIsSavedByItsAddressOrItsEmbed() async throws {
        let document =
            "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF"
        let pdf = Data(document.utf8)
        let bed = try await ScriptVerbBed.open(serving: {
            $0.route("/doc.pdf", .init(status: 200, contentType: "application/pdf", data: pdf))
        })
        await bed.load("/doc.pdf")
        #expect(await bed.value("document.body.innerText") == "", "the viewer draws the document itself")
        let byAddress = await bed.ctl("save-resource", ["url": .string(bed.page.url)])
        #expect(byAddress.ok, "\(byAddress.json)")
        #expect(byAddress.result["path"]?.stringValue?.hasSuffix(".pdf") == true)
        #expect(try bytes(byAddress.result["path"]?.stringValue) == pdf)
        let byEmbed = await bed.ctl("save-resource", ["selector": "embed"])
        #expect(byEmbed.ok, "\(byEmbed.json)")
        #expect(try bytes(byEmbed.result["path"]?.stringValue) == pdf)
    }

    /// J-24: read-back verbs refuse a pane this caller does not own. (The Electron test also lists `pane-info`,
    /// `screenshot` and `get-page-text`: the other families'.)
    @Test func readBackVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let foreign = try #require(bed.harness.open("browser"))
        for (command, flags) in [
            ("assert", ["text": JSONValue.string("anything")]), ("save-resource", ["url": "https://example.com/x.png"]),
        ] {
            let answer = await bed.ctl(command, flags, pane: foreign.id)
            #expect(answer.error == "not the owner of this pane", "\(command): \(answer.json)")
        }
    }

    /// J-23, J-24: the capture verbs of the Electron test: `read-console` refuses a pane not owned; `read-network`
    /// and `capture-bodies` are not ported, so they answer as any unknown command does, and `describe` does not list them.
    @Test func captureVerbsRefuseAPaneThisCallerDoesNotOwn() async throws {
        let bed = try await ScriptVerbBed.open("/page")
        let foreign = try #require(bed.harness.open("browser"))
        #expect(await bed.ctl("read-console", pane: foreign.id).error == "not the owner of this pane")
        for command in ["read-network", "capture-bodies"] {
            let answer = await bed.ctl(command, pane: foreign.id)
            #expect(answer.error?.hasPrefix("unknown command") == true, "\(command): \(answer.json)")
        }
        let described = await bed.harness.tabsCtl("describe", ["capability": "browser"])
        let text = String(decoding: try JSONEncoder().encode(described), as: UTF8.self)
        #expect(!text.contains("read-network") && !text.contains("capture-bodies"), "the guide and the reference promise no capture")
        #expect(text.contains("save-resource"))
    }

    /// J-22, I-2: declared as `controlSpec.ts` declares it, docs verbatim; budget the longest fixed tier.
    @Test func saveResourceIsDeclaredAsControlSpecDeclaresIt() async throws {
        let bed = try await ScriptVerbBed.open()
        let verb = try #require(bed.verb("browser.saveResource"))
        #expect(verb.command == "save-resource" && verb.wireType == "saveResource" && verb.batchable)
        #expect(verb.timeout == .seconds(30))
        #expect(verb.arguments.map(\.flagName) == ["url", "ref", "selector", "out"])
        #expect(verb.arguments.allSatisfy { !$0.required })
        #expect(verb.arguments.first { $0.name == "outPath" }?.kind == .path)
        #expect(verb.arguments.first { $0.name == "url" }?.summary == "A blob:, data:, http:, or https: URL to fetch.")
        #expect(verb.arguments.first { $0.name == "ref" }?.summary == "A read-page ref whose element’s src/href is saved.")
        #expect(
            verb.arguments.first { $0.name == "outPath" }?.summary
                == "Where to write it, resolved against your shell’s cwd. Default: a temp file swept after ~10 minutes.")
        #expect(verb.summary.hasPrefix("Save a page resource — a blob:/data:/http(s) URL, or an element’s src — to a local file"))
    }
}
