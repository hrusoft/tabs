#if DEBUG
import AppKit
import TabsPluginSDK
import WebKit

/// Debug-only verbs for the visual capture and the end-to-end tests: a pane's
/// state, loading a fixture page with a base URL (the page content the
/// captures and tests need to be deterministic), running script, and where the
/// header draws its parts. Not in Release builds. (The product's verbs are
/// `Control/`, another slice.)
///
/// The visual capture's hooks (Visual/README.md): `browser.test.stage` shows a
/// scenario's `content` entry, `browser.test.visual` measures the header, and
/// `browser.test.snapshot` draws the page, which lives in another process.
@MainActor
enum BrowserTestVerbs {
    static func register(in context: any PluginContext, services: BrowserServices) {
        context.register(
            ControlVerbContribution(
                name: "browser.test.dataStore",
                summary: "Debug: the identifier of the web data store every page uses, for a test to remove once its app is gone"
            ) { [weak services] _ in
                guard let services else { throw ControlVerbError("no browser services") }
                return .string(services.webDataStore.uuidString)
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.state",
                summary: "Debug: a browser pane's URL, title, history, load state, status, console and address text",
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self) else { throw ControlVerbError("not a browser pane") }
                return pane.testState
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.load",
                summary: "Debug: load a URL, or fixture HTML under a base URL, and wait for the load to end",
                arguments: [
                    ControlArgument("url", .string), ControlArgument("html", .string), ControlArgument("baseURL", .string),
                    ControlArgument("timeoutMs", .integer),
                ],
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self) else { throw ControlVerbError("not a browser pane") }
                if let html = invocation["html"]?.stringValue {
                    pane.page.loadHTML(html, baseURL: invocation["baseURL"]?.stringValue)
                } else if let url = invocation["url"]?.stringValue {
                    pane.page.load(url)
                } else {
                    throw ControlVerbError("load needs a url or html")
                }
                let outcome = await pane.page.waitForLoadEnd(timeoutMs: Int(invocation["timeoutMs"]?.intValue ?? 10_000))
                var result: [String: JSONValue] = ["loaded": .bool(outcome.loaded), "url": .string(pane.page.url)]
                if let error = outcome.loadError { result["loadError"] = .string(error) }
                return .object(result)
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.script",
                summary: "Debug: evaluate a script (an expression) in the page and answer its value",
                arguments: [ControlArgument("code", .string, required: true)],
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self), let code = invocation["code"]?.stringValue else {
                    throw ControlVerbError("not a browser pane")
                }
                switch await pane.page.evaluate(code) {
                case .success(let value): return .object(["value": value])
                case .failure(let error): throw ControlVerbError(error.message)
                }
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.input",
                summary:
                    "Debug: send trusted input into the page as a control verb would: a click at a point (CSS pixels), typed text, a key with modifiers; the window's keyboard focus stays where it was",
                arguments: [
                    ControlArgument("x", .number), ControlArgument("y", .number), ControlArgument("text", .string),
                    ControlArgument("key", .string), ControlArgument("modifiers", .array),
                ],
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self) else { throw ControlVerbError("not a browser pane") }
                let input = PageInput(page: pane.page)
                let modifiers =
                    (invocation["modifiers"].flatMap { value -> [JSONValue]? in
                        if case .array(let items) = value { items } else { nil }
                    } ?? []).compactMap { $0.stringValue.flatMap(KeyModifier.init(rawValue:)) }
                do {
                    try await input.withHostFocusRestored {
                        if let x = invocation["x"]?.doubleValue, let y = invocation["y"]?.doubleValue { try await input.click(x: x, y: y) }
                        if let text = invocation["text"]?.stringValue { try await input.send(typingEvents(text)) }
                        if let key = invocation["key"]?.stringValue { try await input.send(keystrokeEvents(key, modifiers: modifiers)) }
                    }
                } catch {
                    throw ControlVerbError(paneNotMountedError)
                }
                return .emptyObject
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.geometry",
                summary: "Debug: where a browser pane's header draws its parts, in the header title view's coordinates",
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self), let toolbar = pane.toolbar else {
                    throw ControlVerbError("not a browser pane with a header")
                }
                toolbar.layoutSubtreeIfNeeded()
                return toolbar.geometry()
            })

        let scratch = context.temporaryDirectory
        context.register(
            ControlVerbContribution(
                name: "browser.test.stage",
                summary:
                    "Debug: show a Visual scenario's content entry: a fixture page of the color `page`, the history Back and Forward need, the `address` and `title` the bar shows, the address field focused if asked",
                arguments: [ControlArgument("spec", .object, required: true)],
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self), let spec = invocation["spec"] else {
                    throw ControlVerbError("not a browser pane")
                }
                try await pane.stage(spec, scratch: scratch)
                return .null
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.visual",
                summary:
                    "Debug: a pane's block of the visual comparison's geometry (Visual/README.md): its header's parts, in the header title view's coordinates",
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self), let toolbar = pane.toolbar else {
                    throw ControlVerbError("not a browser pane with a header")
                }
                toolbar.layoutSubtreeIfNeeded()
                return ["title": toolbar.visualGeometry()]
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.snapshot",
                summary:
                    "Debug: the page as WebKit draws it, at 2x, as a PNG at `path`: the visual capture's picture of a view whose content lives in another process",
                arguments: [ControlArgument("path", .path, required: true)],
                target: .pane(ofTypes: ["browser"])
            ) { invocation in
                guard let pane = invocation.pane(as: BrowserPane.self), let path = invocation["path"]?.stringValue else {
                    throw ControlVerbError("not a browser pane")
                }
                try await pane.page.writeSnapshot(to: URL(filePath: path))
                return .null
            })

        context.register(
            ControlVerbContribution(
                name: "browser.test.external",
                summary: "Debug: capture the URLs a page sends to the OS's browser instead of opening them; answers those captured so far",
                arguments: [ControlArgument("capture", .bool)]
            ) { [weak services] invocation in
                guard let services else { throw ControlVerbError("no browser services") }
                if let capture = invocation["capture"]?.boolValue { services.capturesExternalOpens = capture }
                return .object(["opened": .array(services.openedExternally.map { .string($0.absoluteString) })])
            })
    }
}

