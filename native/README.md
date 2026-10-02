# Tabs native

macOS core (Swift 6, AppKit) whose features come from plugins: separately built
`.tabsplugin` bundles, released in lockstep with the core, isolated from each other, seeing
only the SDK. Content types (terminal, browser, git tree) and the rest of the UI are ports of
the Electron app at the repository root.

## Docs

- [ARCHITECTURE.md](docs/ARCHITECTURE.md): how it fits together, the rules it enforces, why.
- [PLUGINS.md](docs/PLUGINS.md): writing a plugin.
- [Visual/README.md](Visual/README.md): the look-comparison pipeline (scenario keys, geometry format).
- Port docs, one per area: [LAYOUT](docs/LAYOUT.md) (pane management, chrome),
  [NEW-CONTENT](docs/NEW-CONTENT.md) (creation chords, ⌘P palette),
  [KEYBOARD](docs/KEYBOARD.md) (Settings ▸ Keyboard), [PANE-SIGNALS](docs/PANE-SIGNALS.md)
  (bell, controlled cue), [TERMINAL](docs/TERMINAL.md), [BROWSER](docs/BROWSER.md) (+ the
  `tabs-ctl` control plane), [GIT-TREE](docs/GIT-TREE.md), [ABOUT](docs/ABOUT.md),
  [CAFFEINATE](docs/CAFFEINATE.md), [RESTORE-LAYOUT](docs/RESTORE-LAYOUT.md).

Port-doc conventions:
- The Electron app is the spec: where the two disagree, Electron is right unless a row is
  marked **Deviation** or listed under Known differences.
- Case ids (`P-8`, `J-12`) are cited by tests and code (`// P-8`). Never renumber or reuse one.
- `Native test` names the tests that pin a case (`Suite/test`; nested `UITests.X/test`).

## Commands

Requires Xcode 27 and [mise](https://mise.jdx.dev) (runs the pinned XcodeGen).
`Tabs.xcodeproj` is generated from `project.yml` + `Plugins/*/plugin.yml`; never committed.

```sh
make check          # required for every change: lint + no warnings + every test tier + packaging gate
make check-release  # packaging gate (real launch included) on the universal Release build
make bundle         # check-release, then build/Tabs.dmg: what a release ships
make test           # every tier; or test-core / test-plugins [ONLY=…] / test-ui / test-e2e
make lint           # swift-format --strict, plugin boundary lint, About's generated config check
make run            # launch with scratch data (build/dev-data)
make report         # headless plugin report: what loaded, and why not
make visual         # capture both apps and compare (Visual/README.md)
make format         # swift-format in place
make help           # everything else

Scripts/new-plugin.py <id> [--content-type]   # scaffold a plugin: one folder, no shared edits
```

Headless modes (any built app; no windows; read-only, never write/move/copy user files):

```sh
Tabs.app/Contents/MacOS/Tabs --plugin-report                      # exit 1 if any plugin is broken
Tabs.app/Contents/MacOS/Tabs --control '{"command":"tabs.verbs"}' # every verb and its arguments
Tabs.app/Contents/MacOS/Tabs --control '{"command":"tabs.plugins"}'
```

Exit 2 if the bundle mixes builds. Debug builds also take `--plugins-dir <path>`.

A running app listens on a per-boot control socket, `<data dir>/control-<pid>.sock`:
`tabs.info` reports it; pane processes get it as `TABS_CONTROL_SOCKET`.

```sh
echo '{"command":"tabs.verbs"}' | nc -U "$SOCKET"
```

Environment:
- `TABS_DATA_DIR`: settings, layout, socket (default
  `~/Library/Application Support/TabsPluginPrototype`).
- `TABS_LISTEN_SOCKET`: fixed socket path (tests).
- `TABS_E2E_HIDDEN=1`: never show windows or take focus (end-to-end tests).

All three are stripped from pane processes' environment (`childEnvironment`).

## Layout

```
Sources/TabsPluginSDK/   the SDK: all plugins can see
Sources/TabsCore/        plugin runtime (discover → resolve → load → activate), contribution registry,
                         panes, layout model and engine, shortcuts, persistence, control
Sources/Tabs/            AppKit shell: renders core's layout, menus, pane chrome, windows
Plugins/<Name>/          one plugin each: Info.plist manifest, Sources/, Tests/, plugin.yml
Tests/TabsCoreTests/     core with in-process plugins, fake shell and renderer (unhosted)
Tests/TabsAppTests/      real bundles, the shell, UI tier (UIDriver), snapshots (hosted)
Tests/TabsEndToEndTests/ the app as its own process, over the control socket
Tests/Support/           shared helpers (TestSupport, Fakes, PluginHarness, StandIns, FixtureServer)
Tests/Fixtures/          test-only plugin bundles
Scripts/                 build stamp, fingerprint, version, packaging gate, dmg, boundary lint, warnings, scaffold
Visual/                  look comparison with the Electron app
Config/                  signing (Base.xcconfig; optional gitignored Signing.local.xcconfig)
../resources/skills/tabs the `tabs-ctl` skill, shared with the Electron app, bundled unchanged
```
