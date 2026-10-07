import AppKit
import SwiftUI
import TabsCore
import TabsPluginSDK

/// Settings ▸ Keyboard: every command the user can rebind, with a recorder for a new
/// combination, a search box that also takes a pressed combination, and Clear, Reset and
/// Restore Defaults, on core's shortcut table and its rules (docs/KEYBOARD.md).
@MainActor
@Observable
final class KeyboardSettingsModel {
    /// One line of feedback under a row's title, replacing its description until the next
    /// interaction.
    struct Notice: Equatable {
        enum Tone { case error, info }
        let command: CommandID
        let text: String
        let tone: Tone
    }

    /// A group of rows as the page shows it.
    struct Group: Identifiable {
        let id: String
        let bindings: [Shortcuts.Binding]
    }

    /// Every command's binding, fixed ones included (the page never shows those).
    private(set) var bindings: [Shortcuts.Binding]
    /// The command whose chip is recording, if any.
    private(set) var capturing: CommandID?
    /// The modifiers held while recording ("⌃⌥"), until a key completes the combination.
    private(set) var preview = ""
    private(set) var notice: Notice?
    var query = ""
    @ObservationIgnored let shortcuts: Shortcuts
    @ObservationIgnored private var subscription: Subscription?

    init(shortcuts: Shortcuts) {
        self.shortcuts = shortcuts
        bindings = shortcuts.bindings
        subscription = shortcuts.observeChanges { [weak self, unowned shortcuts] in self?.bindings = shortcuts.bindings }
    }

    /// The rows the query shows, by group (`ShortcutText.visibleGroups`).
    var groups: [Group] {
        ShortcutText.visibleGroups(query, in: bindings).map { Group(id: $0.group, bindings: $0.bindings) }
    }

    func binding(_ command: CommandID) -> Shortcuts.Binding? { bindings.first { $0.command == command } }

    /// What a row's chip reads: the chord, "Not set", or while recording the held modifiers or
    /// "Press keys…".
    func chipTitle(_ binding: Shortcuts.Binding) -> String {
        guard capturing == binding.command else { return ShortcutText.formatBinding(binding.chord) }
        return preview.isEmpty ? "Press keys…" : preview
    }

    /// The line under a row's title: its notice, else its description.
    func detail(of binding: Shortcuts.Binding) -> (text: String, tone: Notice.Tone?) {
        if let notice, notice.command == binding.command { return (notice.text, notice.tone) }
        return (binding.summary ?? "", nil)
    }

    /// Why a row doesn't have the chord it would otherwise have, when core's rules explain it:
    /// its chord is another command's for now, or a stored one can't be used.
    func explanation(of binding: Shortcuts.Binding) -> String? {
        switch binding.reason {
        case .takenBy(let holder, let chord):
            "\(ShortcutText.formatBinding(chord)) is taken by \(self.binding(holder)?.label ?? holder.rawValue)."
        case .unusable(let stored): "Your shortcut “\(stored)” can’t be used here, so it has its default."
        case .unboundByUser, .fixed, nil: nil
        }
    }

    // MARK: Recording

    /// Clicking a chip: records into it, or stops if it was already recording.
    func startCapture(_ command: CommandID) {
        notice = nil
        preview = ""
        capturing = capturing == command ? nil : command
    }

    func cancelCapture() {
        capturing = nil
        preview = ""
    }

    /// Modifiers held or released while recording.
    func holding(_ modifiers: KeyChord.Modifiers) {
        guard capturing != nil else { return }
        preview = ShortcutText.formatModifiers(modifiers)
    }

