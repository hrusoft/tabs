# Architecture

Core (`Sources/TabsCore`) runs plugins (`Plugins/<Name>`) through one SDK (`Sources/TabsPluginSDK`); the AppKit shell
(`Sources/Tabs`) draws windows, menus and pane chrome. The plugin author's side: [PLUGINS.md](PLUGINS.md).

## Images

```
Tabs.app/Contents/
  MacOS/Tabs                           role app     shell: windows, menus, pane chrome
  Frameworks/TabsPluginSDK.framework   role sdk     the only module plugins see
  Frameworks/TabsCore.framework        role core    plugin runtime, layout, persistence, control; no windows
  PlugIns/<id>.tabsplugin              role plugin  MH_BUNDLE: loadable, never linkable
```

- Dependencies: shell → TabsCore → SDK ← plugins. Never plugin → plugin.
- TabsCore has no `public` API, only `package`. Shell, TabsCore, SDK and every test target share
  `SWIFT_PACKAGE_NAME = TabsCore`; each plugin target gets its own → `import TabsCore` gives a plugin nothing, and the
  SDK's `package` members (`ExtensionPoint.init`…) are invisible to it.
- Every image carries `Resources/TabsBuildStamp.plist` (`Scripts/stamp-build-info.sh`): role, configuration,
  shared-ABI fingerprint; the app's also `bundledPlugins` (every `TABS_BUNDLED_PLUGIN_<ID>` setting, one per `plugin.yml`).
  - A resource of our own, never Info.plist keys: Xcode regenerates the product Info.plist on its own schedule and can
    erase what a script phase wrote.
  - Mode 644: an install owned by another user must read it, or core refuses every plugin.

## Isolation