extension BrowserPage {
    /// Loads fixture HTML as if it were served from `baseURL` (a fixture page with
    /// a real origin, without a server).
    func loadHTML(_ html: String, baseURL: String?) {
        directLoadWillStart()
        webView.loadHTMLString(html, baseURL: baseURL.flatMap(URL.init(string:)))
    }

    /// The page as WebKit draws it, at 2x, written to `file` as a PNG.
    func writeSnapshot(to file: URL) async throws {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { throw ControlVerbError("the page isn't on screen") }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: webView.bounds.width * 2)
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { throw ControlVerbError("no snapshot") }
        try png.write(to: file)
    }
}

extension BrowserPane {
    /// A Visual scenario's content entry, on screen: a page of the seeded solid
    /// color (`page`) titled `title`, with the history behind and ahead of it
    /// that Back and Forward need (`canGoBack`, `canGoForward`), the bar showing
    /// `address`, and the address field focused (`focusAddress`).
    ///
    /// Nothing is fetched: the scenario's pane starts on about:blank and every
    /// page is a fixture file in `scratch`, loaded for real so the history is
    /// real (WebKit replaces the entry of one fixture string loaded over
    /// another, and won't push entries from a script that no one clicked for).
    /// The bar is then told to show `address`, and no title where `title` is
    /// absent.
    func stage(_ spec: JSONValue, scratch: URL) async throws {
        guard let color = spec["page"]?.stringValue else { throw ControlVerbError("no page color") }
        let address = spec["address"]?.stringValue ?? BrowserPage.blank
        let title = spec["title"]?.stringValue
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let prefix = UUID().uuidString
        func fixture(_ name: String, title: String?, color: String) throws -> URL {
            let escaped = title.map { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
            let html =
                "<!doctype html><meta charset=utf-8>\(escaped.map { "<title>\($0)</title>" } ?? "")"
                + "<body style=\"margin:0;background:\(color)\">"
            let file = scratch.appending(path: "\(prefix)-\(name).html")
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func load(_ file: URL) async throws {
            page.load(file.absoluteString)
            let outcome = await page.waitForLoadEnd(timeoutMs: 10_000)
            guard outcome.loaded else { throw ControlVerbError("\(file.lastPathComponent) didn't load: \(outcome.loadError ?? "")") }
        }
        let back = spec["canGoBack"] == .bool(true)
        let forward = spec["canGoForward"] == .bool(true)
        if back { try await load(fixture("previous", title: "Previous", color: "#3a3a3a")) }
        let current = try fixture("current", title: title, color: color)
        try await load(current)
        if forward {
            try await load(fixture("next", title: "Next", color: "#3a3a3a"))
            _ = await page.evaluate("history.back()")
        }
        // The history the seed asks for, on the page it asks for, titled.
        for _ in 0..<100 {
            if page.url == current.absoluteString, !page.isLoading, page.canGoBack == back, page.canGoForward == forward,
                title == nil || page.title == title
            {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let toolbar else { throw ControlVerbError("no header") }
        // A page with no title still has the URL-derived one; the scenario's is what shows.
        toolbar.titleOverride = title == nil ? "" : nil
        toolbar.addressOverride = address
        toolbar.sync()
        guard page.url == current.absoluteString, page.canGoBack == back, page.canGoForward == forward,
            toolbar.bar.address == address, toolbar.bar.title == (title ?? ""), toolbar.back.isEnabled == back,
            toolbar.forward.isEnabled == forward
        else { throw ControlVerbError("not as seeded: \(testState)") }
        if spec["focusAddress"] == .bool(true) {
            let field = toolbar.bar.field
            guard let window = field.window, window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                throw ControlVerbError("the address field would not take focus")
            }
            // A hidden caret at the start, rather than the whole text selected
            // as a focus by keyboard would leave it.
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertionPointColor = .clear
        }
    }
}

extension BrowserPane {
    var testState: JSONValue {
        var state: [String: JSONValue] = [
            "url": .string(page.url),
            "title": .string(page.title),
            "canGoBack": .bool(page.canGoBack),
            "canGoForward": .bool(page.canGoForward),
            "isLoading": .bool(page.isLoading),
            "hasCommitted": .bool(page.hasCommitted),
            "showingErrorPage": .bool(page.isShowingErrorPage),
            "console": .int(Int64(page.console.list().count)),
            "pageInstance": .string(String(page.pageInstance)),
            "visible": .bool(page.isVisible),
            "configURL": currentConfig()["url"] ?? .null,
        ]
        if let status = page.documentStatus {
            state["status"] = .int(Int64(status.status))
            state["statusText"] = .string(status.statusText)
        }
        if let error = page.lastLoadError { state["loadError"] = .string(error) }
        if let toolbar {
            state["addressText"] = .string(toolbar.bar.address)
            state["titleSegment"] = .string(toolbar.bar.title)
            state["backEnabled"] = .bool(toolbar.back.isEnabled)
            state["forwardEnabled"] = .bool(toolbar.forward.isEnabled)
            state["editingAddress"] = .bool(toolbar.isEditingAddress)
        }
        return .object(state)
    }
}

extension BrowserToolbar {
    /// A pane's block of the visual comparison's geometry (docs/BROWSER.md,
    /// Visual): rects `[x, y, width, height]` in this view's coordinates (the
    /// capture adds its origin). Text rects are the line box of the text, clipped: the title's to
    /// the segment's border box, the address's to the input's content box.
    func visualGeometry() -> JSONValue {
        func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        func rect(_ rect: CGRect) -> JSONValue {
            .array([.double(round2(rect.minX)), .double(round2(rect.minY)), .double(round2(rect.width)), .double(round2(rect.height))])
        }
        let layout = computeLayout(width: bounds.width)
        let barLayout = bar.computeLayout()
        let origin = layout.bar.origin
        let font = BrowserText.ui12
        var out: [String: JSONValue] = [
            "page": rect(pane.page.webView.convert(pane.page.webView.bounds, to: self)),
            "back": rect(layout.back), "forward": rect(layout.forward), "refresh": rect(layout.refresh),
            "backDisabled": .bool(!back.isEnabled), "forwardDisabled": .bool(!forward.isEnabled),
            "addressBar": rect(layout.bar),
            "titleSegment": .null, "titleText": .null, "titleBaseline": .null, "titleString": .null, "titleTruncated": .bool(false),
            "focused": .bool(isEditingAddress),
        ]
        if let segment = barLayout.segment?.offsetBy(dx: origin.x, dy: origin.y) {
            let left = segment.minX + BrowserMetrics.segmentPaddingX
            let baseline =
                segment.minY + BrowserMetrics.segmentPaddingY + font.halfLeading(in: BrowserMetrics.segmentLineHeight) + font.ascent
            let textWidth = font.width(bar.title)
            out["titleSegment"] = rect(segment)
            out["titleText"] = rect(
                CGRect(x: left, y: baseline - font.ascent, width: min(textWidth, segment.maxX - left), height: font.lineHeight))
            out["titleBaseline"] = .double(round2(baseline))
            out["titleString"] = .string(bar.title)
            out["titleTruncated"] = .bool(textWidth > segment.width - 2 * BrowserMetrics.segmentPaddingX - 1 + 0.01)
        }
        let input = barLayout.input.offsetBy(dx: origin.x, dy: origin.y)
        let text = AddressBar.inputTextOrigin(in: input)
        let textLeft = text.x
        let textRight = input.maxX - BrowserMetrics.inputPaddingX
        out["addressInput"] = rect(input)
        out["addressText"] = rect(
            CGRect(
                x: textLeft, y: text.y - font.ascent, width: max(min(font.width(bar.address), textRight - textLeft), 0),
                height: font.lineHeight))
        out["addressBaseline"] = .double(round2(text.y))
        out["addressValue"] = .string(bar.address)
        return .object(out)
    }

    /// The header parts' rectangles, `[x, y, width, height]` in this view's
    /// coordinates (the capture adds its origin), with the address text's baseline.
    func geometry() -> JSONValue {
        func rect(_ rect: CGRect?) -> JSONValue {
            guard let rect else { return .null }
            func round2(_ x: Double) -> JSONValue { .double((x * 100).rounded() / 100) }
            return .array([round2(rect.minX), round2(rect.minY), round2(rect.width), round2(rect.height)])
        }
        let layout = computeLayout(width: bounds.width)
        let barLayout = bar.computeLayout()
        let barOrigin = layout.bar.origin
        func inBar(_ rect: CGRect?) -> CGRect? { rect?.offsetBy(dx: barOrigin.x, dy: barOrigin.y) }
        var out: [String: JSONValue] = [:]
        out["back"] = rect(layout.back)
        out["forward"] = rect(layout.forward)
        out["refresh"] = rect(layout.refresh)
        out["bar"] = rect(layout.bar)
        out["segment"] = rect(inBar(barLayout.segment))
        out["input"] = rect(inBar(barLayout.input))
        let origin = AddressBar.inputTextOrigin(in: barLayout.input)
        out["inputBaseline"] = .double(((barOrigin.y + origin.y) * 100).rounded() / 100)
        if let segment = barLayout.segment {
            let font = BrowserText.ui12
            let baseline =
                segment.minY + BrowserMetrics.segmentPaddingY + font.halfLeading(in: BrowserMetrics.segmentLineHeight) + font.ascent
            out["segmentBaseline"] = .double(((barOrigin.y + baseline) * 100).rounded() / 100)
        } else {
            out["segmentBaseline"] = .null
        }
        return .object(out)
    }
}
#endif
