#if DEBUG
import AppKit
import TabsCore
import TabsPluginSDK
import WebKit

/// `Tabs --render-scenarios <dir> --out <dir> [names…]` (Debug builds): the
/// native half of the visual comparison with the Electron app
/// (`native/Visual/`). Each scenario's layout goes through the real engine
/// and renderer in a window that is never shown, with the scenario's hover or
/// drag applied, and comes out as `<name>.png` (the content area at 2x) and
/// `<name>.geometry.json` in the Electron capture's format.
@MainActor
enum VisualCapture {
    static func arguments(_ arguments: [String]) -> (scenarios: URL, out: URL, names: [String])? {
        guard let index = arguments.firstIndex(of: "--render-scenarios"), arguments.indices.contains(index + 1),
            let out = arguments.firstIndex(of: "--out"), arguments.indices.contains(out + 1)
        else { return nil }
        let names = arguments[(index + 2)...].filter { !$0.hasPrefix("--") && $0 != arguments[out + 1] }
        return (URL(filePath: arguments[index + 1]), URL(filePath: arguments[out + 1]), Array(names))
    }

    struct Scenario: Decodable {
        struct Size: Decodable {
            var width: Double
            var height: Double
        }

        struct Point: Decodable {
            var x: Double
            var y: Double
        }

        struct Drag: Decodable {
            var from: Point
            var to: Point
        }

        struct PaletteSpec: Decodable {
            var step: String
            var highlight: Int?
            var hover: Int?
        }

        var size: Size
        var settings: [String: JSONValue]?
        var layout: LayoutSnapshot
        var pointer: Point?
        var drag: Drag?
        var fullscreen: Bool?
        /// The managed caffeinate process counts as running: the root bar's cup shows.
        var caffeinate: Bool?
        var contextMenu: Point?
        /// The command palette open: which step, the row a key press moved the
        /// highlight to, and the row the pointer is over.
        var palette: PaletteSpec?
        /// Extra stub types after the harness's own that the palette lists
        /// ("Sample 2"…), for a list longer than nine rows.
        var paletteTypes: Int?
        var tooltip: Bool?
        /// Signals to put on panes, by pane id: the Electron app's two cues,
        /// `bell` and `controlled` (`SignalFixtures`).
        var signals: [String: [String]]?
        /// Freezes every pulse this many seconds in; nil: the peak (opacity 1,
        /// as the Electron capture with its animations disabled).
        var pulse: Double?
        /// Git tree panes' scripted history, by pane id (the real git tree
        /// plugin is loaded, and answered by `git-tree.test.script`).
        var gitTree: [String: JSONValue]?
        /// Browser panes' stand-in pages, by pane id (`page`, and the optional
        /// `canGoBack`, `canGoForward`, `focusAddress`): the real browser plugin
        /// is loaded, and shows a fixture page of that color.
        var browser: [String: JSONValue]?
        /// What the layout says about each browser leaf (its live title and the
        /// URL it stands at), read while decoding; the pane itself starts blank,
        /// so that nothing is fetched.
        var browserLeaves: [String: BrowserLeaf]?
        /// Content types, besides the harness's stub, that an empty pane offers
        /// (only `browser`: its globe button).
        var creationActions: [String]?
    }

    struct BrowserLeaf: Decodable {
        var title: String?
        var url: String
    }