A plugin reaches only its `PluginContext` ([PLUGINS.md](PLUGINS.md#the-context)). No plugin-to-plugin APIs, events,
extension points or dependencies.

| Enforcement | Where |
|---|---|
| Only core constructs `ExtensionPoint`, `EventChannel`, `PaneCapability` (`package` inits) | SDK |
| Only declared points / channels / capabilities work; an undeclared one or a wrong type is refused, never silently dropped | `ContributionRegistry`, `EventHub`, `PaneRuntime` / `PluginWorkspace` |
| Plugins subscribe, never publish | `EventBus` has only `subscribe` |
| Contribution ids namespaced by plugin id (`<id>`, `<id>.<name>`); plugin ids `tabs`, `core`, `sdk` reserved | `ContributionRegistry.namespacePolicy`, `PluginManifest.problems()` |
| `openPane`, `focusPane`, `revealPane`, `panes(ofType:)`: own content types only (else an ignored call) | `PluginWorkspace` (`PluginContextImpl.swift`) |
| `PaneRequest.controlledBy`: only the caller of the plugin's own control verb, while it runs | `PaneRuntime.openPane(_:by:)`, `PaneOwnership.isRunning` |
| Commands and verbs get a controller only for the plugin's own panes; `appliesTo` and verb targets must name own types | `CommandCenter`, `ControlInvocation.pane(as:)`, commit checks in `CoreExtensionPoints` |
| Signals: a plugin raises/withdraws only its own kinds | `PaneSignals` |
| No `requires`: plugins load and fail independently, in `(sortOrder, id)` order | `PluginResolver` |
| Plugins link only the SDK and system libraries | packaging gate |
| Process-wide state (defaults, notifications, env, cwd, globals, shared web/URL stores…) | boundary lint ([PLUGINS.md](PLUGINS.md#isolation)) |

- Two plugins need to share something → it becomes core functionality exposed through the SDK. The model:
  `PaneCapability.workingDirectory` — any pane offers it, any plugin reads core's copy, neither knows the other
  (Electron's `exposeCwd`/`exposedCwdOf`).
- One plugin's contributions can't fail another's, except: a control-plane `wireType` is global, so a clash fails the
  later plugin in `(sortOrder, id)` order; and discovery rejects every claimant of a duplicate plugin id.
- API-, link- and lint-level isolation, not a security boundary: plugins are trusted in-process code.

## Three rules the compiler can't enforce

1. **One copy of every shared module.** A type crossing images must live in exactly one image. A plugin carrying its
   own SDK has a different `TabsPlugin` protocol → `principalClass as? TabsPlugin.Type` fails though the class
   conforms. SwiftPM silently links a same-package target statically even into a "dynamic" product, so the SDK is an
   Xcode framework that plugins link but never embed (`Plugin` template: `embed: false`). Caught by:
   - the gate: one SDK image; no other image exports `tabs_plugin_sdk_sentinel`; linkage;
   - the loader: "does not conform to the loaded SDK's TabsPlugin".
2. **One build of everything.** Lockstep releases, `BUILD_LIBRARY_FOR_DISTRIBUTION = NO`: every image hard-codes the
   shared modules' layouts and witness tables; an image from another build loads cleanly, then corrupts memory. The
   fingerprint (`Scripts/shared-fingerprint.sh <configuration>`, conservative: a comment edit changes it) hashes:
   - every file (any type, symlinks followed) of `Sources/TabsPluginSDK` and `Sources/TabsCore`;
   - `project.yml`, every `Plugins/*/plugin.yml`, `Config/*` (incl. `Signing.local.xcconfig`);
   - the configuration name;
   - `xcrun swiftc --version`.

   Checked before any plugin code loads: a plugin whose stamp differs from the loaded SDK's is rejected; an app or
   framework that differs or has no stamp (`BuildIntegrity`) → "Tabs is damaged" alert and quit (hidden: stderr,
   exit 2; headless: `the app bundle mixes builds…`, exit 2).
3. **Nothing unloads.** An image that registered ObjC classes or Swift metadata can't be unloaded. Disabling applies
   at the next launch; a failed plugin's image stays mapped.

## Plugin lifecycle

```
discover ─→ resolve ─→ load ─→ activate (one transaction) ─→ … ─→ deactivate (quit, reverse order)
Info.plist  manifests  dlopen   commit all or roll back all
+ stamp     only       + cast
```

- **Discover** (`PluginDiscovery`; rejected = no code mapped). Rejects a bundle that:
  - is a symlink, or not a readable bundle;
  - has no or a malformed manifest, or one failing `PluginManifest.problems()` (id syntax, reserved id, empty
    `displayName`, content types outside its namespace or repeated);
  - has id ≠ bundle name, no stamp, role ≠ `plugin`, or a fingerprint ≠ the loaded SDK's;
  - isn't in the app stamp's `bundledPlugins` (a listed plugin missing from `PlugIns` is reported as rejected too).
  - Two candidates with one id (bundle vs in-process test plugin): both rejected.
- **Resolve** (`PluginResolver`, pure): `(sortOrder, id)`. **Disabling is a creation gate, not an uninstall**: a
  disabled plugin still loads when a restored pane shows one of its content types (noted in its record), but offers no
  creation actions, settings pages or enabled control capability. Turning a plugin off never costs an open pane.
- **Load** (`PluginLoader`): principal class defined in the plugin's own bundle, an `NSObject` subclass, conforming to
  the loaded SDK's `TabsPlugin`; instantiated with `init()`.
- **Activate** (`PluginHost`): a `PluginContextImpl` bound to the plugin's id. Contributions are validated as staged and
  committed only if `activate` returns and nothing broke a rule. Otherwise nothing is committed; subscriptions,
  settings and spawned tasks are cancelled; the context goes dead (later calls ignored and recorded). A plugin rejected
  at commit still gets `deactivate()` (context live), then the kill. Other plugins are unaffected.
- **Deactivate**: exactly once per plugin whose `activate` returned; at quit in reverse order; its tasks are cancelled
  right after.
- Records (Plugins window, `--plugin-report`, `tabs.plugins`): `active` | `disabled` | `rejected` (discovery) |
  `failed` (loaded, rolled back) + detail, notes (why a disabled plugin loaded, unbound shortcuts), ignored calls
  (first 50), contribution counts, activation time. `--plugin-report` exits 1 if any is rejected or failed.

## Extension points

Everything a plugin adds is a `Contribution` to one of core's `ExtensionPoint<C>`s (`CoreExtensionPoints.install`).

| Point | Contribution | Id | Checks (all about the plugin's own contributions) |
|---|---|---|---|
| `.contentTypes` | `ContentTypeContribution` | namespaced, in the manifest's `contentTypes`; every declared type registered | `displayName`; SF Symbol exists; `creationLabel` non-empty if set |
| `.commands` | `CommandContribution` | namespaced | `title`; default chord well-formed for its scope; `appliesTo` an own type |
| `.settingsPages` | `SettingsPageContribution` | namespaced | `title` |
| `.controlVerbs` | `ControlVerbContribution` | namespaced | argument/command/wireType rules ([PLUGINS.md](PLUGINS.md#control-verbs-tabs-ctl)); target types own; `wireType` not core's and unique across plugins; control-plane verbs need a capability |
| `.controlCapabilities` | `ControlCapabilityContribution` | = plugin id | `displayName`; `limits` valid JSON |
| `.paneSignals` | `PaneSignalContribution` | namespaced | `label`; SF Symbol exists; `pulse` > 0; setting title; `tooltip` non-empty if set |

- Every point gets transactional staging, duplicate detection and namespacing. An undeclared point or a wrong
  contribution type fails the plugin.
- A new kind of contribution is a core change that never touches the loader, the context or the rollback: define the
  type, declare the point, add a `register` overload, read it where it's used.

### Shortcuts

`Shortcuts` owns every effective chord, core's commands and plugins'.

- Claims in priority order: the user's bindings (`settings.json` → `core.shortcuts`; `null` = unbound) → core's
  defaults → plugins' defaults in UI order. A chord already claimed in an overlapping scope leaves the later command
  unbound, with a note (`tabs.shortcuts`, Plugins window, report); never a failure.
- Scopes overlap unless both commands have `appliesTo`, and they differ.
- The menu arms a scoped chord only while its type is active (`MainMenu.arm`): AppKit stops at the first matching key
  equivalent, even a disabled one. So types can share chords, and one type's ⌃ keys never shadow another pane's typing.
- Fixed stock items (`CoreCommand(fixed:)`: Hide, Hide Others, Quit, Undo, Redo, Cut, Copy, Paste, Select All,
  Minimize) can't be rebound; plugin defaults lose their chords to them by priority. The user also can't take ⌃⌘F
  (`Shortcuts.reserved`); plugin defaults aren't checked against it. User rules: [KEYBOARD.md](KEYBOARD.md);
  `tabs.setShortcut` applies the same.

## Panes and layout

`PaneRuntime` holds everything plugins can observe about panes: creation (behind the creation gate), restoration,
contexts, titles, snapshots, capabilities, visibility, ownership, and the events:

- `paneOpened` once a live pane is in a window, never before;
- `paneClosed` only for panes that opened;
- `activePaneChanged` only when the frontmost window's active pane or its type changes (a tab selected in a background
  window is announced when that window comes to the front);
- `paneMoved` when an opened pane changes window;
- `capabilityChanged(c)` on the next main-actor turn, once per burst; readers see the new value at once;
- an event published during delivery waits: every subscriber sees events in order.

Three layers:

- **Model** (`TabsCore/Layout`, pure values, tested without windows): a port of Electron's layout model. Leaf, tab group
  or split; per window (`WindowLayout`) a docked root (always a tab group), floating panes, an active pane. `layout.json`
  holds every window in Electron's snapshot shape. [LAYOUT.md](LAYOUT.md).
- **`LayoutEngine`** (core's `WorkspaceShell`): the only place the layout changes, for plugin requests and user actions
  alike. Model first, then `reconcile()`:
  1. panes gone from the model close (`paneWillClose`, `paneClosed`);
  2. the renderer draws (building views runs plugin code);
  3. new panes `paneOpened`, moved ones `paneMoved`;
  4. visibility (`paneDidShow`/`paneDidHide`);
  5. the active pane announced;
  6. a save scheduled (only if the model changed; coalesced over 400 ms).

  A layout change from plugin code mid-pass restarts the pass at step 1: plugins never see a half-applied model. Capped
  at 100 restarts (then a fault is logged and it stops), so plugins answering each other can't spin forever. Also
  owns: the last-closed window, close confirmations (`CloseConfirmation`: `closeWarning`s as bullets, Cancel the
  default, Close/Quit Anyway), saving, creation origins, new content "like" a pane, cross-window moves.
- **Renderer** (`WorkspaceRenderer`, `Sources/Tabs`): draws the model, turns input into model operations, decides
  nothing. Views reconciled by node id; a leaf's body (and plugin view) lives as long as the leaf, across tab switches,
  fills, moves and windows.

Rules that prevent bugs:

- **Views are built on first show and may move** between superviews and windows. AppKit views keep their state across a
  move (unlike Electron's `<webview>`) → no state-transfer machinery for splits, floating panes, cross-window moves.
- **Capabilities are pushed**: a pane `offer`s, core stores, readers get core's copy → no plugin runs inside another's
  call. Declared in `CoreRuntime` (only `.workingDirectory`); a new one is a core change.
- **Children don't inherit launch settings**: `childEnvironment` drops `TABS_DATA_DIR`, `TABS_LISTEN_SOCKET`,
  `TABS_E2E_HIDDEN` (`PaneRuntime.launchSettings`), else a Tabs started from a pane would share this one's data,
  socket or hidden mode; it adds `TABS_CONTROL_SOCKET` and `TABS_PANE_ID`.
- **`requestClose` is deferred** to the next main-actor turn, so `paneWillClose` never runs inside the plugin's own call.
- **Window frames live in `layout.json`**, not user defaults: they move with the data directory and go with the window.
- **Frontmost window**: visible windows by z-order; none visible (app hidden) → the last key one.
- **⌘W** closes the key window's active pane (on the root's bar: its shown tab), or the key window itself if it isn't a
  workspace window (Settings, Plugins) — never a pane behind it (`CommandRouter.close`).
- **Signals**: plugins declare and raise kinds; `PaneSignals` decides what shows; the renderer draws every kind alike
  ([PANE-SIGNALS.md](PANE-SIGNALS.md)).

## Persistence

`DocumentStore` backs `settings.json` and `layout.json` in the data directory (`TABS_DATA_DIR`, else
`~/Library/Application Support/TabsPluginPrototype`). It never overwrites what it couldn't fully read:

| Situation | Action |
|---|---|
| Doesn't parse or decode | moved to `<name>.unreadable-<time>.json`, start fresh; if the move fails, the file is never overwritten |
| Decoded partly (a pane, window or field dropped) | copied to `<name>.partial-<time>.json` before the first save |
| `version` newer than this build's | copied to `<name>.newer-<time>.json` before the first save |
| A save can't encode | previous file kept; writes atomic; nothing throws (saves run from timers and at quit) |
| Headless (`--plugin-report`, `--control`) | read-only: nothing written, moved or copied |

- No migrations: formats change in lockstep; `version` exists only to spot a newer file.
- Tolerant decoding: defaulted fields decode when absent; top-level fields a newer build wrote are carried through.
- Recovered state: one alert at launch (stderr when hidden), and `persistence` in the report.
- Plugin settings: one blob per plugin under `plugins.<id>`; blobs of plugins not loaded this launch survive every
  save ([PLUGINS.md](PLUGINS.md#settings)).
- Panes whose plugin is missing, failed or refused the config stay unavailable and are saved back verbatim.
- Restore layout on relaunch off → `layout.json` is neither read nor written ([RESTORE-LAYOUT.md](RESTORE-LAYOUT.md)).

## Control

`ControlDispatcher` handles `{command, args, paneId, cwd}` envelopes → `{ok: true, result}` | `{ok: false, error}`, from:

- `Tabs --control '<json>'`: one request, headless, read-only (no shell, so no panes);
- the control socket (below).

`command` resolves as a qualified verb name (`tabs.info`, `browser.navigate`), else as a control-plane CLI command
(`navigate`); a bare command two verbs share is refused, naming both. Core's internal verbs: `tabs.verbs` (every
verb), `tabs.info` (pid, data directory, socket path, fingerprint), `tabs.plugins`, `tabs.shortcuts`,
`tabs.setShortcut`.

- **Internal verbs** (no `wireType`): `args` validated against the declared arguments (unknown, missing, kind,
  `enumValues`, `minimum`); `path` resolved against `cwd`; `.pane(ofTypes:)` requires `paneId` to be an open pane of
  those types; `timeout` is the deadline; errors prefixed with the verb name.
- **Control-plane verbs** (`command` + `wireType`): [below](#the-control-plane).
- Both: the caller is answered at the deadline even if the handler ignores cancellation (late result dropped, side
  effects not undone). Everything runs on the main actor: a handler that blocks without suspending can't be timed out.
  A result with NaN/∞ is refused. Core's own verbs meet the plugins' declaration rules.

### The control socket

`ControlServer`: newline-delimited JSON over a Unix-domain socket; one response line per request line, many per
connection, answered in order.

- **Per boot**: `<data dir>/control-<pid>.sock`, or `TABS_LISTEN_SOCKET` (tests). Pane ids persist across boots and
  instances, so a fixed name could reach the wrong process. Not `TABS_CONTROL_SOCKET`: panes' children get that, so a
  Tabs launched inside Tabs would take over its parent's socket.
- Stale `control-<pid>.sock` files of dead pids are removed at launch; a path another process answers on is never taken.
- Owner-only: mode 0600, and peers of another uid (`getpeereid`) are refused.
- **SIGPIPE is caught by a no-op handler, not `SIG_IGN`**: a peer that hangs up before its answer would kill the
  process; per-socket `SO_NOSIGPIPE` fails (EINVAL) once the peer has left; and an ignored disposition survives
  `exec`, so every spawned shell would ignore SIGPIPE (`yes | head -1` → "Broken pipe").
- **Can't stall**: non-blocking I/O on one serial queue that never waits for a client.
  - Per connection: reading pauses at 64 unanswered requests or 4 MiB of unread answers; a line over 16 MiB closes it;
    a client with unread answers that makes no progress for 30 s is disconnected.
  - At 64 connections a new client replaces the longest-idle replaceable one (idle, no unread bytes, and answered once
    or connected > 2 s), else waits in the listen backlog.
  - A closed connection's queued requests never run; its running one is cancelled. A last line without a newline
    still counts (`printf '{…}' | nc -U`).
- Quit saves first, then stops the server; it never waits on a client.
- Close-on-exec. macOS has no `SOCK_CLOEXEC`: a fork racing `socket()`/`accept()` can inherit a descriptor, so spawners
  should close what they don't pass (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
- From a shell: `echo '{"command":"tabs.verbs"}' | nc -U <socket>`.
- `tabs-ctl` (`resources/skills/tabs/scripts/tabs-ctl`, the one copy both apps ship; bundled as
  `Contents/Resources/skills/tabs`) relays argv into the envelope with `TABS_PANE_ID` and `TABS_CONTROL_SOCKET`. It
  settles on the first line read: the server keeps connections open, so waiting for the close would hang.

### The control plane

Port of Electron's `externalControl.ts`, `controlEnvelope.ts`, `controlDescribe.ts`. Plugin side:
[PLUGINS.md](PLUGINS.md#control-verbs-tabs-ctl).

CLI flags → typed **wire request** `{type, paneId, targetPaneId?, …}` (`ControlEnvelope.build`, coercing by the
declared arguments) → handler. A `batch` step is a raw wire request. `paneId` on the wire is always the **caller's**
pane; a verb acting on another pane names it in `targetPaneId` (CLI `--pane`).

One dispatch (`dispatch(wire:)`, `ControlPlane.swift`) for envelopes and batch steps alike, in order:

1. `type` is some verb's `wireType` (`unknown request type: …`);
2. the caller is a live pane (`not running inside a Tabs pane`) — uniformly, before anything else;
3. a named `targetPaneId` is owned by the caller (`not the owner of this pane`);
4. the request validates against the schema derived from the verb's arguments (`ControlSchema`,
   `additionalProperties: false`; `request.<field> …`);
5. the target is still open (else the pane-gone message) and of the verb's type (`target is not a browser pane`);
6. relative `path` fields resolved against `cwd` (raw wire requests too; Electron leaves that to the handler), then the
   handler runs on its budget.

Enforced once, so no plugin verb can ship without the checks.

**Ownership** (`PaneOwnership`, in `PaneRuntime`):

- A pane a verb creates belongs to the caller's pane: per app run, never persisted, never expired. Granted by
  `PaneRequest.controlledBy`, in the ledger before the pane is built; allowed only while that plugin is answering a verb
  for that caller (`verbBegan`/`verbEnded` around the handler — not after it timed out).
- Ends only when the pane is really gone (`close-pane` or the user; released in `PaneRuntime.detach`); a declined close
  keeps it.
- The refusal is uniform: a pane id is a persisted layout id, not a credential, so answers must not reveal liveness.
  The one exception: the owner of a closed pane (the ledger keeps the last 100) gets `paneGoneError`,
  `target pane no longer exists — it was closed; listOwnedPanes shows the panes still open` (SKILL.md quotes it).
- A test reset builds a new `CoreRuntime`, and with it an empty ledger.
- `ControlledSignal`: raised while owned (on attach for a pane owned from creation), gone with the pane; never on tabs;
  switch "Control indicator" in Settings ▸ Panes & Tabs.

**Core's verbs** (capability `core`, 5 s budget each):

| Command | Wire type | Does |
|---|---|---|
| `ping` | `ping` | liveness |
| `activate-pane` | `activatePane` | reveals an owned pane; never activates it or takes the keyboard |
| `close-pane` | `closePane` | closes an owned pane; asks the user first if it has a `closeWarning` (Electron never asks: its panes have none); error if not closed |
| `list-panes` | `listOwnedPanes` | the caller's panes in every window: `{paneId, type, title}` with `controlSummary` merged over; nil summary = not listed |
| `pane-info` | `getPaneInfo` | `{paneId, type, title}` with `controlDescription()` fields merged over |
| `batch` | `batch` | ≤ 50 wire steps in order, each as the batch's caller (`paneId` overwritten); stops at the first failure (`stoppedAt`, the rest `{skipped: true}`) unless `--continue-on-error`; refuses nesting and `batchable: false` verbs (`<wireType> cannot be used inside a batch`); no deadline of its own; `ok: true` whenever it ran, with a `steps` transcript |
| `capabilities` | `capabilities` | `core` plus every `ControlCapabilityContribution` (`enabled` = its plugin offers creation), one usage line per command |
| `describe` | `describe` | a capability's guide, limits and, per command, flags, derived wire schema, `resultShape` |

**Budgets**: `timeoutFor(arguments)` ?? `timeout`. Core answers `<wireType> timed out after <budget>ms` at budget +
`ControlBudget.headroom` (5 s) and cancels the handler. `ControlBudget.unbounded` = no deadline (`batch`).

## Build, gate and tests

### Build graph

- `project.yml` (XcodeGen) is the graph. Target templates carry the rules: `Stamped` (stamp phase; depends on the
  `SharedFingerprint` aggregate target, which computes the fingerprint once per build), `SharedFramework`, `Plugin`,
  `PluginTests`.
- Each plugin's `Plugins/<Name>/plugin.yml` adds its targets, its embedding into `PlugIns`, its
  `TABS_BUNDLED_PLUGIN_<ID>`, and its tests to the `Tabs` and `Plugins` schemes. `make project` includes every one
  (`Scripts/plugin-includes.sh` → `build/plugins.yml`), so adding a plugin edits no shared file.
- XcodeGen reruns only when the specs or the file list changed (`--use-cache`).

| Scheme / target | |
|---|---|
| scheme `Tabs` | app, every plugin, every test tier |
| scheme `Core` | SDK + TabsCore + `TabsCoreTests` only |
| scheme `Plugins` | every `<Name>PluginTests`, without the app |
| `make check` | `lint` + `warnings` + `test` + `verify` (Debug) |
| `make check-release` | `verify` on the universal Release build |
| `make bundle` | `check-release`, then `build/Tabs.dmg` (`Scripts/make-dmg.sh`): what a release ships |
| `make lint` | `swift-format lint --strict`, `Scripts/lint-plugin-boundaries.py`, `Scripts/sync-app-config.py --check` |
| `make test-core` / `test-plugins` (`ONLY=<Target>`) / `test-ui` / `test-e2e` | one tier |
| `make report` / `make run` | headless plugin report / launch on `build/dev-data` |

**No warnings** (`make warnings`, `Scripts/check-warnings.sh`): a clean `build-for-testing` of every target in fresh
DerivedData; fails on any `warning:` line. Clean, because an incremental build reports only recompiled files; a gate of
its own, because Swift 6.4's `-warnings-as-errors` (on project-wide) doesn't escalate AppKit main-actor isolation
warnings.

### Packaging gate

`Scripts/verify-app.sh <Tabs.app>` (`make verify`):

1. one SDK image; no other image exports `tabs_plugin_sdk_sentinel`;
2. roles: frameworks `sdk`/`core`; plugins stamped `plugin` and Mach-O bundles;
3. linkage: SDK bound as `@rpath/TabsPluginSDK.framework/…` everywhere; plugins link only `/usr/lib`, `/System` and the SDK;
4. every stamp's fingerprint = what the sources give for the app's configuration;
5. the app stamp's `bundledPlugins` = `PlugIns`; manifest ids = bundle names;
6. every file readable by other users (root-owned installs);
7. `codesign --verify --deep --strict`;
8. `--plugin-report` exits 0, and no "implemented in both" duplicate-class warning;
9. a real launch, hidden (`TABS_E2E_HIDDEN=1`, scratch `TABS_DATA_DIR`, `TABS_LISTEN_SOCKET`): answers `tabs.info`,
   every plugin active in `tabs.plugins`, quits on SIGTERM within 5 s (the GUI path, Release too);
10. the bundled skill: `SKILL.md` and an executable `scripts/tabs-ctl`, identical to `resources/skills/tabs`;
11. versions: the app, both frameworks and every plugin carry the root `package.json` version verbatim as
    `CFBundleShortVersionString` and `CFBundleVersion`.

### Version and release

- The version is the root `package.json`'s (the Electron app's), verbatim: `make project` writes
  `build/Version.xcconfig` (`Scripts/version-xcconfig.sh`), `Config/Base.xcconfig` includes it, every image's
  Info.plist reads `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`. Not part of the shared-ABI fingerprint.
- Releases ship it as `tabs-native-experimental-<version>-universal.dmg` beside the Electron dmg, both built locally
  by `scripts/build-dmgs.sh` (from `scripts/release.sh`): a `git archive` export, `make bundle`. No CI.

### Test tiers

| Tier | Target | Electron analogue | What |
|---|---|---|---|
| Core | `TabsCoreTests` (unhosted) | vitest | real runtime, inline plugins (`TestSupport.candidate`), `FakeShell`/`FakeRenderer`: rules, rollback, layout, shortcuts, persistence, control, socket |
| Plugins | `<Name>PluginTests` (unhosted) | a package's vitest | the real plugin class in a real core runtime + layout engine, no app (`PluginHarness`) |
| App and UI | `TabsAppTests` (hosted in Tabs.app) | jsdom + Chromium harness | real bundles across real image boundaries; `UIDriver`: synthesized input into the real shell in never-shown windows (clicks only on what a user could hit, chords through the real menu); offscreen snapshots; `StandIns` (`text`, `inert`) when a test just needs a pane |
| End to end | `TabsEndToEndTests` (unhosted; depends on `Tabs`: never a stale app) | Playwright on Electron | the built app as a hidden process, driven over the socket with `tabs.test.*` verbs (Debug + `TABS_E2E_HIDDEN` only); `.sharedApp` suites reset per test (`tabs.test.reset`: core, plugins, windows rebuilt on emptied data, same process); quit, relaunch and SIGKILL tests launch their own |

Both UI tiers use `InputSynthesizer`; neither goes through the OS's own event routing (that needs XCUITest and an
Accessibility grant).

## Signing

- Local builds: ad-hoc, no Hardened Runtime (`Config/Base.xcconfig`). Hardened Runtime's library validation admits only
  images with the app's Team ID; ad-hoc has none → the app would refuse its own SDK.
- Release dmgs are these local builds: ad-hoc, so a downloaded copy is quarantined (the dmg's `Read Me.txt`).
- Distribution: gitignored `Config/Signing.local.xcconfig` with `DEVELOPMENT_TEAM`,
  `CODE_SIGN_IDENTITY = Developer ID Application`, `ENABLE_HARDENED_RUNTIME = YES`. One team signs every image → no
  `disable-library-validation` entitlement needed.

## Deliberate limits

- **No crash isolation**: plugins are in-process (isolation would mean XPC and remote views).
- **Chords match characters, not physical keys**, as AppKit menus match them ([KEYBOARD.md](KEYBOARD.md)).
- **No network-capture verbs** (`read-network`, `capture-bodies`): `WKWebView` has no request observation
  ([BROWSER.md](BROWSER.md)).
- **App Transport Security is off** (`NSAllowsArbitraryLoads` in `Sources/Tabs/Info.plist`) so the browser loads plain
  `http://`, for page loads and `save-resource` alike.
- **Library validation under Hardened Runtime is unexercised**: no build has been signed with a Team ID yet.
- Per-area differences from Electron: each area doc's "Known differences".
