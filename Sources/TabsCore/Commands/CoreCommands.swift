import TabsPluginSDK

/// One of core's own commands: the shell's menu items. They share the
/// shortcut table with plugin commands, so the user can rebind them too and a
/// plugin's default chord can never take theirs — except the fixed ones.
package struct CoreCommand: Sendable {
    /// Where Settings ▸ Keyboard lists a core command.
    package enum Group: String, Sendable {
        case application = "Application"
        case panesAndTabs = "Panes & Tabs"
        case navigation = "Navigation"
    }

    package let id: CommandID
    /// The menu item's title.
    package let title: String
    package let defaultChord: KeyChord?
    /// How Settings ▸ Keyboard names it.
    package let label: String
    /// Settings ▸ Keyboard's line about it.
    package let summary: String
    /// Its group on Settings ▸ Keyboard; nil for a fixed command.
    package let group: Group?

    /// A stock item (Quit, Copy…): its chord is the system's, so it isn't
    /// listed on Settings ▸ Keyboard, the user can't rebind it, and nothing else
    /// may take its chord (`Shortcuts.reserved`).
    package var isFixed: Bool { group == nil }

    init(_ id: CommandID, _ title: String, _ defaultChord: KeyChord? = nil, label: String? = nil, _ group: Group, _ summary: String) {
        self.id = id
        self.title = title
        self.defaultChord = defaultChord
        self.label = label ?? title
        self.summary = summary
        self.group = group
    }

    init(fixed id: CommandID, _ title: String, _ defaultChord: KeyChord) {
        self.id = id
        self.title = title
        self.defaultChord = defaultChord
        label = title
        summary = ""
        group = nil
    }
}

package enum CoreCommands {
    package static let settings = CoreCommand(
        "tabs.settings", "Settings…", KeyChord(",", [.command]), label: "Open Settings", .application, "Open the Settings window.")
    package static let plugins = CoreCommand("tabs.plugins", "Plugins…", label: "Open Plugins", .application, "Open the Plugins window.")
    package static let hide = CoreCommand(fixed: "tabs.hide", "Hide Tabs", KeyChord("h", [.command]))
    package static let hideOthers = CoreCommand(fixed: "tabs.hideOthers", "Hide Others", KeyChord("h", [.command, .option]))
    package static let quit = CoreCommand(fixed: "tabs.quit", "Quit Tabs", KeyChord("q", [.command]))
    package static let newWindow = CoreCommand(
        "tabs.newWindow", "New Window", KeyChord("n", [.command]), .application,
        "Open another pane-tree window, with its own independent layout.")
    /// File ▸ Caffeinate… — "Decaf" while the process runs (the menu relabels
    /// it). No default chord: opt-in, not a shortcut waiting for one.
    package static let caffeinate = CoreCommand(
        "tabs.caffeinate", "Caffeinate…", nil, .application,
        "Open the Caffeinate dialog to keep the Mac awake, or turn it off if already running.")
    /// ⌘P: the palette that picks a content type, then where to put it.
    package static let commandPalette = CoreCommand(
        "tabs.commandPalette", "New Content…", KeyChord("p", [.command]), .panesAndTabs,
        "Open the command palette for creating new content.")
    package static let newTab = CoreCommand(
        "tabs.newTab", "New Tab", KeyChord("t", [.command]), .panesAndTabs, "Open a new tab in the active pane.")
    package static let splitHorizontal = CoreCommand(
        "tabs.splitHorizontal", "New Horizontal Split", KeyChord("t", [.command, .shift]), .panesAndTabs,
        "Split the active pane horizontally with new content.")
    package static let splitVertical = CoreCommand(
        "tabs.splitVertical", "New Vertical Split", KeyChord("t", [.command, .option]), .panesAndTabs,
        "Split the active pane vertically with new content.")
    package static let newUnpinnedPane = CoreCommand(
        "tabs.newUnpinnedPane", "New Unpinned Pane", KeyChord("t", [.command, .option, .shift]), .panesAndTabs,
        "Open a new floating, unpinned pane over the active pane, in the position set in Settings.")
    package static let closePane = CoreCommand(
        "tabs.closePane", "Close Pane", KeyChord("w", [.command]), .panesAndTabs,
        "Close the active pane, confirming first if it still has work running.")
    /// Pane focus, one step through the layout. Not menu items: a menu takes
    /// its keys before a text field could, and these belong to text editing there.
    package static let navLeft = CoreCommand(
        "tabs.navLeft", "Focus Pane Left", KeyChord(.arrow(.left), [.command]), .navigation, "Move pane focus one step left.")
    package static let navRight = CoreCommand(
        "tabs.navRight", "Focus Pane Right", KeyChord(.arrow(.right), [.command]), .navigation, "Move pane focus one step right.")
    package static let navUp = CoreCommand(
        "tabs.navUp", "Focus Pane Up", KeyChord(.arrow(.up), [.command]), .navigation, "Move pane focus one step up.")
    package static let navDown = CoreCommand(
        "tabs.navDown", "Focus Pane Down", KeyChord(.arrow(.down), [.command]), .navigation, "Move pane focus one step down.")
    package static let undo = CoreCommand(fixed: "tabs.undo", "Undo", KeyChord("z", [.command]))
    package static let redo = CoreCommand(fixed: "tabs.redo", "Redo", KeyChord("z", [.command, .shift]))
    package static let cut = CoreCommand(fixed: "tabs.cut", "Cut", KeyChord("x", [.command]))
    package static let copy = CoreCommand(fixed: "tabs.copy", "Copy", KeyChord("c", [.command]))
    package static let paste = CoreCommand(fixed: "tabs.paste", "Paste", KeyChord("v", [.command]))
    package static let selectAll = CoreCommand(fixed: "tabs.selectAll", "Select All", KeyChord("a", [.command]))
    package static let minimize = CoreCommand(fixed: "tabs.minimize", "Minimize", KeyChord("m", [.command]))

    package static let all: [CoreCommand] = [
        settings, plugins, hide, hideOthers, quit, newWindow, caffeinate, commandPalette, newTab, splitHorizontal, splitVertical,
        newUnpinnedPane,
        closePane,
        navLeft, navRight, navUp, navDown, undo, redo, cut, copy, paste, selectAll, minimize,
    ]
}