    /// A scenario file, with the Electron app's content type names mapped to
    /// the native plugins' (`gitTree` is `git-tree`).
    static func decodeScenario(_ data: Data) throws -> Scenario {
        var browserLeaves: [String: BrowserLeaf] = [:]
        func mapTypes(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(var object):
                if object["type"] == .string("gitTree") { object["type"] = .string("git-tree") }
                if object["type"] == .string("browser"), let id = object["id"]?.stringValue {
                    var config: [String: JSONValue] = [:]
                    if case .object(let existing)? = object["config"] { config = existing }
                    browserLeaves[id] = BrowserLeaf(title: object["title"]?.stringValue, url: config["url"]?.stringValue ?? "about:blank")
                    config["url"] = .string("about:blank")
                    object["config"] = .object(config)
                    object["title"] = nil
                }
                return .object(object.mapValues(mapTypes))
            case .array(let values): return .array(values.map(mapTypes))
            default: return value
            }
        }
        var json = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .object(var object) = json, let layout = object["layout"] {
            object["layout"] = mapTypes(layout)
            json = .object(object)
        }
        var scenario = try JSONDecoder().decode(Scenario.self, from: json.encodedData(pretty: false))
        if !browserLeaves.isEmpty { scenario.browserLeaves = browserLeaves }
        return scenario
    }

    static func run(scenarios: URL, out: URL, names: [String]) async -> Int32 {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: scenarios, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { names.isEmpty || names.contains($0.deletingPathExtension().lastPathComponent) }
        var failures = 0
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            do {
                let scenario = try decodeScenario(Data(contentsOf: file))
                try await capture(scenario, name: name, to: out)
                print("captured \(name)")
            } catch {
                print("failed \(name): \(error)")
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    private static func capture(_ scenario: Scenario, name: String, to out: URL) async throws {
        let staged = try await stage(scenario)
        defer { staged.tearDown() }
        try render(staged.controller.root, pages: await staged.pageSnapshots()).write(to: out.appending(path: "\(name).png"))
        try await staged.geometryWithContent().encodedData().write(to: out.appending(path: "\(name).geometry.json"))
    }

    /// A scenario on screen (in a window that's never shown), as the Electron
    /// harness would show it: its layout, settings, and any hover, right-click
    /// or drag applied and settled.
    @MainActor
    final class Staged {
        let runtime: CoreRuntime
        let engine: LayoutEngine
        let renderer: WorkspaceRenderer
        let controller: WorkspaceWindowController
        let scenario: Scenario
        private let data: URL

        fileprivate init(
            runtime: CoreRuntime, engine: LayoutEngine, renderer: WorkspaceRenderer, controller: WorkspaceWindowController,
            scenario: Scenario,
            data: URL
        ) {
            self.runtime = runtime
            self.engine = engine
            self.renderer = renderer
            self.controller = controller
            self.scenario = scenario
            self.data = data
        }

        /// The geometry in the Electron capture's format.
        func geometry() -> JSONValue {
            controller.root.layoutSubtreeIfNeeded()
            return GeometryDump(controller: controller, renderer: renderer, size: scenario.size).json()
        }

        /// The geometry plus the git tree block (`gitTree`), which the
        /// plugin reports in its view's coordinates, offset here by each
        /// pane's body.
        func geometryWithContent() async throws -> JSONValue {
            var geometry = geometry()
            if let browser = try await browserGeometry(placing: geometry), case .object(var object) = geometry {
                object["browser"] = browser
                geometry = .object(object)
            }
            guard let gitTree = scenario.gitTree, !gitTree.isEmpty else { return geometry }
            var block: [String: JSONValue] = [:]
            for pane in gitTree.keys.sorted() {
                let answer = await runtime.control.handle(.init(command: "git-tree.test.geometry", targetPane: PaneID(pane)))
                guard answer["ok"] == .bool(true), case .object(let local)? = answer["result"],
                    let body = geometry["panes"]?[pane]?["body"], let x = body[0]?.doubleValue, let y = body[1]?.doubleValue,
                    let title = controller.paneView(NodeID(pane))?.header?.titleView
                else { throw Failure("git-tree.test.geometry: \(answer)") }
                // The toolbar is the header's title: its rects are in that view's coordinates.
                let inTitle = local.filter { Self.headerTitleKeys.contains($0.key) }
                let inBody = local.filter { !Self.headerTitleKeys.contains($0.key) }
                let origin = title.convert(NSPoint.zero, to: controller.root)
                guard case .object(let placedTitle) = Self.offset(.object(inTitle), by: origin),
                    case .object(let placedBody) = Self.offset(.object(inBody), by: CGPoint(x: x, y: y))
                else { throw Failure("git-tree.test.geometry: offsetting") }
                block[pane] = .object(placedBody.merging(placedTitle) { $1 })
            }
            if case .object(var object) = geometry {
                object["gitTree"] = .object(block)
                geometry = .object(object)
            }
            return geometry
        }

        /// The `browser` block: what the plugin reports in its header title's
        /// coordinates (`browser.test.visual`), offset to the window.
        func browserGeometry(placing geometry: JSONValue) async throws -> JSONValue? {
            guard let leaves = scenario.browser, !leaves.isEmpty else { return nil }
            var block: [String: JSONValue] = [:]
            for pane in leaves.keys.sorted() {
                let answer = await runtime.control.handle(.init(command: "browser.test.visual", targetPane: PaneID(pane)))
                guard answer["ok"] == .bool(true), let local = answer["result"],
                    let title = controller.paneView(NodeID(pane))?.header?.titleView
                else { throw Failure("browser.test.visual: \(answer)") }
                block[pane] = Self.offset(local, by: title.convert(NSPoint.zero, to: controller.root))
            }
            return .object(block)
        }

        /// The browser pages' pixels: a `WKWebView`'s content lives in another
        /// process, so the layer tree renders it blank. Each page as WebKit
        /// snapshots it, at 2x, to stand in for the view's layer contents.
        func pageSnapshots() async throws -> [(WKWebView, CGImage)] {
            var out: [(WKWebView, CGImage)] = []
            for web in Self.webViews(in: controller.root) where web.bounds.width > 0 && web.bounds.height > 0 {
                let configuration = WKSnapshotConfiguration()
                configuration.snapshotWidth = NSNumber(value: web.bounds.width * 2)
                let image = try await web.takeSnapshot(configuration: configuration)
                guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure("page snapshot") }
                // `CALayer.render(in:)` ignores a layer's Core Image filters, and a
                // snapshot is the page before them: an inactive pane's dimming
                // (`PaneBodyHost.applyDim`) is applied here.
                if let filters = web.layer?.filters as? [CIFilter], !filters.isEmpty {
                    var filtered = CIImage(cgImage: cg)
                    for filter in filters {
                        filter.setValue(filtered, forKey: kCIInputImageKey)
                        guard let next = filter.outputImage else { throw Failure("page dimming") }
                        filtered = next
                    }
                    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
                    guard let rendered = context.createCGImage(filtered, from: CIImage(cgImage: cg).extent) else {
                        throw Failure("page dimming")
                    }
                    cg = rendered
                }
                out.append((web, cg))
            }
            return out
        }

        static func webViews(in view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }

        /// The geometry keys the git tree reports for its header title.
        static let headerTitleKeys: Set<String> = [
            "pathInput", "browse", "pathBaseline", "head", "headText", "headBaseline", "select", "selectBaseline",
        ]

        /// Every rect (`[x, y, w, h]`) and baseline in `value` moved by `origin`.
        static func offset(_ value: JSONValue, by origin: CGPoint, key: String? = nil) -> JSONValue {
            func round2(_ x: Double) -> JSONValue { .double((x * 100).rounded() / 100) }
            switch value {
            case .array(let items) where items.count == 4 && items.allSatisfy({ $0.doubleValue != nil }) && key != "refs":
                let n = items.compactMap(\.doubleValue)
                return .array([round2(n[0] + origin.x), round2(n[1] + origin.y), round2(n[2]), round2(n[3])])
            case .array(let items): return .array(items.map { offset($0, by: origin) })
            case .object(let object):
                var out: [String: JSONValue] = [:]
                for (name, item) in object {
                    if name.hasSuffix("aseline"), let y = item.doubleValue {
                        out[name] = round2(y + origin.y)
                    } else {
                        out[name] = offset(item, by: origin, key: name)
                    }
                }
                return .object(out)
            default: return value
            }
        }

        func tearDown() {
            SignalPulse.frozenTime = nil
            renderer.drag.endSimulation()
            HeaderMenu.close()
            ChromeTooltip.hide()
            engine.tearDown()
            runtime.host.stop()
            try? FileManager.default.removeItem(at: data)
        }
    }

    static func stage(_ scenario: Scenario) async throws -> Staged {
        let data = FileManager.default.temporaryDirectory.appending(path: "tabs-visual-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if let gitTree = scenario.gitTree, !gitTree.isEmpty {
            // The git tree's own settings, as the Electron scenario gives them.
            let blob = scenario.settings?["contentTypes"]?["gitTree"] ?? .emptyObject
            let settingsFile: JSONValue = ["version": 1, "plugins": ["git-tree": blob]]
            try settingsFile.encodedData().write(to: data.appending(path: "settings.json"))
        }
        let runtime = CoreRuntime(paths: AppPaths(dataDirectory: data), readOnly: true)
        var required: Set<ContentTypeID> = []
        if scenario.gitTree?.isEmpty == false { required.insert(ContentTypeID("git-tree")) }
        if scenario.browser?.isEmpty == false { required.insert(ContentTypeID("browser")) }
        if scenario.creationActions?.contains("browser") == true { required.insert(ContentTypeID("browser")) }
        if !required.isEmpty { runtime.startBundledPlugins(of: .main, requiredContentTypes: required) }
        let engine = LayoutEngine(runtime: runtime)
        let renderer = WorkspaceRenderer(runtime: runtime, engine: engine, presentsWindows: false)
        // The Electron harness registers one stub content type ("▣").
        // A type the scenario asks for is offered before the stub: the Electron
        // harness registers its stand-in browser before it mounts the stub.
        var creationActions: [EmptyPaneView.Action] = []
        for contribution in runtime.panes.creatableTypes().map(\.value)
        where scenario.creationActions?.contains(contribution.id.rawValue) == true {
            creationActions.append(
                EmptyPaneView.Action(
                    type: contribution.id, label: contribution.resolvedCreationLabel, displayName: contribution.displayName,
                    icon: EmptyPaneView.Icon(contribution.icon)))
        }
        creationActions.append(EmptyPaneView.Action(type: "stub", label: "New stub", displayName: "Stub", icon: .glyph("▣")))
        for number in 2..<(2 + max(scenario.paletteTypes ?? 0, 0)) {
            creationActions.append(
                EmptyPaneView.Action(
                    type: ContentTypeID("sample-\(number)"), label: "New sample \(number)", displayName: "Sample \(number)",
                    icon: .glyph("▣")))
        }
        // The harness offers nothing for a type the scenario turned off.
        if case .array(let off)? = scenario.settings?["disabledContentTypes"] {
            let disabled = Set(off.compactMap(\.stringValue))
            creationActions.removeAll { disabled.contains($0.type.rawValue) }
        }
        renderer.creationActionsOverride = creationActions
        var appearance = PaneAppearance()
        let settings = scenario.settings ?? [:]
        appearance.theme = Theme.resolve(settings["colorTheme"]?.stringValue ?? "dark", systemIsDark: true)
        if case .bool(let dim)? = settings["dimInactivePanes"] { appearance.dimInactivePanes = dim }
        if let intensity = settings["dimInactivePanesIntensity"]?.doubleValue { appearance.dimIntensity = intensity }
        if case .bool(let snap)? = settings["snapResizeSeparators"] { appearance.snapResizeSeparators = snap }
        // The harness reports no window corner radius.
        appearance.cornerRadius = 0
        appearance.caffeinateRunning = scenario.caffeinate == true
        renderer.baseAppearance = appearance
        // The Electron capture hides tooltips unless the scenario waits for one.
        ChromeTooltip.isSuppressed = scenario.tooltip != true
        // Pulses freeze where the Electron capture pauses its animations.
        SignalPulse.frozenTime = scenario.pulse

        engine.restore(SavedLayout(windows: [scenario.layout.window]))
        guard let controller = renderer.windows.first, let window = controller.window else {
            try? FileManager.default.removeItem(at: data)
            throw Failure("no window")
        }
        let staged = Staged(runtime: runtime, engine: engine, renderer: renderer, controller: controller, scenario: scenario, data: data)
        window.setContentSize(NSSize(width: scenario.size.width, height: scenario.size.height))
        engine.reconcile()
        controller.root.layoutSubtreeIfNeeded()
        if let signals = scenario.signals {
            // Raised while their switches are on (Electron seeds the stores
            // directly); the scenario's settings may then hide them.
            SignalFixtures.declare(in: runtime.signals)
            for (pane, kinds) in signals.sorted(by: { $0.key < $1.key }) {
                for kind in kinds { runtime.signals.raise(PaneSignal(kind), on: PaneID(pane), by: nil) }
            }
            var panes = runtime.settings.panes
            if case .bool(false)? = settings["enableBellIndicator"] { panes.disabledSignals.append(SignalFixtures.bellID) }
            if case .bool(false)? = settings["enableControlIndicator"] { panes.disabledSignals.append(SignalFixtures.controlledID) }
            runtime.settings.setPanes(panes)
        }
        if let gitTree = scenario.gitTree {
            for (_, fixture) in gitTree.sorted(by: { $0.key < $1.key }) {
                let answer = await runtime.control.handle(.init(command: "git-tree.test.script", arguments: ["fixture": fixture]))
                guard answer["ok"] == .bool(true) else { throw Failure("git-tree.test.script: \(answer)") }
            }
            controller.root.layoutSubtreeIfNeeded()
        }
        if let browser = scenario.browser {
            for (pane, spec) in browser.sorted(by: { $0.key < $1.key }) {
                try await stageBrowser(
                    pane, spec: spec, leaf: scenario.browserLeaves?[pane], in: runtime, controller: controller, data: data)
            }
            controller.root.layoutSubtreeIfNeeded()
        }
        if scenario.fullscreen == true {
            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            controller.root.layoutSubtreeIfNeeded()
        }
        if let point = scenario.contextMenu {
            rightClick(at: CGPoint(x: point.x, y: point.y), in: controller)
        }
        if let spec = scenario.palette { openPalette(spec, in: controller) }
        if let pointer = scenario.pointer {
            hover(at: CGPoint(x: pointer.x, y: pointer.y), in: controller)
        }
        if let drag = scenario.drag {
            renderer.drag.simulate(from: CGPoint(x: drag.from.x, y: drag.from.y), to: CGPoint(x: drag.to.x, y: drag.to.y), in: controller)
        }
        // Transitions (the controls' fade, the dropdown) settle; a tooltip shows after 400ms.
        try? await Task.sleep(for: .milliseconds(scenario.tooltip == true ? 800 : 450))
        controller.root.layoutSubtreeIfNeeded()
        return staged
    }

    /// A browser pane as the Electron scenario shows it: a page of the seeded
    /// solid color and the live title the layout gives, at the URL the layout
    /// gives, with the history behind and ahead of it that Back and Forward
    /// need, and the address field focused when asked.
    ///
    /// Nothing is fetched: the pane starts on `about:blank` (see
    /// `decodeScenario`) and every page is a fixture file, loaded for real so
    /// the history is real (WebKit replaces the entry of one fixture string
    /// loaded over another, and won't push entries from a script that no one
    /// clicked for). The bar is then told to show the layout's URL, and the
    /// layout's title where the page has none.
    private static func stageBrowser(
        _ pane: String, spec: JSONValue, leaf: BrowserLeaf?, in runtime: CoreRuntime, controller: WorkspaceWindowController, data: URL
    ) async throws {
        let id = PaneID(pane)
        guard let page = spec["page"]?.stringValue else { throw Failure("browser.\(pane): no page color") }
        let shownURL = leaf?.url ?? "about:blank"
        func call(_ command: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
            let answer = await runtime.control.handle(.init(command: command, arguments: .object(arguments), targetPane: id))
            guard answer["ok"] == .bool(true), let result = answer["result"] else { throw Failure("\(command): \(answer)") }
            return result
        }
        func fixture(_ name: String, title: String?, color: String) throws -> URL {
            let escaped = title.map { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
            let html =
                "<!doctype html><meta charset=utf-8>\(escaped.map { "<title>\($0)</title>" } ?? "")"
                + "<body style=\"margin:0;background:\(color)\">"
            let file = data.appending(path: "\(pane)-\(name).html")
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func load(_ file: URL) async throws {
            let result = try await call("browser.test.load", ["url": .string(file.absoluteString)])
            guard result["loaded"] == .bool(true) else { throw Failure("browser.\(pane): \(result)") }
        }
        let back = spec["canGoBack"] == .bool(true)
        let forward = spec["canGoForward"] == .bool(true)
        if back { try await load(fixture("previous", title: "Previous", color: "#3a3a3a")) }
        let current = try fixture("current", title: leaf?.title, color: page)
        try await load(current)
        if forward {
            try await load(fixture("next", title: "Next", color: "#3a3a3a"))
            _ = try await call("browser.test.script", ["code": .string("history.back()")])
        }
        // The history the seed asks for, on the page it asks for.
        var state = try await call("browser.test.state")
        for _ in 0..<100 {
            if state["url"]?.stringValue == current.absoluteString, state["isLoading"] == .bool(false),
                state["canGoBack"] == .bool(back), state["canGoForward"] == .bool(forward)
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
            state = try await call("browser.test.state")
        }
        var chrome: [String: JSONValue] = ["address": .string(shownURL)]
        // A page with no title still has the URL-derived one; the layout's is what shows.
        if leaf?.title == nil { chrome["title"] = .string("") }
        _ = try await call("browser.test.chrome", chrome)
        state = try await call("browser.test.state")
        guard state["url"]?.stringValue == current.absoluteString, state["canGoBack"] == .bool(back),
            state["canGoForward"] == .bool(forward),
            state["addressText"]?.stringValue == shownURL, state["titleSegment"]?.stringValue == (leaf?.title ?? ""),
            state["backEnabled"] == .bool(back), state["forwardEnabled"] == .bool(forward)
        else { throw Failure("browser.\(pane) is not as seeded: \(state)") }
        if spec["focusAddress"] == .bool(true) {
            guard let window = controller.window, let toolbar = controller.paneView(NodeID(pane))?.header?.titleView,
                let field = Self.textField(in: toolbar), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView
            else { throw Failure("browser.\(pane): the address field would not take focus") }
            // The Electron capture's script focus leaves a caret at the start (hidden
            // by the capture), not the text selected as a focus by keyboard does.
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertionPointColor = .clear
        }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        (view as? NSTextField) ?? view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The root view's layer tree at 2x, opaque sRGB.
    static func render(_ view: NSView, pages: [(WKWebView, CGImage)] = []) throws -> Data {
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let layer = view.layer
        else { throw Failure("no bitmap") }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped || view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        // Each page's snapshot replaces the layer tree's own rendering of the
        // page (its hosted remote layers, drawn undimmed and unfiltered) while
        // the tree renders, so what core draws over the page (the controlled
        // pane's glow) composites over it as on screen.
        var restore: [() -> Void] = []
        for (web, page) in pages {
            guard let layer = web.layer else { continue }
            let (contents, scale, gravity) = (layer.contents, layer.contentsScale, layer.contentsGravity)
            let hosted = (layer.sublayers ?? []).filter { !$0.isHidden }
            hosted.forEach { $0.isHidden = true }
            layer.contents = page
            layer.contentsScale = 2
            layer.contentsGravity = .resize
            restore.append {
                layer.contents = contents
                layer.contentsScale = scale
                layer.contentsGravity = gravity
                hosted.forEach { $0.isHidden = false }
            }
        }
        layer.render(in: context)
        restore.forEach { $0() }
        guard let image = context.makeImage() else { throw Failure("no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("no png") }
        return png
    }

    /// The palette as the Electron capture leaves it: opened by its chord, the
    /// second step reached by choosing the first row, the highlight moved to a
    /// row by the arrow keys, or the pointer put over one.
    static func openPalette(_ spec: Scenario.PaletteSpec, in controller: WorkspaceWindowController) {
        guard let palette = Palette.open(in: controller) else { return }
        palette.layoutSubtreeIfNeeded()
        if spec.step == "placement" { palette.choose(0) }
        palette.layoutSubtreeIfNeeded()
        if let row = spec.highlight { palette.setHighlight(row) }
        if let row = spec.hover {
            let box = palette.rowRect(row)
            palette.simulatePointer(at: CGPoint(x: palette.panelLayout.minX + box.midX, y: palette.panelLayout.minY + box.midY))
        }
    }

    /// A right-click at `point` (content coordinates), as the view there gets it.
    static func rightClick(at point: CGPoint, in controller: WorkspaceWindowController) {
        guard let window = controller.window else { return }
        let root = controller.root
        guard let view = root.hitTest(root.convert(point, to: root.superview)),
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: root.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)
        else { return }
        view.rightMouseDown(with: event)
    }

    /// Whether `view` is inside a pane body's plugin content.
    static func isPluginContent(_ view: NSView) -> Bool {
        !(view is PaneBodyHost) && sequence(first: view, next: \.superview).contains { $0 is PaneBodyHost }
    }

    /// Hovers the pointer at `point` (content coordinates): every view under
    /// it hears the pointer enter and move, as tracking areas would tell it.
    static func hover(at point: CGPoint, in controller: WorkspaceWindowController) {
        guard let window = controller.window else { return }
        let root = controller.root
        ChromeHover.update(point, in: root)
        // A menu the hover opened now covers the pointer.
        if let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: root.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        {
            HeaderMenu.simulatePointer(event)
            // A plugin's own view under the pointer hears it move, as its
            // tracking area would tell it (core's chrome hovers through ChromeHover).
            if let view = root.hitTest(root.convert(point, to: root.superview)), !(view is PointerHover),
                isPluginContent(view)
            {
                view.mouseMoved(with: event)
            } else if let view = root.hitTest(root.convert(point, to: root.superview)), !(view is PointerHover),
                sequence(first: view, next: \.superview).contains(where: { $0 is PaneHeaderView })
            {
                // A plugin's header title (the browser's nav buttons) hears the
                // pointer arrive, as its tracking area would tell it.
                if let entered = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: root.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil)
                {
                    view.mouseEntered(with: entered)
                }
            }
        }
    }
}

/// The on-screen geometry, in the Electron capture's format
/// (`native/Visual/README.md`): content coordinates, top-left origin.
@MainActor
struct GeometryDump {
    let controller: WorkspaceWindowController
    let renderer: WorkspaceRenderer
    let size: VisualCapture.Scenario.Size

    private var root: WindowRootView { controller.root }

    private func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .double(($0 * 100).rounded() / 100) })
    }

    /// A view's layout rect (unsnapped, as Chromium reports boxes), or a
    /// rect in its drawing coordinates.
    private func rect(of view: NSView, _ local: CGRect? = nil) -> JSONValue {
        if local == nil, let flipped = view as? FlippedView { return rect(flipped.layoutFrame) }
        return rect(view.convert(local ?? view.bounds, to: root))
    }

    /// A layout-local rect of `view`, in content coordinates.
    private func rect(ofLayout view: FlippedView, _ local: CGRect) -> JSONValue {
        rect(local.offsetBy(dx: view.layoutFrame.minX, dy: view.layoutFrame.minY))
    }

    private func number(_ value: CGFloat) -> JSONValue { .double((value * 100).rounded() / 100) }

    private var visiblePanes: [PaneView] {
        func collect(_ view: NSView) -> [PaneView] {
            guard !view.isHidden else { return [] }
            return ((view as? PaneView).map { [$0] } ?? []) + view.subviews.flatMap(collect)
        }
        return collect(root)
    }

    func json() -> JSONValue {
        let layout = controller.layout
        let visuals = controller.dragVisuals
        var panes: [String: JSONValue] = [:]
        var bars: [String: JSONValue] = [:]
        var controls: [String: JSONValue] = [:]
        var toolbars: [String: JSONValue] = [:]
        let text = ChromeText(size: Metrics.chromeFontSize)
        for pane in visiblePanes {
            let id = pane.nodeID.rawValue
            var entry: [String: JSONValue] = [
                "rect": rect(of: pane), "depth": .int(Int64(pane.depth)), "active": .bool(layout.activePaneID == pane.nodeID),
                "dragging": .bool(visuals.sourcePane == pane.nodeID),
                "dimmed": .bool(pane.isLeaf && layout.activePaneID != pane.nodeID && controller.appearance.dimInactivePanes),
                "header": .null, "title": .null, "titleBaseline": .null, "titleText": .null, "grip": .null,
            ]
            if let header = pane.header {
                entry["body"] = rect(of: pane.content)
                entry["header"] = rect(of: header)
                // A plugin's own title view has no title text to report.
                if header.titleView == nil {
                    let label = header.titleRect
                    let title = controller.paneTitle(of: pane.node)
                    let lineTop = label.minY + (label.height - text.lineHeight) / 2
                    entry["title"] = rect(
                        of: header, CGRect(x: label.minX, y: lineTop, width: min(text.width(title), label.width), height: text.lineHeight))
                    entry["titleBaseline"] = number(header.convert(CGPoint(x: 0, y: lineTop + text.ascent), to: root).y)
                    entry["titleText"] = .string(title)
                }
                entry["grip"] = rect(of: header.grip)
                controls[id] = controlsJSON(header.controls, visible: header.controls.isRevealed)
                if let icons = signalIconsJSON(header.signalIcons) { entry["signalIcons"] = icons }
                if let cue = renderer.engine.signals.outline(of: pane.nodeID) { entry["cue"] = .string(cue.kind.id) }
            } else {
                let insets = pane.borderInsets
                let size = pane.layoutSize
                entry["body"] = rect(
                    ofLayout: pane,
                    CGRect(
                        x: insets.left, y: insets.top, width: size.width - insets.left - insets.right,
                        height: size.height - insets.top - insets.bottom))
            }
            if let bar = pane.tabBar {
                bars[id] = barJSON(bar)
                controls[id] = controlsJSON(bar.controls, visible: bar.controls.isRevealed)
            }
            // With nothing to create there is no toolbar (the sentence stands in).
            if case .leaf(let leaf) = pane.node, let empty = renderer.bodyHost(for: leaf).content as? EmptyPaneView, !empty.actions.isEmpty
            {
                let buttons = empty.buttonLayoutRects
                let union = buttons.reduce(CGRect.null) { $0.union($1) }
                toolbars[id] = ["rect": rect(ofLayout: empty, union), "buttons": .array(buttons.map { rect(ofLayout: empty, $0) })]
            }
            panes[id] = .object(entry)
        }
        var separators: [String: JSONValue] = [:]
        for split in controller.splitViews {
            let frames = split.childContentRects
            let whole = split.layoutFrame
            for index in frames.indices.dropFirst() {
                let frame = frames[index]
                let line =
                    split.direction == .horizontal
                    ? CGRect(x: frame.minX, y: whole.minY, width: 0, height: whole.height)
                    : CGRect(x: whole.minX, y: frame.minY, width: whole.width, height: 0)
                separators["\(split.nodeID.rawValue):\(index)"] = rect(line)
            }
        }
        var floating: [String: JSONValue] = [:]
        for view in root.floatingViews { floating[view.floatID.rawValue] = rect(view.layoutFrame) }
        var result: [String: JSONValue] = [
            "size": ["width": .double(size.width), "height": .double(size.height)],
            "panes": .object(panes), "tabBars": .object(bars), "controls": .object(controls), "separators": .object(separators),
            "floating": .object(floating), "emptyToolbars": .object(toolbars), "dockPreview": .null, "dockPreviewPane": .null,
            "emptyDropTarget": .null, "dragGhost": .null, "dragGhostText": .null, "dropIndicator": .null, "tooltip": .null,
        ]
        switch visuals.target {
        case .dock(let target, _)?:
            for tree in controller.trees {
                if let preview = tree.overlay.previewFrame {
                    result["dockPreview"] = rect(preview)
                    result["dockPreviewPane"] = .string(target.rawValue)
                }
            }
        case .emptyPane(let pane)?:
            result["emptyDropTarget"] = .string(pane.rawValue)
        case .tabBar(let group, _)?:
            if let indicator = controller.paneView(group)?.tabBar?.strip.dropIndicatorFrame {
                result["dropIndicator"] = rect(indicator)
            }
        case nil:
            break
        }
        if let palette = Palette.current(in: controller) { result["palette"] = paletteJSON(palette) }
        result["contextMenu"] =
            (root.overlay.subviews.first { $0 is ContextMenuBackdrop } as? ContextMenuBackdrop).map { rect($0.panelLayout) } ?? .null
        if let bubble = root.overlay.subviews.first(where: { $0 is TooltipBubble }) as? TooltipBubble {
            result["tooltip"] = ["rect": rect(bubble.layoutFrame), "text": .string(bubble.label)]
        }
        if let ghost = root.overlay.subviews.first(where: { $0 is DragGhostView && !$0.isHidden }) as? DragGhostView {
            result["dragGhost"] = rect(ghost.layoutFrame)
            result["dragGhostText"] = .string(ghost.title)
        }
        return .object(result)
    }

    /// The palette in the Electron capture's shape (`capture-electron.mjs`).
    private func paletteJSON(_ palette: PaletteView) -> JSONValue {
        let origin = palette.panelLayout.origin
        func absolute(_ local: CGRect) -> CGRect { local.offsetBy(dx: origin.x, dy: origin.y) }
        let rows = palette.rows
        var entries: [JSONValue] = []
        for (index, row) in rows.enumerated() {
            let parts = palette.parts(index)
            let text = PaletteView.text
            var entry: [String: JSONValue] = [
                "rect": rect(absolute(parts.row)), "highlighted": .bool(index == palette.highlighted), "badge": .null, "badgeText": .null,
                "badgeBaseline": .null, "icon": rect(absolute(parts.icon)), "text": .string(row.label),
                "label": rect(
                    absolute(
                        CGRect(
                            x: parts.label.minX, y: parts.label.minY, width: min(text.width(row.label), parts.label.width),
                            height: text.lineHeight))),
                "labelBaseline": number(origin.y + parts.labelBaseline),
            ]
            if let badge = parts.badge, let baseline = parts.badgeText {
                let digit = PaletteView.badgeText
                entry["badge"] = rect(absolute(badge))
                entry["badgeText"] = rect(
                    absolute(
                        CGRect(x: baseline.x, y: baseline.y - digit.ascent, width: digit.width(String(index + 1)), height: digit.lineHeight)
                    ))
                entry["badgeBaseline"] = number(origin.y + baseline.y)
            }
            entries.append(.object(entry))
        }
        var empty: JSONValue = .null
        if rows.isEmpty {
            let text = PaletteView.emptyText
            let inset = PaletteView.border + PaletteView.panelPadding + 10
            let lines = palette.emptyLines
            let top = inset
            empty = [
                "text": rect(
                    absolute(
                        CGRect(
                            x: inset, y: top, width: lines.map { text.width($0) }.max() ?? 0, height: CGFloat(lines.count) * text.lineHeight
                        ))),
                "baseline": number(origin.y + top + CGFloat(max(lines.count - 1, 0)) * text.lineHeight + text.ascent),
                "string": .string(NoContentTypes.message),
            ]
        }
        return [
            "step": .string(rows.isEmpty ? "empty" : palette.step.kind == 0 ? "type" : "placement"), "backdrop": rect(root.overlay.bounds),
            "panel": rect(palette.panelLayout), "rows": .array(entries), "empty": empty,
        ]
    }

    private func barJSON(_ bar: TabBarView) -> JSONValue {
        let text = TabView.text
        var tabs: [String: JSONValue] = [:]
        for tab in bar.strip.orderedTabs {
            let box = tab.layoutBox
            let label = tab.titleRect
            let lineTop = label.minY + (label.height - text.lineHeight) / 2 - 1
            let width = text.width(tab.title)
            var entry: JSONValue = [
                "rect": rect(ofLayout: tab, box),
                "title": rect(of: tab, CGRect(x: label.minX, y: lineTop, width: min(width, label.width), height: text.lineHeight)),
                "titleBox": rect(of: tab, CGRect(x: label.minX, y: lineTop, width: label.width, height: text.lineHeight)),
                "baseline": number(tab.convert(CGPoint(x: 0, y: lineTop + text.ascent), to: root).y),
                "text": .string(tab.title), "truncated": .bool(width > label.width + 0.01), "close": rect(of: tab, tab.closeRect),
                "active": .bool(tab.isActive), "dragging": .bool(controller.dragVisuals.sourceTab == tab.tabID),
            ]
            if case .object(var fields) = entry, let icons = signalIconsJSON(tab.signalIcons) {
                fields["signalIcons"] = icons
                entry = .object(fields)
            }
            tabs[tab.tabID.rawValue] = entry
        }
        let barRect = CGRect(x: 0, y: 0, width: bar.layoutSize.width, height: bar.barHeight)
        var fields: [String: JSONValue] = [
            "rect": rect(ofLayout: bar, barRect), "root": .bool(bar.pane.isDockedRoot), "strip": rect(of: bar.strip),
            "grip": bar.grip.isHidden ? .null : rect(of: bar.grip), "newTab": rect(of: bar.strip.newTabButton),
            "settings": bar.settingsButton.isHidden ? .null : rect(of: bar.settingsButton), "tabs": .object(tabs),
        ]
        // Only while caffeinate runs (absent otherwise, as in the Electron dump).
        if !bar.caffeinateButton.isHidden { fields["caffeinate"] = rect(of: bar.caffeinateButton) }
        return .object(fields)
    }

    /// Signal icons by kind (absent when there are none, as in the Electron dump).
    private func signalIconsJSON(_ icons: [SignalIconView]) -> JSONValue? {
        guard !icons.isEmpty else { return nil }
        var out: [String: JSONValue] = [:]
        for icon in icons { if let kind = icon.kindID { out[kind] = rect(of: icon) } }
        return .object(out)
    }

    private func controlsJSON(_ controls: HeaderControlsView, visible: Bool) -> JSONValue {
        var buttons: [String: JSONValue] = [:]
        for button in controls.groupButtons {
            if let first = button.items.first { buttons[first.action.testID] = rect(of: button) }
        }
        var dropdown: JSONValue = .null
        if let open = HeaderMenu.openDropdown, open.button.pane === controls.pane {
            var items: [String: JSONValue] = [:]
            for (index, item) in open.items.enumerated() {
                let id = index == 0 ? item.action.testID + "-menu-item" : item.action.testID
                items[id] = rect(of: open, open.rowFrame(index))
            }
            dropdown = ["rect": rect(of: open), "items": .object(items)]
        }
        return [
            "rect": rect(of: controls), "visible": .bool(visible), "buttons": .object(buttons),
            "separator": rect(of: controls.separatorView), "dropdown": dropdown,
        ]
    }
}

extension HeaderAction {
    /// The Electron app's test id for the button.
    var testID: String { accessibilityID }
}
#endif
