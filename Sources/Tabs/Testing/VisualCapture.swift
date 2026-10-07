#if DEBUG
import AppKit
import TabsCore
import TabsPluginSDK

/// `Tabs --render-scenarios <dir> [--render-scenarios <dir> …] --out <dir>
/// [names…]` (Debug builds): the look scenarios (`Visual/`, and each plugin's
/// `Plugins/<Name>/Visual/`). Each scenario's layout goes through the real
/// engine and renderer in a window that is never shown, with the scenario's
/// hover or drag applied, and comes out as `<name>.png` (the content area at
/// 2x) and `<name>.geometry.json` (`GeometryDump`).
///
/// A pane's content is its plugin's business, reached through Debug verbs
/// named after the plugin (`<owner>`, the plugin owning the pane's content
/// type): `<owner>.test.stage` shows the scenario's `content` entry for the
/// pane, `<owner>.test.visual` measures it, `<owner>.test.snapshot` draws what
/// the layer tree can't (a view whose content lives in another process).
@MainActor
enum VisualCapture {
    static func arguments(_ arguments: [String]) -> (scenarios: [URL], out: URL, names: [String])? {
        guard let out = arguments.firstIndex(of: "--out"), arguments.indices.contains(out + 1) else { return nil }
        var directories: [URL] = []
        var names: [String] = []
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--render-scenarios" || argument == "--out" {
                guard arguments.indices.contains(index + 1) else { return nil }
                if argument == "--render-scenarios" { directories.append(URL(filePath: arguments[index + 1])) }
                index += 2
            } else {
                if !argument.hasPrefix("-") { names.append(argument) }
                index += 1
            }
        }
        guard !directories.isEmpty else { return nil }
        return (directories, URL(filePath: arguments[out + 1]), names)
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
        /// Extra stub types after the stub ("▣") that the palette lists
        /// ("Sample 2"…), for a list longer than nine rows.
        var paletteTypes: Int?
        /// Signals to put on panes, by pane id: `bell` and `controlled`
        /// (`SignalFixtures`).
        var signals: [String: [String]]?
        /// Freezes every pulse this many seconds in; nil: the peak (opacity 1).
        var pulse: Double?
        /// Each plugin pane's content as its plugin stages it, by pane id: the
        /// entry goes to `<owner>.test.stage`; the pane is then measured
        /// (`<owner>.test.visual`, the geometry's `content` block) and, in a
        /// picture, drawn by its plugin (`<owner>.test.snapshot`) if it says how.
        var content: [String: JSONValue]?
        /// Content types, besides the stub, that an empty pane offers.
        var creationActions: [String]?
    }

    static func decodeScenario(_ data: Data) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: data)
    }

    /// The scenario files in `directories`, by name. A name in two directories is an error: the
    /// captures and goldens are keyed by name.
    static func scenarioFiles(in directories: [URL]) throws -> [String: URL] {
        var files: [String: URL] = [:]
        for directory in directories {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                if let other = files[name] { throw Failure("\(name) is both \(other.path) and \(file.path)") }
                files[name] = file
            }
        }
        return files
    }

    static func run(scenarios: [URL], out: URL, names: [String]) async -> Int32 {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let found: [String: URL]
        do {
            found = try scenarioFiles(in: scenarios)
        } catch {
            print("failed: \(error)")
            return 1
        }
        let files = found.sorted { $0.key < $1.key }.map(\.value)
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
        try render(staged.controller.root, pages: await staged.contentSnapshots()).write(to: out.appending(path: "\(name).png"))
        try await staged.geometryWithContent().encodedData().write(to: out.appending(path: "\(name).geometry.json"))
    }

    /// A scenario on screen (in a window that's never shown): its layout,
    /// settings, and any hover, right-click or drag applied and settled.
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

        /// The geometry (`GeometryDump`).
        func geometry() -> JSONValue {
            controller.root.layoutSubtreeIfNeeded()
            return GeometryDump(controller: controller, renderer: renderer, size: scenario.size).json()
        }

        /// The plugin owning a leaf's content type, if the leaf has one.
        func owner(of pane: String) -> PluginID? {
            engine.model.leaf(PaneID(pane))?.type.flatMap { runtime.registry.contribution(to: .contentTypes, id: $0.rawValue)?.owner }
        }

        /// The Debug verb `<owner>.test.<name>` for a leaf's content, if its plugin declares it.
        func contentVerb(_ name: String, of pane: String) -> String? {
            guard let owner = owner(of: pane) else { return nil }
            let verb = "\(owner.rawValue).test.\(name)"
            return runtime.control.verbs().contains { $0.verb.name == verb } ? verb : nil
        }

        /// Runs a leaf's content verb; its result, or the failure.
        func callContentVerb(_ verb: String, on pane: String, _ arguments: JSONValue = .emptyObject) async throws -> JSONValue {
            let answer = await runtime.control.handle(.init(command: verb, arguments: arguments, targetPane: PaneID(pane)))
            guard answer["ok"] == .bool(true) else { throw Failure("\(verb) on \(pane): \(answer)") }
            return answer["result"] ?? .null
        }

        /// The geometry plus the `content` block: each staged pane as its plugin
        /// measures it (`<owner>.test.visual`), in the header title view's
        /// coordinates (`title`) and the pane body's (`body`), offset here to
        /// the window's.
        func geometryWithContent() async throws -> JSONValue {
            var geometry = geometry()
            var block: [String: JSONValue] = [:]
            for pane in (scenario.content ?? [:]).keys.sorted() {
                guard let verb = contentVerb("visual", of: pane) else { continue }
                let measured = try await callContentVerb(verb, on: pane)
                var placed: [String: JSONValue] = [:]
                if let body = measured["body"] {
                    guard let rect = geometry["panes"]?[pane]?["body"], let x = rect[0]?.doubleValue, let y = rect[1]?.doubleValue,
                        case .object(let fields) = Self.offset(body, by: CGPoint(x: x, y: y))
                    else { throw Failure("\(verb): \(pane) has no body to place its geometry in") }
                    placed.merge(fields) { $1 }
                }
                if let title = measured["title"] {
                    guard let view = controller.paneView(NodeID(pane))?.header?.titleView,
                        case .object(let fields) = Self.offset(title, by: view.convert(NSPoint.zero, to: controller.root))
                    else { throw Failure("\(verb): \(pane) has no header title to place its geometry in") }
                    placed.merge(fields) { $1 }
                }
                block[pane] = .object(placed)
            }
            if !block.isEmpty, case .object(var object) = geometry {
                object["content"] = .object(block)
                geometry = .object(object)
            }
            return geometry
        }

        /// The pixels of what the layer tree can't render (a web view's page
        /// lives in another process): each staged pane whose plugin draws it
        /// (`<owner>.test.snapshot`, a 2x PNG), to stand in for its view's layer.
        func contentSnapshots() async throws -> [(CALayer, CGImage)] {
            var out: [(CALayer, CGImage)] = []
            for pane in (scenario.content ?? [:]).keys.sorted() {
                guard let verb = contentVerb("snapshot", of: pane), let view = renderer.body(for: PaneID(pane))?.content,
                    view.window != nil, view.bounds.width > 0, view.bounds.height > 0, let layer = view.layer
                else { continue }
                let file = data.appending(path: "snapshot-\(pane).png")
                _ = try await callContentVerb(verb, on: pane, ["path": .string(file.path)])
                guard var image = (try? Data(contentsOf: file)).flatMap(NSBitmapImageRep.init(data:))?.cgImage else {
                    throw Failure("\(verb) on \(pane) wrote no picture")
                }
                // `CALayer.render(in:)` ignores a layer's Core Image filters, and a
                // snapshot is the view before them: an inactive pane's dimming
                // (`PaneBodyHost.applyDim`) is applied here.
                if let filters = layer.filters as? [CIFilter], !filters.isEmpty {
                    var filtered = CIImage(cgImage: image)
                    for filter in filters {
                        filter.setValue(filtered, forKey: kCIInputImageKey)
                        guard let next = filter.outputImage else { throw Failure("dimming \(pane)") }
                        filtered = next
                    }
                    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
                    guard let rendered = context.createCGImage(filtered, from: CIImage(cgImage: image).extent) else {
                        throw Failure("dimming \(pane)")
                    }
                    image = rendered
                }
                out.append((layer, image))
            }
            return out
        }

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
            engine.tearDown()
            runtime.host.stop()
            try? FileManager.default.removeItem(at: data)
        }
    }

    static func stage(_ scenario: Scenario) async throws -> Staged {
        // A `.noindex` folder, which Spotlight skips: a run of the goldens stages one per scenario.
        let data = FileManager.default.temporaryDirectory.appending(
            path: "tabs-visual-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if let plugins = scenario.settings?["plugins"] {
            // The plugins' own settings, as the scenario gives them.
            let settingsFile: JSONValue = ["version": 1, "plugins": plugins]
            try settingsFile.encodedData().write(to: data.appending(path: "settings.json"))
        }
        let runtime = CoreRuntime(paths: AppPaths(dataDirectory: data), readOnly: true)
        // The plugins, only when the scenario shows or offers a type of theirs.
        let required = SavedLayout(windows: [scenario.layout.window]).contentTypes
            .union((scenario.creationActions ?? []).map { ContentTypeID($0) })
        if !required.isEmpty { runtime.startBundledPlugins(of: .main, requiredContentTypes: required) }
        let engine = LayoutEngine(runtime: runtime)
        let renderer = WorkspaceRenderer(runtime: runtime, engine: engine, presentsWindows: false)
        // Empty panes offer one stub content type ("▣"), after any type the
        // scenario asks for.
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
        // Nothing is offered for a type the scenario turned off.
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
        // No window corner radius: the captures are square.
        appearance.cornerRadius = 0
        appearance.caffeinateRunning = scenario.caffeinate == true
        renderer.baseAppearance = appearance
        // Pulses freeze where the scenario says.
        SignalPulse.frozenTime = scenario.pulse
        // The hover fades end at once: nothing below waits for them.
        ChromeFade.isInstant = true
        defer { ChromeFade.isInstant = false }

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
            // Raised while their switches are on; the scenario's settings may
            // then hide them.
            SignalFixtures.declare(in: runtime.signals)
            for (pane, kinds) in signals.sorted(by: { $0.key < $1.key }) {
                for kind in kinds { runtime.signals.raise(PaneSignal(kind), on: PaneID(pane), by: nil) }
            }
            var panes = runtime.settings.panes
            if case .bool(false)? = settings["enableBellIndicator"] { panes.disabledSignals.append(SignalFixtures.bellID) }
            if case .bool(false)? = settings["enableControlIndicator"] { panes.disabledSignals.append(SignalFixtures.controlledID) }
            runtime.settings.setPanes(panes)
        }
        for (pane, spec) in (scenario.content ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let verb = staged.contentVerb("stage", of: pane) else {
                let wanted = staged.owner(of: pane).map { "no verb \($0.rawValue).test.stage" } ?? "not a plugin's pane"
                throw Failure("\(pane): nothing stages its content (\(wanted))")
            }
            _ = try await staged.callContentVerb(verb, on: pane, ["spec": spec])
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
        // What would settle by itself settles now, without waiting for it: the
        // resize's reclamp of floating panes (its timer), then what's queued for
        // the next turn (capability events). Spring loading takes longer than a
        // capture ever waited, so no scenario shows it.
        controller.reclampNow()
        try? await Task.sleep(for: .milliseconds(10))
        controller.root.layoutSubtreeIfNeeded()
        return staged
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The root view's layer tree at 2x, opaque sRGB; each of `pages` stands in
    /// for a layer the tree renders blank.
    static func render(_ view: NSView, pages: [(CALayer, CGImage)] = []) throws -> Data {
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
        // Each snapshot replaces the layer tree's own rendering of the view
        // (its hosted remote layers, drawn undimmed and unfiltered) while the
        // tree renders, so what core draws over it (the controlled pane's glow)
        // composites over it as on screen.
        var restore: [() -> Void] = []
        for (layer, page) in pages {
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

    /// The palette as the scenario asks for it: opened by its chord, the
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
                // A plugin's header title (its own controls) hears the pointer
                // arrive, as its tracking area would tell it.
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

/// The on-screen geometry (`Visual/README.md`): content coordinates, top-left
/// origin, points.
@MainActor
struct GeometryDump {
    let controller: WorkspaceWindowController
    let renderer: WorkspaceRenderer
    let size: VisualCapture.Scenario.Size

    private var root: WindowRootView { controller.root }

    private func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .double(($0 * 100).rounded() / 100) })
    }

    /// A view's layout rect (unsnapped), or a rect in its drawing coordinates.
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
            "emptyDropTarget": .null, "dragGhost": .null, "dragGhostText": .null, "dropIndicator": .null,
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
        if let ghost = root.overlay.subviews.first(where: { $0 is DragGhostView && !$0.isHidden }) as? DragGhostView {
            result["dragGhost"] = rect(ghost.layoutFrame)
            result["dragGhostText"] = .string(ghost.title)
        }
        return .object(result)
    }

    /// The palette: its panel, rows and empty state.
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
        // Only while caffeinate runs (absent otherwise).
        if !bar.caffeinateButton.isHidden { fields["caffeinate"] = rect(of: bar.caffeinateButton) }
        return .object(fields)
    }

    /// Signal icons by kind (absent when there are none).
    private func signalIconsJSON(_ icons: [SignalIconView]) -> JSONValue? {
        guard !icons.isEmpty else { return nil }
        var out: [String: JSONValue] = [:]
        for icon in icons { if let kind = icon.kindID { out[kind] = rect(of: icon) } }
        return .object(out)
    }

    private func controlsJSON(_ controls: HeaderControlsView, visible: Bool) -> JSONValue {
        var buttons: [String: JSONValue] = [:]
        for button in controls.groupButtons {
            if let first = button.items.first { buttons[first.action.accessibilityID] = rect(of: button) }
        }
        var dropdown: JSONValue = .null
        if let open = HeaderMenu.openDropdown, open.button.pane === controls.pane {
            var items: [String: JSONValue] = [:]
            for (index, item) in open.items.enumerated() {
                let id = index == 0 ? item.action.accessibilityID + "-menu-item" : item.action.accessibilityID
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

#endif