    /// A combination pressed while `command`'s chip records (nil: a key that has no chord).
    /// Refused, it stays armed — a correction, not a cancel; recorded, it takes the chord from
    /// whatever held it, and says so.
    func commit(_ command: CommandID, _ chord: KeyChord?) {
        guard let binding = binding(command) else { return }
        func refuse(_ text: String) { notice = Notice(command: command, text: text, tone: .error) }
        guard let chord, ShortcutText.isRecordable(chord.key) else { return refuse("That key cannot be used as a shortcut.") }
        if let problem = Shortcuts.userProblem(with: chord, scope: binding.scope) {
            switch problem {
            case .malformed: return refuse("That key cannot be used as a shortcut.")
            case .needsModifier: return refuse("Add ⌘ or ⌃ to the combination.")
            case .needsCommand: return refuse("Add ⌘ to the combination: ⌃ alone is left to the pane you’re typing in.")
            case .reserved: return refuse("\(ShortcutText.formatBinding(chord)) is reserved by the system.")
            }
        }
        let holders = shortcuts.holders(of: chord, for: command)
        do {
            try shortcuts.bind(command, to: chord)
        } catch {
            return refuse(error.description)
        }
        cancelCapture()
        if !holders.isEmpty {
            notice = Notice(command: command, text: "Taken from \(Self.list(holders.map(\.label))).", tone: .info)
        } else if ShortcutText.isBareCtrlLetterChord(chord), let type = binding.scopeName {
            // A ⌃ letter armed for a pane type no longer reaches those panes as typing.
            notice = Notice(
                command: command, text: "\(ShortcutText.formatBinding(chord)) is also used inside \(type) panes.", tone: .info)
        } else {
            notice = nil
        }
    }

    // MARK: Clear, Reset, Restore Defaults

    /// An explicit unbinding: the row reads "Not set" and offers Reset.
    func clear(_ command: CommandID) { settle { try? shortcuts.bind(command, to: nil) } }

    func reset(_ command: CommandID) { settle { try? shortcuts.reset(command) } }

    func restoreDefaults() { settle { try? shortcuts.resetAll() } }

    /// The search field took the keyboard: a chip's recording ends, or it would take the
    /// typing.
    func searchDidFocus() { cancelCapture() }

    /// Every change that isn't a recording settles the recorder first.
    private func settle(_ apply: () -> Void) {
        notice = nil
        cancelCapture()
        apply()
    }

    /// "A", "A and B", "A, B and C".
    private static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// The page's keyboard. While a chip records, every key in the Settings window goes to it,
/// even one the main menu would take (AppKit offers the menu ⌘ keys before any view sees
/// them: ⌘T, ⌘W, ⌘K, ⌘,); while the search field edits, a combination is typed out as its
/// search text. A local monitor gets the keys first. It acts only on its own window's keys,
/// only while a chip records or the search field edits, and it goes with the page: a closed
/// window ends the recording (the window is reused when Settings opens again), and the
/// monitor is removed when the page leaves the window or goes away.
@MainActor
final class KeyboardSettingsKeys {
    let model: KeyboardSettingsModel
    weak var searchField: NSSearchField?
    private(set) weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []

    init(model: KeyboardSettingsModel) {
        self.model = model
    }

    var isMonitoring: Bool { monitor != nil }

    /// Follows the page into `window`, or out of any (nil).
    func attach(to window: NSWindow?) {
        guard window !== self.window || monitor == nil else { return }
        detach()
        guard let window else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
        // The window losing focus, or closing, ends a recording.
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.cancelCapture() }
            }
        }
    }

    isolated deinit {
        detach()
    }

    /// Clicking a chip: it records (or stops), and takes the keyboard from the search field.
    func startCapture(_ command: CommandID) {
        model.startCapture(command)
        if searchEditor != nil { window?.makeFirstResponder(nil) }
    }

    /// Ends any recording and lets go of the keyboard.
    func detach() {
        model.cancelCapture()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window = nil
    }

    /// One key event in the app: what the page does with it, before anything else sees it.
    /// Returns whether the page used it up.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        if let recording = model.capturing {
            switch event.type {
            case .flagsChanged:
                model.holding(KeyChord.modifiers(of: event.modifierFlags))
                return false
            case .keyDown:
                let chord = KeyChord(event: event)
                // Tab keeps moving focus, so there is always a way out that isn't the mouse;
                // it's never recorded.
                if chord?.key == .tab {
                    model.cancelCapture()
                    return false
                }
                if chord?.key == .escape {
                    model.cancelCapture()
                } else {
                    model.commit(recording, chord)
                }
                return true
            default:
                return false
            }
        }
        guard event.type == .keyDown, let editor = searchEditor else { return false }
        // A real modifier (⌘, ⌃ or ⌥) makes the keystroke a combination, typed out as its search
        // text where the cursor is — unless it's a fixed item's, which keeps its meaning here (⌘V
        // pastes, ⌘A selects all). Everything else is ordinary typing.
        guard let chord = KeyChord(event: event), ShortcutText.hasRequiredModifier(chord), !Shortcuts.reserved.contains(chord),
            let text = ShortcutText.formatChordAsQuery(chord)
        else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    /// The search field's editor, while it has the keyboard.
    var searchEditor: NSTextView? {
        guard let searchField, let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
            editor.delegate === searchField
        else { return nil }
        return editor
    }
}

