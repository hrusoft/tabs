#if DEBUG
import AppKit
import TabsCore
import TabsPluginSDK

/// `tabs.test.*`: control verbs that let an end-to-end test drive a running
/// app over the control socket — look at windows, click, type, press chords,
/// read a pane's state, quit. Debug builds only; they use the same
/// `InputSynthesizer` as the in-process UI tier.
@MainActor
enum TestControlVerbs {
    /// The verbs are stored on the runtime they drive, so they hold it (and
    /// the shell) weakly: otherwise a reset could never free the old ones.
    @MainActor
    private final class Targets {
        weak var runtime: CoreRuntime?
        weak var renderer: WorkspaceRenderer?
        weak var input: WorkspaceInput?

        init(runtime: CoreRuntime, renderer: WorkspaceRenderer, input: WorkspaceInput) {
            self.runtime = runtime
            self.renderer = renderer
            self.input = input
        }

        func workspace() throws -> WorkspaceRenderer {
            guard let renderer else { throw ControlVerbError("the workspace is gone (a reset is under way)") }
            return renderer
        }

        func core() throws -> CoreRuntime {
            guard let runtime else { throw ControlVerbError("core is gone (a reset is under way)") }
            return runtime
        }
    }

    static func register(on runtime: CoreRuntime, shell: AppShell, about: AboutPresenter, reset: @escaping @MainActor () -> Void) {
        let control = runtime.control
        let targets = Targets(runtime: runtime, renderer: shell.renderer, input: shell.input)
        weak let dialog = shell.caffeinateDialog
        registerCaffeinate(on: runtime, dialog: shell.caffeinateDialog)

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.reset",
                summary: "The state of a fresh launch, without relaunching: new core, plugins and windows on emptied data"
            ) { _ in
                reset()
                return nil
            })

        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.test.windows", summary: "Every window: its panes, the active and the focused one") { _ in
                let renderer = try targets.workspace()
                return .array(
                    renderer.windows.map { window in
                        let layout = window.layout
                        let encoded = (try? JSONValue(encoding: layout)) ?? .null
                        return [
                            "id": .string(window.windowID.rawValue),
                            "frontmost": .bool(window === renderer.frontmostController),
                            "title": .string(window.window?.title ?? ""),
                            "activePane": layout.activeLeafID.map { .string($0.rawValue) } ?? .null,
                            "activeNode": .string(layout.activePaneID.rawValue),
                            "focusedPane": focusedPane(in: window).map { .string($0.rawValue) } ?? .null,
                            "panes": .array(
                                layout.leaves.map { leaf in
                                    [
                                        "id": .string(leaf.id.rawValue),
                                        "type": leaf.type.map { .string($0.rawValue) } ?? .null,
                                        "title": .string(renderer.engine.paneTitle(of: leaf.id)),
                                        "live": .bool(renderer.engine.live(leaf.id) != nil),
                                        "visible": .bool(layout.isShowing(leaf.id)),
                                    ]
                                }),
                            "layout": encoded,
                        ]
                    })
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.click",
                summary:
                    "Click in the frontmost window, as a user would: a view by accessibility identifier (tab-<tab id>, "
                    + "pane-split-horizontal-button, tab-strip-new-tab-button, …), or an empty pane's creation button for a content type",
                arguments: [
                    ControlArgument(
                        "window", .string,
                        summary:
                            "\"about\" or \"caffeinate\": click in the About window or the Caffeinate dialog, not the frontmost workspace window"
                    ),
                    ControlArgument("identifier", .string, summary: "the view to click at its center"),
                    ControlArgument("create", .string, summary: "a content type: click the empty pane's button that creates it"),
                    ControlArgument(
                        "paneId", .string, summary: "look only inside this pane (for create: the empty pane; default the active one)"),
                ]
            ) { invocation in
                let renderer = try targets.workspace()
                if let name = invocation["window"]?.stringValue {
                    let auxiliary: NSWindow? =
                        switch name {
                        case "about": about.controller?.window
                        case "caffeinate": dialog?.controller?.window
                        default: throw ControlVerbError("no such window \(name)")
                        }
                    guard let window = auxiliary else { throw ControlVerbError("there is no \(name) window") }
                    guard let identifier = invocation["identifier"]?.stringValue else { throw ControlVerbError("give an identifier") }
                    do {
                        try InputSynthesizer.click(identifier, in: window, within: nil, input: targets.input)
                    } catch {
                        throw ControlVerbError(String(describing: error))
                    }
                    return nil
                }
                let window = try frontmost(renderer)
                let paneID = invocation["paneId"]?.stringValue.map { PaneID($0) }
                do {
                    if let type = invocation["create"]?.stringValue {
                        guard let id = paneID ?? renderer.frontmostController?.layout.activeLeafID, let body = renderer.body(for: id) else {
                            throw ControlVerbError("no pane to create in")
                        }
                        try InputSynthesizer.create(ContentTypeID(type), in: body, input: targets.input)
                    } else if let identifier = invocation["identifier"]?.stringValue {
                        let scope = try paneID.map { id in
                            // The whole pane: its header holds a plugin's title view.
                            guard let pane = renderer.windows.lazy.compactMap({ $0.paneView(id) }).first else {
                                throw ControlVerbError("no pane \(id)")
                            }
                            return pane
                        }
                        try InputSynthesizer.click(identifier, in: window, within: scope, input: targets.input)
                    } else {
                        throw ControlVerbError("give an identifier or a content type to create")
                    }
                } catch let error as ControlVerbError {
                    throw error
                } catch {
                    throw ControlVerbError(String(describing: error))
                }
                return nil
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.type", summary: "Type text into the focused view of the frontmost window (\\n is Return)",
                arguments: [ControlArgument("text", .string, required: true)]
            ) { invocation in
                InputSynthesizer.type(invocation["text"]?.stringValue ?? "", into: try frontmost(targets.workspace()))
                return nil
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.press",
                summary: "Press a chord in the frontmost window; returns whether a key equivalent (a menu item) handled it",
                arguments: [
                    ControlArgument(
                        "key", .string, required: true, summary: "a character, or return/tab/escape/delete/space/left/right/up/down/f1–f20"),
                    ControlArgument("modifiers", .array, summary: "command, shift, option, control"),
                ]
            ) { invocation in
                let chord = try chord(invocation["key"]?.stringValue ?? "", invocation["modifiers"])
                return .bool(InputSynthesizer.press(chord, in: try frontmost(targets.workspace()), input: targets.input))
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.menu",
                summary: "Choose a menu item by its title, as a click on it would: the first enabled match in any menu",
                arguments: [ControlArgument("title", .string, required: true)]
            ) { invocation in
                let title = invocation["title"]?.stringValue ?? ""
                func find(_ menu: NSMenu) -> (NSMenu, Int)? {
                    menu.update()
                    for (index, item) in menu.items.enumerated() {
                        if item.title == title, item.isEnabled, item.action != nil { return (menu, index) }
                        if let submenu = item.submenu, let found = find(submenu) { return found }
                    }
                    return nil
                }
                guard let main = NSApp.mainMenu, let (menu, index) = find(main) else {
                    throw ControlVerbError("no enabled menu item \(title)")
                }
                menu.performActionForItem(at: index)
                return nil
            })

        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.test.shownWindows", summary: "The titles of the app's windows on screen") { _ in
                .array(NSApp.windows.filter(\.isVisible).map { .string($0.title) })
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.about",
                summary:
                    "The About window as built (null when there is none): its title, size and traits, how many windows bear "
                    + "its title, every label, and each Copy button's title"
            ) { _ in
                guard let controller = about.controller, let window = controller.window else { return .null }
                let body = controller.body
                body.layoutSubtreeIfNeeded()
                let size = window.contentLayoutRect.size
                var copyTitles: [String: JSONValue] = [:]
                var addresses: [String: JSONValue] = [:]
                for entry in Donations.addresses {
                    copyTitles[entry.id] = .string(body.copyButton(entry.id)?.title ?? "")
                    addresses[entry.id] = .string(body.addressLabels[entry.id]?.stringValue ?? "")
                }
                return [
                    "title": .string(window.title),
                    "visible": .bool(window.isVisible),
                    "width": .double(size.width), "height": .double(size.height),
                    "resizable": .bool(window.styleMask.contains(.resizable)),
                    "zoomable": .bool(window.standardWindowButton(.zoomButton)?.isEnabled ?? false),
                    "fullScreenAllowed": .bool(!window.collectionBehavior.contains(.fullScreenNone)),
                    "hasParent": .bool(window.parent != nil),
                    "windows": .int(Int64(NSApp.windows.filter { $0.title == AboutCopy.windowTitle }.count)),
                    "texts": .array(body.texts.map { .string($0) }),
                    "copyTitles": .object(copyTitles),
                    "addresses": .object(addresses),
                ]
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.paneConfig", summary: "A live pane's state, as core would save it now",
                arguments: [ControlArgument("paneId", .string, required: true)]
            ) { invocation in
                let runtime = try targets.core()
                let id = PaneID(invocation["paneId"]?.stringValue ?? "")
                guard let pane = runtime.panes.pane(id) else { throw ControlVerbError("no live pane \(id)") }
                return runtime.panes.snapshot(pane).config
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.signals",
                summary:
                    "Pane signals as drawn: per window, each visible pane's header icons and outline, each tab's icons (with the "
                    + "leaves it holds); every pane's raised signals; how many times the Dock was asked to bounce"
            ) { _ in
                let renderer = try targets.workspace()
                let signals = try targets.core().signals
                @MainActor func kinds(_ icons: [SignalIconView]) -> JSONValue {
                    var ids: [JSONValue] = []
                    for icon in icons.sorted(by: { $0.frame.minX < $1.frame.minX }) { if let id = icon.kindID { ids.append(.string(id)) } }
                    return .array(ids)
                }
                var raised: [String: JSONValue] = [:]
                for pane in signals.panes.sorted() { raised[pane.rawValue] = .array(signals.raised(on: pane).map { .string($0.id) }) }
                return [
                    "attentionRequests": .int(Int64(renderer.attentionRequests)),
                    "raised": .object(raised),
                    "windows": .array(
                        renderer.windows.map { window in
                            window.root.layoutSubtreeIfNeeded()
                            var panes: [String: JSONValue] = [:]
                            var tabs: [String: JSONValue] = [:]
                            for leaf in window.layout.leaves where window.layout.isShowing(leaf.id) {
                                guard let view = window.paneView(leaf.id), let header = view.header else { continue }
                                let outline = window.trees.lazy.compactMap { $0.overlay.signalOutlines[leaf.id] }.first
                                panes[leaf.id.rawValue] = [
                                    "header": kinds(header.signalIcons),
                                    "outline": outline?.shown.map { .string($0.kind.id) } ?? .null,
                                ]
                            }
                            for tree in window.layout.trees {
                                for group in groups(in: tree) {
                                    guard let bar = window.paneView(group.id)?.tabBar else { continue }
                                    for tab in group.tabs {
                                        guard let view = bar.strip.tabView(tab.id) else { continue }
                                        tabs[tab.id.rawValue] = [
                                            "leaves": .array(tab.content.leaves.map { .string($0.id.rawValue) }),
                                            "signals": kinds(view.signalIcons),
                                        ]
                                    }
                                }
                            }
                            return [
                                "id": .string(window.windowID.rawValue), "panes": .object(panes), "tabs": .object(tabs),
                            ]
                        }),
                ]
            })

        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.paneSettings",
                summary: "Merge fields into core's pane settings (core.panes), as Settings ▸ Panes & Tabs would; returns them all",
                arguments: [ControlArgument("set", .object, summary: "e.g. {\"persistLayoutOnExit\": false}")]
            ) { invocation in
                let settings = try targets.core().settings
                guard case .object(var fields) = try JSONValue(encoding: settings.panes) else { throw ControlVerbError("unencodable") }
                if case .object(let changes)? = invocation["set"] { fields.merge(changes) { _, new in new } }
                let merged = try JSONDecoder().decode(
                    SettingsStore.PaneSettings.self, from: JSONValue.object(fields).encodedData(pretty: false))
                settings.setPanes(merged)
                return try JSONValue(encoding: settings.panes)
            })

        control.addCoreVerb(
            ControlVerbContribution(name: "tabs.test.quit", summary: "Quit normally (saving), right after answering") { _ in
                // The main actor's next turn: the answer is on its way by then, and may still
                // lose the race to the quit, which closes the socket; a test takes either as the quit.
                Task { @MainActor in NSApp.terminate(nil) }
                return nil
            })
    }

    /// `tabs.test.caffeinate*`: the managed process and the dialog, as a test
    /// needs them.
    private static func registerCaffeinate(on runtime: CoreRuntime, dialog presenter: CaffeinateDialogPresenter) {
        let control = runtime.control
        weak let caffeinate = runtime.caffeinate
        weak let presenter = presenter
        let flagNames: [(String, WritableKeyPath<CaffeinateFlags, Bool>)] = [
            ("display", \.preventDisplaySleep), ("idle", \.preventIdleSleep), ("disk", \.preventDiskSleep),
            ("system", \.preventSystemSleep), ("active", \.declareUserActive),
        ]
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.caffeinate",
                summary:
                    "The managed caffeinate process (running, its OS pid) and the Caffeinate dialog as built (null when there is "
                    + "none): its title, size and traits, how many windows bear its title, its switches and timer text"
            ) { _ in
                guard let caffeinate else { throw ControlVerbError("core is gone (a reset is under way)") }
                var dialog: JSONValue = .null
                if let controller = presenter?.controller, let window = controller.window {
                    window.contentView?.layoutSubtreeIfNeeded()
                    var flags: [String: JSONValue] = [:]
                    for (name, flag) in flagNames { flags[name] = .bool(controller.model.flags[keyPath: flag]) }
                    let size = window.contentLayoutRect.size
                    dialog = [
                        "title": .string(window.title),
                        "visible": .bool(window.isVisible),
                        "width": .double(size.width), "height": .double(size.height),
                        "resizable": .bool(window.styleMask.contains(.resizable)),
                        "miniaturizable": .bool(window.styleMask.contains(.miniaturizable)),
                        "fullScreenAllowed": .bool(!window.collectionBehavior.contains(.fullScreenNone)),
                        "hasParent": .bool(window.parent != nil),
                        "windows": .int(Int64(NSApp.windows.filter { $0.title == CaffeinateCopy.windowTitle }.count)),
                        "flags": .object(flags),
                        "timer": .string(controller.model.timerText),
                    ]
                }
                return [
                    "running": .bool(caffeinate.isRunning),
                    "pid": caffeinate.pid.map { .int(Int64($0)) } ?? .null,
                    "dialog": dialog,
                ]
            })
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.startCaffeinate",
                summary: "Start the managed caffeinate process directly, bypassing the dialog (a no-op if one runs)",
                arguments: flagNames.map { ControlArgument($0.0, .bool) } + [
                    ControlArgument("timerSeconds", .number, summary: "-t, in seconds (the dialog only offers minutes)")
                ]
            ) { invocation in
                guard let caffeinate else { throw ControlVerbError("core is gone (a reset is under way)") }
                var flags = CaffeinateFlags()
                for (name, flag) in flagNames { flags[keyPath: flag] = invocation[name] == true }
                flags.timerSeconds = invocation["timerSeconds"]?.doubleValue
                caffeinate.start(flags)
                return nil
            })
        control.addCoreVerb(
            ControlVerbContribution(
                name: "tabs.test.caffeinateDialog",
                summary: "Set the open Caffeinate dialog's fields, as the user would: switches by name, and the timer's text",
                arguments: flagNames.map { ControlArgument($0.0, .bool) } + [
                    ControlArgument("timer", .string, summary: "minutes, as typed")
                ]
            ) { invocation in
                guard let model = presenter?.controller?.model else { throw ControlVerbError("there is no Caffeinate dialog") }
                for (name, flag) in flagNames {
                    if let value = invocation[name], value != .null { model.flags[keyPath: flag] = value == true }
                }
                if let text = invocation["timer"]?.stringValue { model.timerText = text }
                return nil
            })
    }

    /// Every tab group in a tree, outer ones first.
    private static func groups(in node: LayoutNode) -> [TabGroup] {
        switch node {
        case .leaf: []
        case .tabs(let group): [group] + group.tabs.flatMap { groups(in: $0.content) }
        case .split(let split): split.children.flatMap { groups(in: $0) }
        }
    }

    /// The pane whose body holds the window's first responder.
    private static func focusedPane(in window: WorkspaceWindowController) -> PaneID? {
        var view = window.window?.firstResponder as? NSView
        while let current = view {
            if let body = current as? PaneBodyHost { return body.paneID }
            view = current.superview
        }
        return nil
    }

    private static func frontmost(_ renderer: WorkspaceRenderer) throws -> NSWindow {
        guard let window = renderer.frontmostController?.window else { throw ControlVerbError("no workspace window") }
        return window
    }

    private static func chord(_ key: String, _ modifiers: JSONValue?) throws -> KeyChord {
        var flags: KeyChord.Modifiers = []
        if case .array(let names)? = modifiers {
            for name in names {
                switch name.stringValue {
                case "command", "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option", "alt": flags.insert(.option)
                case "control", "ctrl": flags.insert(.control)
                default: throw ControlVerbError("unknown modifier \(name)")
                }
            }
        }
        let named: [String: KeyChord.Key] = [
            "return": .return, "tab": .tab, "escape": .escape, "delete": .delete, "space": .space,
            "left": .arrow(.left), "right": .arrow(.right), "up": .arrow(.up), "down": .arrow(.down),
        ]
        if let special = named[key] { return KeyChord(special, flags) }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number) { return KeyChord(.function(number), flags) }
        guard key.count == 1, let character = key.first else { throw ControlVerbError("unknown key \"\(key)\"") }
        return KeyChord(character, flags)
    }
}
#endif
