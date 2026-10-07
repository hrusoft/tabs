# Writing a plugin

The plugin author's contract. How core runs and enforces it: [ARCHITECTURE.md](ARCHITECTURE.md). Doc comments in
`Sources/TabsPluginSDK` (`TabsPlugin.swift`, `Contributions/*.swift`) are the full contract.

## Start

```sh
Scripts/new-plugin.py <id> [--name Name] [--content-type]   # my-tool → Plugins/MyTool, MyToolPlugin
make project && make check
```

```
Plugins/<Name>/
  Info.plist                     manifest (TabsPlugin) + NSPrincipalClass $(PRODUCT_MODULE_NAME).<Name>Plugin
  Sources/<Name>Plugin.swift     everything in Sources/ → <id>.tabsplugin
  Tests/<Name>PluginTests.swift  unit tests (see Testing)
  plugin.yml                     bundle + test targets, embedding, TABS_BUNDLED_PLUGIN_<ID>, scheme entries
```

- A plugin is a folder: `make project` includes every `Plugins/*/plugin.yml`; no shared file changes.
- Plugin targets take everything from the `Plugin`/`PluginTests` templates. The boundary lint refuses any key but
  `templates`, `templateAttributes` and `- package:` dependencies, and a test target's
  `settings: base: TEST_PARALLELIZATION_WIDTH: <n>` (how many of its tests run at once; [Testing](#testing)).
- The scaffold is a blank, standalone plugin: its sources import only the SDK, its tests reach core only through
  `PluginHarness` (`problems`, `openPane(ofType:)`, `controller(of:as:)`, `config(of:)`), and it names no other plugin.
  `--content-type` adds a content type named after the id, with a blank pane that saves the config it opened with.
- `make check-scaffold` (part of `make check`) proves that, as generated, it works: it scaffolds a blank and a
  content-type plugin into a copy of the tree (`build/scaffold-check`) and runs lint, the build, the packaging gate and
  their tests there.

## Isolation

A plugin sees core, never another plugin; everything it can reach is on its context ([enforcement](ARCHITECTURE.md#isolation)).
Code two plugins both need is copied into each: the SDK is fairly frozen, and grows only, after scrutiny, where plugins
must meet through core ([ARCHITECTURE.md](ARCHITECTURE.md#isolation)).

`make lint` (`Scripts/lint-plugin-boundaries.py`) refuses process-wide state in every Plugin target's `Sources`
(fixture plugins included; tests aren't scanned). Comments and string text don't count; interpolations do.

| Refused | Instead |
|---|---|
| `import TabsCore`, `@testable import` | the SDK |
| `UserDefaults`, `@AppStorage`, `@SceneStorage` | `context.settings` |
| `NotificationCenter.default`, `DistributedNotificationCenter.default` (post or observe) | core's events, delegates, your own objects |
| `NSApp.windows` / `orderedWindows` / `keyWindow` / `mainWindow` / `mainMenu` / `appearance` / `delegate` | your own views; the theme is `pane.theme` |
| `.superview.superview`, `.superview.subviews`, `window.contentView`, `contentViewController` | your own views (a window's tabs are siblings) |
| `NSEvent.addLocalMonitorForEvents` / `addGlobalMonitorForEvents` | nothing: sees every key in every pane |
| `runModal`, `beginSheetModal`, `NSAlert`, `NSOpenPanel`, `NSSavePanel` | `pane.confirm` / `choose` / `alert` / `chooseDirectory` / `chooseFile` (a modal blocks the app and hangs tests) |
| `chdir`, `setenv`, `putenv`, `unsetenv`, `umask`, `signal(SIG…)`, `sigaction(SIG…)`, `changeCurrentDirectoryPath` | pass the cwd and `pane.childEnvironment` to what you spawn |
| `WKWebsiteDataStore.default()` | `WKWebsiteDataStore(forIdentifier: context.webDataStoreIdentifier)` |
| `HTTPCookieStorage` / `URLCache` / `URLCredentialStorage` / `URLSession` `.shared` | your own configuration |
| `NSClassFromString`, `Mirror(reflecting:)` | nothing: reaches other plugins' classes, core's objects |
| `Bundle.main` | `context.bundle` |
| `NSTemporaryDirectory()`, `FileManager.default.temporaryDirectory`, `FileManager.default.urls(for:…)` | `context.dataDirectory` / `cacheDirectory` / `temporaryDirectory` |
| stored `static var`, `static let shared`, top-level `var` | state on the instance (core may make several) |

Reviewed exception: `// boundary: allow — <reason>` on the line itself.

### Third-party packages

- Link each package into exactly one plugin (statically, SwiftPM's default). Two plugins linking one package carry two
  copies of its classes → the gate's duplicate-class check fails. Two plugins needing one package is an SDK addition,
  scrutinized like any other.
- Declare it in your `plugin.yml`; depend on it from the plugin target and its test target:

  ```yaml
  packages:
    SwiftTerm:
      url: https://github.com/migueldeicaza/SwiftTerm
      revision: 5d14406844143538cd8f8851d2d8a67c1fe443e5  # a commit: tags move, Package.resolved isn't committed
  targets:
    TerminalPlugin:
      templates: [Plugin]
      templateAttributes: { pluginID: terminal, pluginDir: Plugins/Terminal }
      dependencies:
        - package: SwiftTerm
    TerminalPluginTests:
      templates: [PluginTests]
      templateAttributes: { pluginDir: Plugins/Terminal }
      dependencies:
        - package: SwiftTerm
  ```

- Credit it in your Info.plist, beside (not inside) the `TabsPlugin` manifest: `TabsCredits`, an array of
  `{name, license, url}`, the name exactly as your `plugin.yml` declares it and the license's SPDX id. The About
  window lists it while your plugin ships; `AboutContentTests` reconciles the two lists both ways.

  ```xml
  <key>TabsCredits</key>
  <array><dict>
      <key>name</key><string>SwiftTerm</string>
      <key>license</key><string>MIT</string>
      <key>url</key><string>https://github.com/migueldeicaza/SwiftTerm</string>
  </dict></array>
  ```

- Package code isn't linted but runs in the process: review it for process-wide state (observers, event monitors,
  globals) before adopting it.
- Packages with build-tool plugins need `-skipPackagePluginValidation` (the Makefile passes it).

## The manifest

`Info.plist` → `TabsPlugin` dict; read without running your code.

| Key | |
|---|---|
| `id` | required; = bundle name (`<id>.tabsplugin`); `[a-z][a-z0-9-]*`, not `tabs`/`core`/`sdk`; the namespace of everything you contribute (`git-tree`, `git-tree.refresh`) |
| `displayName` | required, non-empty; Plugins window, your Settings ▸ Keyboard group |
| `summary` | Plugins window |
| `contentTypes` | exactly the content types `activate` registers, namespaced |
| `canDisable` | default `true` |
| `sortOrder` | UI order and activation order, ties by id; default 100 |

## The entry class

```swift
@MainActor
final class GitTreePlugin: NSObject, TabsPlugin {
    func activate(_ context: any PluginContext) throws {
        let settings = context.settings(GitTreeSettings.self)
        let workspace = context.workspace  // captured below instead of `context`
        context.register(
            ContentTypeContribution(
                id: "git-tree", displayName: "Git tree", icon: .symbol("arrow.triangle.branch"),
                initialConfig: { creation in
                    guard let origin = creation.origin, let dir = workspace.capability(.workingDirectory, of: origin) else {
                        return .emptyObject
                    }
                    return ["cwd": .string(dir.path)]
                },
                makePane: { pane in try GitTreePane(pane: pane, settings: settings) }))
        context.register(
            CommandContribution(
                id: "git-tree.refresh", title: "Refresh", summary: "Re-read the active git tree.", menu: .view,
                defaultChord: KeyChord("r", [.command]), appliesTo: "git-tree"
            ) { invocation in invocation.pane(as: GitTreePane.self)?.refresh() })
    }
}
```

- **No `init` of your own.** Core calls `init()` and may instantiate the class more than once per process (every test
  host does) → all state on the instance.
- **`activate` registers and returns**: fast, synchronous, on the main thread before any window exists, and also
  headless (`--plugin-report`, `--control`) → no windows or views. Slow or async setup → `context.spawn { … }`
  (cancelled on deactivation or rollback; check `Task.isCancelled`).
- **All or nothing.** A throw, or any contribution breaking a rule ([per point](ARCHITECTURE.md#extension-points)),
  rolls the whole plugin back and kills its context. The Plugins window and `--plugin-report` say why.
- **`deactivate()`** runs exactly once if `activate` returned: at quit (reverse order) or right after its
  contributions were rejected. Never after a throw → clean up before throwing. Release process-wide resources here, not
  in `paneWillClose` (skipped at quit).
- **Contribute only during `activate`**; later calls are ignored (listed as ignored calls). `openPane`, `focusPane`,
  `revealPane` work only after it.
- **Don't capture `context` in a contribution's closure**: the registry keeps closures for good, and so would keep your
  context alive. Capture what you need (`context.workspace`, the settings object).

## Contributions

| `context.register(…)` | Notes |
|---|---|
| `ContentTypeContribution` | `makePane` builds every pane of the type, new or restored ([Panes](#panes)); `initialConfig(creation)` for a pane created without a config (`creation.origin`: the pane it was made from); `icon` (`PaneIcon`: an existing SF Symbol, or a template image); `creationLabel` (default "New \<displayName>") = the creation button's tooltip and accessibility label; the ⌘P palette row shows `displayName` |
| `CommandContribution` | `menu`: `.file` / `.edit` / `.view` / `.window`; `defaultChord`; `appliesTo` (own type: enabled, and its chord armed, only while one of your panes of that type is active); `isEnabled`, `isChecked`; `summary` (Settings ▸ Keyboard) |
| `SettingsPageContribution` | AppKit `makeView`, or a SwiftUI builder (gets `settingsPageLayout()`: grouped `Form`, `SettingsPageContribution.width` = 600); made when its tab is first chosen (not as Settings opens), then kept while the window lives; the window fits its height, a longer page scrolls; hidden while the plugin is disabled |
| `PaneSignalContribution` | [Signals](#signals) |
| `ControlVerbContribution` | [Control verbs](#control-verbs-tabs-ctl) |
| `ControlCapabilityContribution` | one per plugin with control-plane verbs, id = plugin id |

### Shortcuts

- `KeyChord(key, modifiers)`: a lowercase letter (shift explicit); another character as the keys make it, without
  `.shift` (`KeyChord("?", [.command])` = ⌘?); `.return`, `.tab`, `.escape`, `.delete`, `.space`; `.arrow(_)`;
  `.function(1…20)`. Needs ⌘ or ⌃, unless a function key. Stored form: `cmd+shift+d`, `ctrl+f5`.
- Without `appliesTo` the chord needs ⌘ (or is a function key): ⌃ keys belong to the focused pane (a shell's ⌃R). With
  `appliesTo`, ⌃ alone is fine and other types' commands may share the chord.
- It's only a default: the user can rebind or unbind it (Settings ▸ Keyboard under your plugin's name,
  `tabs.setShortcut`); a chord already taken leaves your command unbound, reported, never fatal
  ([resolution](ARCHITECTURE.md#shortcuts)).
- Views that take raw keys (terminal, web view): return false from `performKeyEquivalent` when
  `pane.isAppShortcut(event)`; keep everything else.

## The context

`PluginContext`, all of it:

| Member | |
|---|---|
| `manifest`, `id`, `bundle` (your resources), `log` (`Logger`, category `plugin.<id>`) | |
| `dataDirectory`, `cacheDirectory`, `temporaryDirectory` | your own, created on access; the temporary one is per run, removed at quit |
| `webDataStoreIdentifier` | your web data identity; stable per data directory, not derivable by other plugins |
| `register(_:)` / `contribute(_:to:)` | during `activate` only |
| `settings(T.self)` | [Settings](#settings) |
| `spawn { … }` | a task tied to your lifetime; off the main actor unless `@MainActor` |
| `events` | [Events](#events) |
| `workspace` | `activePaneID`, `contentType(of:)` (any pane); `panes(ofType:)`, `openPane`, `focusPane`, `revealPane` (own types only); `capability(_:of:)` (any pane, core's copy) |

## Panes

`makePane(context)` returns a `PaneController`. Throw only when the config truly can't be read (wrong type, names
something that's gone): core keeps the saved pane verbatim, shown unavailable with your error. Decode tolerantly
(missing fields → defaults). Never fall back to an empty state: it would be saved over the user's.

### `PaneController`

| Member | Contract |
|---|---|
| `view` | asked on first show (a restored background tab may never be) → build lazily (`lazy var`). Core may move it to other superviews and windows while open; AppKit views keep their state (`viewDidMoveToWindow` to react). Everything else must work before the view exists |
| `currentConfig()` | your persisted state, asked at every save; call `pane.configDidChange()` when it changes. NaN/∞ → refused, the last good config is kept, a fault logged |
| `closeWarning` | one line, a bullet in core's "A pane is still busy" confirmation: say what's lost ("vim is still running") |
| `focus()` | the pane became active in a key window; default makes `view` first responder |
| `paneDidShow()` / `paneDidHide()` | became / stopped being its window's visible tab. Size to the view only while shown |
| `paneAppearanceDidChange(theme:depth:)` | theme or depth changed, and once before the first show. `PaneTheme` = the tokens core paints chrome with (`bg`, `bgElevated`, `border`, `text`, `textDim`, `accent`, `onAccent`, `bellAlert`, `agent`, `hover`, `shadow`, `shadowStrength`, `isDark`, `surface(depth:)`). Chrome-like content uses it; content with its own palette ignores it |
| `paneDidBecomeAttended()` / `paneDidLoseAttention()` | the user starts / stops looking: active pane of a focused window. Transitions only (losing also precedes `paneWillClose`). The place for a refresh on return |
| `paneWillClose()` | the pane is going for good; not called at quit |
| `headerActions` | `[PaneHeaderAction(id:label:icon:perform:)]`: buttons leftmost in the header's hover-revealed controls, drawn like core's (13pt icon box); `id` is the accessibility identifier. Asked with `view` |
| `headerAccessory` | a view of yours after the actions, before core's controls. Asked with `view` |
| `headerTitle` | a view of yours in the title's slot (after grip and signal icons, before the controls; what width is left, bar height); no title text, no Edit title. A press on one of its controls activates without dragging; on empty space it drags the pane. Adopt `PaneHeaderTitleView` for `PaneHeaderSlot` (bar content width, fractional origin offset). Asked with `view` |
| `controlSummary`, `controlDescription()` | what `list-panes` / `pane-info` show ([Control verbs](#control-verbs-tabs-ctl)) |

**Undo**: keep a per-pane `UndoManager` (a text view: from its delegate's `undoManager(for:)`). A window's undo manager
is shared by all its tabs, and a pane can move to another window.

### `PaneContext`

| Member | |
|---|---|
| `paneID`, `contentType`, `initialConfig` | |
| `windowID` | live: follows the pane between windows |
| `theme`, `depth` | current (dark / 0 until first told) |
| `controller` | the pane that owns this one now (an agent's terminal, via `controlledBy`), or nil; live from creation to close. What your guards read |
| `setTitle(_:)`, `configDidChange()` | |
| `requestClose()` | asynchronous: happens after your call returns; the user is still asked if `closeWarning` is set |
| `offer(_:_:)` | offer (or withdraw with nil) a core capability on every change: `pane.offer(.workingDirectory, url)`; readers never call you |
| `raise(_:)` / `withdraw(_:)` | your signal kinds on this pane |
| `childEnvironment` | the whole environment for a process you start: the app's minus its launch settings, plus `TABS_CONTROL_SOCKET`, `TABS_PANE_ID`. Add yours (`TERM`) and pass it, with the working directory, to the spawn |
| `isAppShortcut(_:)` | [Shortcuts](#shortcuts) |
| `showContextMenu(_:at:in:)` | core's menu with `[PaneMenuItem(title, isEnabled:, action:)]`, top-left at a point in your view; closes on an outside click, Escape, or an enabled row (runs it); returns at once; nothing for no items. Never an `NSMenu` of your own |
| `confirm(PaneConfirm)` → `Bool` | core's dialog card over the pane's window only (the rest of the app stays live); false for Cancel, Escape, an outside click, or the pane closing |
| `choose(PaneChoose)` → `Int?` | a select starting on the first option; nil for any back-out or no options |
| `alert(PaneAlert)` | one button; returns once dismissed. Messages keep their line breaks |
| `chooseDirectory(title:startingAt:)`, `chooseFile(…)` → `URL?` | the system open panel as a sheet on the pane's window; nil when cancelled |

With no window shown (hidden e2e, UI tests), questions answer their default at once (confirm → true, choose → first,
alert → returns) and pickers answer nil. Tests: `FakeRenderer.answerDialog` / `answerPicker` (core tier);
`WorkspaceRenderer.showsDialogCardsUnattended` + `UIDriver.pressDialogButton` / `chooseDialogOption` /
`clickDialogBackdrop`, and `WorkspaceRenderer.pickerOverride` (UI tier). The real open panel can't be driven.

### Opening panes

`context.workspace.openPane(PaneRequest(type:config:placement:origin:activates:controlledBy:))`:

- `placement`: `.automatic` (the frontmost window's active pane: fill it if empty, else a tab beside), `.tab(near:)`
  (fills `near` if empty), `.split(pane, edge:)`, `.floating(near:)` (unpinned, in the section of `near` the user's
  spawn-position setting names), `.window`. Placed as the user's own action would be.
- `origin` → your `initialConfig`'s `creation.origin`: ask it for capabilities to open where the user was.
- `activates: false`: placed and made active as usual, but the keyboard stays where it was —
  a pane another pane opens must never pull typing away. Spent once.
- `controlledBy`: [Control verbs](#control-verbs-tabs-ctl).
- Returns nil when: not your type, disabled for creation, no shell (headless), still in `activate`, config not valid
  JSON, `makePane` threw, nowhere to place it, or `controlledBy` refused.

`revealPane(_:)` makes one of your panes visible (tabs above it shown, its floating window raised) without activating it
or taking the keyboard (e.g. before a capture). `focusPane(_:)` also activates it and gives it the keyboard.

## Signals

A cue on a pane that asks for the eye without taking focus; look and behaviour in [PANE-SIGNALS.md](PANE-SIGNALS.md).
Declare kinds in `activate`, raise them on your own panes:

```swift
let bell = PaneSignalContribution(
    id: "terminal.bell", label: "Bell", icon: .symbol("bell"), color: .alert,
    pulse: 3, marksTabs: true, lifetime: .untilSeen, requestsAttention: true,
    setting: .init(title: "Bell indicator", detail: "Pulse a bell icon when a terminal rings its bell."))
context.register(bell)
pane.raise(bell.signal)  // later, from one of your panes
```

| Field | |
|---|---|
| `lifetime` | `.untilSeen`: dropped if raised while the user looks at the pane; clears when they look. `.untilWithdrawn`: a state, until you `withdraw` it |
| `icon` | an SF Symbol (must exist, else the plugin fails) or a template image (alpha only), in a 16×16 box. Draw images like the chrome's: 1.2pt stroke, round caps |
| `color` | `.alert`, `.agent`, `.accent` (follow the theme), `.custom(dark:light:)` |
| `pulse` | seconds per breath (default 3; nil: steady) |
| `marksTabs` | also on every tab holding the pane |
| `requestsAttention` | the Dock bounces on every raise while the pane's window isn't focused |
| `tooltip` | the icon's hover text |
| `setting` | its switch in Settings ▸ Panes & Tabs; off: `.untilSeen` raises are dropped, shown signals hidden but kept |

- Follows the pane everywhere (tabs, splits, floating, windows); ends when it closes.
- Raising one it already carries changes nothing (the Dock bounce aside). Only your kinds, only on your panes; anything
  else is refused and logged.
- Several on one pane: icons in kind order (plugins in UI order, each in registration order); the outline is the last
  one's (core's `controlled` is always last).

## Control verbs (`tabs-ctl`)

An agent in a terminal pane runs `tabs-ctl <command> --flag value` (the app's
`Contents/Helpers/tabs-ctl`, through the skill's `scripts/tabs-ctl`). It sends `{command, args, paneId: $TABS_PANE_ID, cwd}` to
`$TABS_CONTROL_SOCKET`. The script knows no command: core resolves it from what you declare → register verbs; touch no
script, skill or shared file. Core's side (dispatch order and messages, ownership ledger, budgets, core's verbs):
[ARCHITECTURE.md](ARCHITECTURE.md#the-control-plane).

```swift
context.register(ControlCapabilityContribution(id: "browser", displayName: "Browser", guide: guideText, limits: ["maxResults": 50]))
context.register(
    ControlVerbContribution(
        name: "browser.navigate", summary: "Load a URL into a pane you own and wait for it to settle.",
        arguments: [
            ControlArgument("url", .string, required: true, summary: "http://, https://, or about:blank."),
            ControlArgument("retryOnRedirect", .bool, summary: "Re-issue the navigation once if it lands elsewhere."),
        ],
        target: .ownedPane(ofTypes: ["browser"]), timeout: .seconds(15) + ControlBudget.headroom,
        command: "navigate", wireType: "navigate",
        resultShape: ["loaded": "boolean", "url": "string"]
    ) { invocation in
        guard let pane = invocation.pane(as: BrowserPane.self) else { throw ControlVerbError("…") }
        return try await pane.navigate(to: invocation["url"]?.stringValue ?? "")
    })
```

Before your handler runs, core has checked that the caller is a live pane, that it owns `--pane`, that the wire request
matches the schema derived from your `arguments`, and that the target is open and of your type. Your handler never
sees those failures.

**Declaring a verb**

- `name`: qualified (`browser.navigate`). A verb without `wireType` is internal: reached by name only (`tabs.verbs`,
  `harness.call`), `args` as given, `paneId` = its target (`.pane(ofTypes:)`), `timeout` = its deadline.
- `command` (kebab-case CLI name) and `wireType` (lowerCamelCase wire `type`): both or neither. `wireType` is declared,
  never derived (several differ from the command), not one of core's, and unique across all plugins: a clash fails the
  later plugin. A bare `command` two verbs share is refused at dispatch, naming both (qualified names still work).
- `arguments` = the wire fields = the flags. Names lowerCamelCase; the flag is the name in kebab-case
  (`retryOnRedirect` → `--retry-on-redirect`) unless `flag:` (`timeoutMs` → `--timeout`). Not `type`, `paneId`,
  `targetPaneId` (nor `target` with a composition).
  - Kinds: `string`, `integer`, `number`, `bool`, `object`, `array`, `path`, `csv` (comma list → array of strings),
    `json` (parsed; any JSON unless `schema:` says more).
  - `enumValues`, `minimum`, `defaultValue` (flags only; never applied to a raw wire request), `placeholder` (the usage
    line's `<css>`), `flagValue` (what a present `bool` flag sends: `--off` → `enabled: false`), `schema` (the wire
    property's own JSON Schema).
  - A bare flag arrives as `true`: accepted only for `bool` and `path` (a bare `--out` = "generate one", `true` on the
    wire); otherwise `--<flag> needs a value`, never sent as `1` or `"true"`.
  - `path`: relative values resolved against the caller's `cwd` (flags and raw wire requests alike); the handler always
    gets an absolute path.
- `composition: .elementTarget`: `--ref` | `--x` + `--y` | `--role`/`--name`/`--selector` [`--nth`], exactly one form
  → the required wire field `target`; core adds the seven flags (after `--pane`) and the schema.
- `target`: `.ownedPane(ofTypes: [your types])` for a verb acting on a pane (core adds the required `--pane`); `.none`
  for one acting on the app or creating a pane. `ofTypes: nil` means any type (core's own verbs); `pane(as:)` still
  returns only your panes. `.pane(ofTypes:)` is for internal verbs.
- `batchable: false`: refused inside `batch` — for a verb that grants a pane's ownership partway through
  (`create-browser-pane`).
- `timeout` (default 30 s) / `timeoutFor(arguments)`: your budget. A verb that waits declares its longest wait +
  `ControlBudget.headroom`, so its own bounded answer beats core's `timed out` (at budget + headroom). The browser's
  convention: quick verbs 5 s, reads 15 s.
- `resultShape`: documentation for `describe` (a string names a primitive, `[x]` an array, an object nests); never
  validated.

**The handler**

- `invocation.arguments` / `invocation["name"]`: the wire fields without `type`, `paneId`, `targetPaneId`.
- `invocation.callerPane`: the pane whose shell ran the CLI → the owner to pass as `PaneRequest.controlledBy`.
- `invocation.targetPane`, `invocation.pane(as:)` (your controller), `invocation.cwd`.
- Throw `ControlVerbError("…")` for a clean message; control-plane errors go out verbatim, no prefix (the skill quotes
  them).
- Return a `JSONValue`; `.null` answers a bare `{ok: true}`. No bytes on the socket: screenshots, saved resources and
  big results are files, answered with their path.
- Honor cancellation: on timeout the caller is answered anyway and your side effects stay. Never block the main actor.

**Panes an agent controls**

- A pane your verb creates for the agent: `openPane(PaneRequest(…, controlledBy: invocation.callerPane))`, allowed only
  while that verb is still running (else refused, no pane made). The ledger has it before `makePane`, so its first
  load already knows (`PaneContext.controller`); core raises the `controlled` signal.
- Only its owner may target it; anyone else gets `not the owner of this pane`. Ownership ends when the pane closes.

**What agents read**

- One `ControlCapabilityContribution` per plugin with control-plane verbs (id = plugin id), else activation fails.
  `guide`: *when* and *how* to use the commands (readiness, targeting, common failures) — the flag lists already say
  what each accepts. `limits`: numbers an agent needs.
- `capabilities` lists it (`enabled` = your plugin not disabled; a disabled one still answers for panes that exist),
  one usage line per command; `describe --capability <id>` prints the guide, limits, flags, derived wire schemas and
  `resultShape`s.
- `controlSummary`: fields `list-panes` merges over `{paneId, type, title}`; nil (default) = not listed.
- `controlDescription()`: `.fields` (merged over the same), `.error(message)` (the caller's error), or `.unsupported`
  (default: `<type> panes cannot be inspected with getPaneInfo`). Both read the live controller, so they must work
  before the view exists.

## Settings

```swift
struct GitTreeSettings: PluginSettingsValue { var showRemotes = true }  // init() = the defaults
let settings = context.settings(GitTreeSettings.self)                   // one settings type per plugin
settings.update { $0.showRemotes = false }                              // persisted
let observation = settings.observe { value in … }                       // AppKit: after each change, not initially
Toggle("Show remotes", isOn: settings.binding(\.showRemotes))           // SwiftUI observes settings.value
```

- Stored under `plugins.<id>` in `settings.json`, merged over your encoded defaults: fields added later decode;
  top-level fields a newer build wrote survive your updates.
- A stored value that won't decode → defaults, and the stored value is left untouched until the next update.
- An update that can't be encoded (NaN) is refused whole; headless, every update is refused (read-only).
- Observers are called in order; an update made inside an observer is delivered after the current one reached everyone.
- After deactivation, updates are ignored and observers dropped.

## Events

`context.events.subscribe(.paneOpened) { event in … }`, also `.paneClosed`, `.paneMoved`, `.activePaneChanged`,
`.capabilityChanged(.workingDirectory)`. Core's events about every pane: `PaneEvent` (`paneID`, `windowID`,
`contentType`). Ordering and timing: [ARCHITECTURE.md](ARCHITECTURE.md#panes-and-layout). A subscription lasts until
cancelled or your plugin deactivates; dropping the returned `Subscription` doesn't cancel it.

## Testing

- **Unit tests** (`Plugins/<Name>/Tests`, target `<Name>PluginTests`, unhosted): your sources + `Tests/Support`; the
  real plugin class in a real core runtime with the layout engine and a `FakeRenderer`, no app, no other plugin (add
  in-process ones with `alongside:`).

  ```swift
  let harness = try PluginHarness { GitTreePlugin() }   // manifest read from your Info.plist
  let pane = try #require(harness.open("git-tree"))
  harness.perform("git-tree.refresh")                   // as the menu does, against the active pane
  #expect(harness.config(of: pane.id) == ["cwd": "/tmp"])
  let answer = await harness.call("git-tree.someVerb", ["path": "."], pane: pane.id)  // an internal verb
  ```

  Control-plane verbs: `PluginHarness(withAgent: true) { … }` (a stand-in terminal, so there is a caller), then
  `harness.tabsCtl("navigate", ["pane": .string(id.rawValue), "url": "…"])` (CLI flags) or
  `harness.wire(["type": "navigate", "targetPaneId": …])` (a batch step); `harness.agentPane` is the caller and owner.

  `make test-plugins` runs every plugin's tests, `ONLY=GitTreePluginTests` one (or several, space-separated). Tests may
  `@testable import TabsCore`; your sources may not (lint). The scaffold's tests don't need it: `harness.problems` is
  empty for a plugin that activated cleanly, and `harness.openPane(ofType:config:)` returns the SDK's `PaneID`.
- **Core rules with inline plugins**: `TabsCoreTests`, `TestSupport.candidate(manifest) { context in … }` with
  `FakeShell` or `FakeRenderer`.

Every tier of your plugin's tests lives in its folder, so deleting the folder takes them along and core's tests never
name it. Each optional tier is a folder and a target in your `plugin.yml`:

```yaml
targets:
  GitTreePluginUITests:
    templates: [PluginUITests]
    templateAttributes: { pluginDir: Plugins/GitTree }
  GitTreePluginE2ETests:
    templates: [PluginE2ETests]
    templateAttributes: { pluginDir: Plugins/GitTree }
schemes:
  Tabs:
    test:
      targets: [GitTreePluginTests, GitTreePluginUITests, GitTreePluginE2ETests]
```

- **What a user does** (`Plugins/<Name>/Tests/UI`, target `<Name>PluginUITests`, hosted in Tabs.app with every
  bundled plugin across real image boundaries; `make test-ui`): `UIDriver` (`Tests/AppSupport`): `create("git-tree")`,
  `click("<accessibility id>")`, `type(…)`, `press(KeyChord("r", [.command]))`, `choose("View", "Refresh")`; assert
  on `activePane`, `focusedPane`, `config(of:)`, or your Debug verbs (`ui.call("git-tree.test.state", pane: id)`).
  Nest suites in `extension UITests` (serialized). Give your controls accessibility identifiers. Your tests reach your
  plugin as a user does, never by importing it. Another plugin is never needed: a pane offering a working directory is
  `StandIns`' `text` with `{cwd}`.
- **The running app** (`Plugins/<Name>/Tests/E2E`, target `<Name>PluginE2ETests`; `make test-e2e`): `LaunchedApp`
  (`Tests/EndToEndSupport`) over the control socket; `@Suite(.sharedApp)` suites share one app, reset per test with
  `SharedApp.fresh()`; tests that quit, relaunch or crash it launch their own. The app runs the `fixture-text` test
  plugin beside its own: `app.newFixturePane()` is a pane that isn't yours, e.g. an agent's caller. Keep this tier to
  glue, each test a launched app's seconds: one cheap test that your built bundle is wired into the app (a pane made
  and read back, your verbs through the real relay), and only what no lower tier can show (your panes across a quit or
  a crash); what your plugin does is the other tiers'.
- **The look** (`Plugins/<Name>/Visual/scenarios`, goldens in `Visual/golden` beside them; `Visual/README.md`): a
  scenario's `content` entry for one of your panes goes to your Debug verb `<id>.test.stage`; `<id>.test.visual`
  reports its geometry (`{title, body}`) and `<id>.test.snapshot` draws what the layer tree can't. `GeometryGoldenTests`
  holds your scenarios to their goldens.
- **At once**: a scheme entry `- name: <Name>PluginTests` with `parallelizable: true` runs that bundle's suites
  concurrently in one process (a `.serialized` suite keeps its own order), every test at once unless the target sets
  `TEST_PARALLELIZATION_WIDTH` (`Tests/Process`): a bundle whose tests all need the main thread (a web view)
  wants a few, Browser's runs 4. Such tests share no process-wide state and poll with generous deadlines. A bundle
  whose tests share one main thread goes faster only in more processes: `make test` splits a long serial one by suite.
- **Files**: a test's folders and files go under `TestTemporary.directory("<name>")` / `.location(…)`
  (`Tests/Process`), its process's own folder, removed as it exits; `make lint` refuses the temporary directory
  reached any other way.
- **Done** = `make check`: lint, no warning in the build, every tier, the packaging gate (your bundle's linkage,
  stamp, manifest), and the scaffold check.