struct KeyboardSettingsView: View {
    @Bindable var model: KeyboardSettingsModel
    let keys: KeyboardSettingsKeys

    var body: some View {
        let groups = model.groups
        VStack(spacing: 0) {
            // Pinned above the list, so the search is there however far down it's scrolled.
            VStack(alignment: .leading, spacing: 8) {
                ShortcutSearchField(model: model, keys: keys)
                Text(
                    "Click a shortcut to record a new combination, then press it. Escape cancels. Combinations the system owns (Copy, Quit, Undo…) and keys scoped to one control (Escape, Enter, Tab) can’t be reassigned."
                )
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
            Divider()
            Form {
                if groups.isEmpty {
                    Section {
                        Text("No shortcuts match your search.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("settings-shortcuts-empty")
                    }
                }
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.bindings, id: \.command) { binding in row(binding) }
                    }
                }
                Section {
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Put every shortcut back to the combination it ships with.").foregroundStyle(.secondary)
                        Spacer()
                        SettingsButton("Restore Defaults", id: "settings-shortcuts-restore-defaults") { model.restoreDefaults() }
                    }
                }
            }
        }
        .settingsPageLayout()
        .accessibilityIdentifier("settings-page-keyboard")
    }

    /// A command's row: its label and description, then Reset (while overridden), the chip and
    /// Clear. Reset comes first so the chip and Clear keep their columns on every row.
    private func row(_ binding: Shortcuts.Binding) -> some View {
        let id = binding.command.rawValue
        let recording = model.capturing == binding.command
        let detail = model.detail(of: binding)
        return LabeledContent {
            HStack(spacing: 6) {
                if binding.isOverridden {
                    SettingsButton("Reset", id: "settings-shortcut-reset-\(id)") { model.reset(binding.command) }
                }
                SettingsButton(
                    model.chipTitle(binding), id: "settings-shortcut-\(id)", isDimmed: binding.chord == nil && !recording,
                    isHighlighted: recording, minWidth: 104
                ) { keys.startCapture(binding.command) }
                SettingsButton("Clear", id: "settings-shortcut-clear-\(id)", isEnabled: binding.chord != nil) {
                    model.clear(binding.command)
                }
            }
        } label: {
            Text(binding.label)
            if let subtitle = subtitle(binding, detail) { subtitle }
        }
    }

    /// The row's description (or notice) and why it lacks its chord, as one text: the form sets
    /// a label's lines after the second smaller, and these two read as one.
    private func subtitle(_ binding: Shortcuts.Binding, _ detail: (text: String, tone: KeyboardSettingsModel.Notice.Tone?)) -> Text? {
        let lines = [
            detail.text.isEmpty ? nil : Text(detail.text).foregroundStyle(Self.color(of: detail.tone)),
            model.explanation(of: binding).map { Text($0).foregroundStyle(.secondary) },
        ].compactMap { $0 }
        guard let first = lines.first else { return nil }
        return lines.dropFirst().reduce(first) { Text("\($0)\n\($1)") }
    }

    private static func color(of tone: KeyboardSettingsModel.Notice.Tone?) -> Color {
        switch tone {
        case .error: .red
        case .info: .accentColor
        case nil: .secondary
        }
    }
}

/// The search field: an `NSSearchField`, whose own clear button empties it. Taking the keyboard
/// ends a chip's recording.
private struct ShortcutSearchField: NSViewRepresentable {
    let model: KeyboardSettingsModel
    let keys: KeyboardSettingsKeys

    final class Field: NSSearchField {
        var onFocus: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: KeyboardSettingsModel

        init(model: KeyboardSettingsModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.query = field.stringValue
        }

        /// The clear button.
        @objc func search(_ sender: NSSearchField) {
            model.query = sender.stringValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search shortcuts, or press a combination…"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.setAccessibilityIdentifier("settings-shortcut-search")
        field.onFocus = { [weak model] in model?.searchDidFocus() }
        keys.searchField = field
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
    }
}

/// The page's view: its keyboard goes with it into and out of the window.
final class KeyboardSettingsHostingView: NSHostingView<KeyboardSettingsView> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rootView.keys.attach(to: window)
    }
}
