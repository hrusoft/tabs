# Developing Tabs

A macOS core (Swift 6, AppKit) whose features come from plugins: separately built `.tabsplugin` bundles, released in
lockstep with the core, isolated from each other, seeing only the SDK. Content types (terminal, browser, git tree) are
plugins; the core and the AppKit shell provide panes, layout, windows, settings and the control plane.

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md): how it fits together, the rules it enforces, why.
- [PLUGINS.md](PLUGINS.md): writing a plugin.
- [Visual/README.md](../Visual/README.md): the look scenarios, geometry goldens and the visual compare.
- One spec per area: [LAYOUT](LAYOUT.md) (pane management, chrome), [NEW-CONTENT](NEW-CONTENT.md) (creation chords,
  ⌘P palette), [KEYBOARD](KEYBOARD.md) (Settings ▸ Keyboard), [PANE-SIGNALS](PANE-SIGNALS.md) (bell, controlled cue),
  [TERMINAL](TERMINAL.md), [BROWSER](BROWSER.md) (+ the `tabs-ctl` control plane), [GIT-TREE](GIT-TREE.md),
  [ABOUT](ABOUT.md), [CAFFEINATE](CAFFEINATE.md), [RESTORE-LAYOUT](RESTORE-LAYOUT.md).

Spec conventions:
- Case ids (`P-8`, `J-12`) are cited by tests and code (`// P-8`). Never renumber or reuse one.
- A case's `Test` column names the tests that pin it (`Suite/test`; nested `UITests.X/test`).

## Commands

Requires Xcode 27 and [mise](https://mise.jdx.dev) (runs the pinned XcodeGen). `Tabs.xcodeproj` is generated from
`project.yml` + `Plugins/*/plugin.yml`; never committed.

```sh
make check          # required for every change: lint + no warnings + every test tier + packaging gate + scaffold, side by side
make check-release  # packaging gate (real launch included) on the universal Release build
make bundle         # check-release, then build/Tabs.dmg: what a release ships
make test           # every tier, bundles in concurrent lanes (LANES=4; build/test-results.noindex); or test-core /
                   # test-plugins [ONLY=…] / test-ui / test-e2e
make test-verbose   # every tier, each test printed as it starts and finishes (watching a run by hand)
make warnings      # fail on any warning standing in the build; warnings-clean: from a clean build
make lint           # swift-format --strict, plugin boundary lint, tests' temporary files, About's generated config check
make run            # launch with scratch data (build/dev-data)
make report         # headless plugin report: what loaded, and why not
make visual         # capture the look scenarios and compare with make visual-baseline's (Visual/README.md)
make format         # swift-format in place
make help           # everything else

Scripts/new-plugin.py <id> [--content-type]   # scaffold a blank plugin: one folder, no shared edits (make check-scaffold)
Scripts/release.sh                            # cut a release (the create-release skill)
```

Headless modes (any built app; no windows; read-only, never write/move/copy user files):

```sh
Tabs.app/Contents/MacOS/Tabs --plugin-report                      # exit 1 if any plugin is broken
Tabs.app/Contents/MacOS/Tabs --control '{"command":"tabs.verbs"}' # every verb and its arguments
Tabs.app/Contents/MacOS/Tabs --control '{"command":"tabs.plugins"}'
```

Exit 2 if the bundle mixes builds. Debug builds also take `--plugins-dir <path>`.

A running app listens on a per-boot control socket, `<data dir>/control-<pid>.sock`: `tabs.info` reports it; pane
processes get it as `TABS_CONTROL_SOCKET`.

```sh
echo '{"command":"tabs.verbs"}' | nc -U "$SOCKET"
```

Environment:
- `TABS_DATA_DIR`: settings, layout, socket (default `~/Library/Application Support/com.hrusoft.tabs`; a Debug build is
  `com.hrusoft.tabs.debug`, so it never shares data, preferences or WebKit stores with an installed Tabs).
- `TABS_LISTEN_SOCKET`: fixed socket path (tests).
- `TABS_E2E_HIDDEN=1`: never show windows or take focus, and run as a background process: no Dock tile, no menu
  bar (end-to-end tests).
- `TABS_E2E_PLUGINS=<dir>`: hidden Debug builds also start the plugin bundles there, unreconciled with the
  stamp (the end-to-end tests' `fixture-text`).

All four are stripped from pane processes' environment (`childEnvironment`).

## Layout

```
Sources/TabsPluginSDK/       the SDK: all plugins can see
Sources/TabsCore/            plugin runtime (discover → resolve → load → activate), contribution registry, panes,
                             layout model and engine, shortcuts, persistence, control
Sources/Tabs/                AppKit shell: renders core's layout, menus, pane chrome, windows
Sources/Tabs/Resources/skills/tabs   the "control Tabs" skill (SKILL.md, scripts/tabs-ctl), bundled unchanged
Sources/TabsCtl/             tabs-ctl: the skill's relay to the control socket, Contents/Helpers/tabs-ctl
Plugins/<Name>/              one plugin each: Info.plist manifest, Sources/, plugin.yml, and its tests:
                             Tests/ (unit), Tests/UI/ (hosted UI tier), Tests/E2E/ (end to end); Visual/ (its scenarios)
Tests/TabsCtlTests/          tabs-ctl's argv, request and exit-code rules (unhosted)
Tests/TabsCoreTests/         core with in-process plugins, fake shell and renderer (unhosted)
Tests/TabsAppTests/          core's: the bundles, the shell, UI tier on stand-ins, snapshots, geometry goldens (hosted)
Tests/TabsEndToEndTests/     core's: the app as its own process, over the control socket
Tests/AppSupport/            the UI tier's helpers (UIDriver, Fixture), core's and every plugin's
Tests/EndToEndSupport/       the end-to-end tier's helpers (LaunchedApp), core's and every plugin's
Tests/Support/               shared helpers (TestSupport, Fakes, PluginHarness, StandIns, FixtureServer)
Tests/Fixtures/              test-only plugin bundles (fixture-throws, fixture-text)
Scripts/                     build stamp, fingerprint, packaging gate, dmg, boundary lint, warnings, scaffold, release
Visual/                      core's look scenarios and geometry goldens; capture and compare (every plugin's too)
Config/                      version (Version.xcconfig), signing (Base.xcconfig; optional gitignored Signing.local.xcconfig),
                             and AppConfig.plist: the About window's donation links and addresses (Scripts/sync-app-config.py
                             generates Swift from it; agents may not edit it)
Artwork/icon.svg             the app icon's source (the app-icon skill regenerates the AppIcon set from it)
```
