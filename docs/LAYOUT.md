# Layout and pane chrome

Panes, tabs, splits and floating panes: the layout model and its operations, the gestures, and
the look of pane chrome. Code: `Sources/TabsCore/Layout` (the model) and `Sources/Tabs/Workspace`
(the chrome).

## The model (`Sources/TabsCore/Layout`, pure, tested without windows)

| File | What |
|---|---|
| `LayoutTree.swift` | Nodes: `leaf` (no type = empty), `tabs` (one active), `split` (horizontal/vertical, fractional sizes, 5% min: `Tree.minPaneSize`). Every tree op: normalize, open content, split, dock a tab or pane (edge or center), move a tab (reorder, other bar, onto an empty pane), move a pane onto a bar, close, clear, wrap, ungroup, rename, resize |
| `Floating.swift` | Anchors (pin back to its container, else a surviving neighbour, else beside the active pane); clamp: 240×120 min, 80pt kept on screen, top never above 0; nine spawn positions (16pt inset, at most 640×400) |
| `Navigation.swift` | Arrow navigation, entry panes, focus after a close; separator snap (8pt) and alignment (5pt) |
| `WindowLayout.swift` | One window: docked root (always a tab group; its bar = title bar), floating panes (array order = z-order), active pane (always a leaf), its panes most recently active first (`recentPanes`: the pane each tab follows, [TAB-TITLES.md](TAB-TITLES.md)). Each action runs on the tree owning its target, rewraps the root, focuses what it created or moved. Focus aimed at a group or split stays put, unless the active pane is gone or hidden behind a tab while that container shows (then the pane it shows takes it); a tab clicked or content dropped keeps an active pane inside it, else hands focus to the pane it shows (`focus(into:)`); closing the active pane, its tab or a group holding it focuses the nearest pane left. Root id → its shown tab for split/wrap/close/clear (`redirectFromDockedRoot`); splitting the root out of itself refused (`splitsDockedRootOutOfItself`). Drops in the window, judged in the dragged subject's own tree: `canDrop`/`drop`, `tabBarDrop` (an index among the tabs that stay), `canSpringLoad`. Cross-window `extract`/`accepts`/`insert`. The chrome menus ask `canUnpin`, `canUngroup`, `canClear` |
| `LayoutModel.swift` | Every window + the last closed one (in memory). layout.json = `{windows}`, each `{id, root, activePaneId, recentPaneIds?, floating, frame}`; a leaf `{id, type, config, title?, titleIsManual?}`, a group `{id, type: "tabs", tabs: [{id, title, titleIsManual?, content}], activeTabId}`, a split `{id, type: "split", direction, children, sizes}` |
| `LayoutEngine.swift` | Core's side: plugin panes at leaves; the reconcile pass announces opens, moves, visibility, the active pane. Arrow navigation (`navigate`: `Navigation`'s pieces, panes compared where the renderer shows them). `PanePlacement`: `.automatic` (front window's active pane: into it if empty, else a tab beside it), `.tab(near:)` (open content), `.split`, `.floating(near:)` (the spawn setting's section), `.window`. The user's new panes (`NewPanePlacement`): `.tab`, `.split`, `.unpinned` (the spawn setting's section of the pane it's made from). Unpin and pin, remembering where a pane floated when it was pinned back (in memory) |

Tests: `Tests/TabsCoreTests/Layout/` — `TreeTests`, `FloatingTests`, `NavigationTests`,
`SeparatorSnapTests`, `WindowLayoutTests` (the window's rules), `LayoutCodingTests`;
`LayoutEngineTests`. UI: `UITests.DragAndDrop`, `.CrossWindow`, `.SplitResize`, `.FloatingPanes`,
`.Keyboard`, `.TabStrip`, `.TabTitles`, `.HeaderControls`, `.Chrome`, `.HeaderTitle`, `.TabShadow`,
`.Appearance`; `RendererTests`, `MenuTests`, `SplitResizerArithmeticTests` (a separator drag's
sizes, without a window); `GeometryGoldenTests`.

## What the user can do

- **Tabs.** Click shows it and moves focus into it: to the pane it shows (the entry pane),
  unless the active pane is already inside. A press on a bar's background moves no focus.
  × closes (asks first if content would lose work). "+" after the last
  tab adds one. Rename: double-click the title or right-click ▸ Edit title; Return or losing
  focus saves, Escape cancels; an emptied title clears the override (a tab gets back the title a
  new tab of its content gets, a pane its content's own). A tab shows the title of the pane last
  active in it, unless the user named it (*Tab titles follow the active pane*, on by default:
  [TAB-TITLES.md](TAB-TITLES.md)). A pane's own title change shows in its header, tab and the
  window title 500 ms later, so one that changes back meanwhile (a quick command's) never shows
  (TT-13). Natural width up to 220pt; overflow scrolls the strip sideways.
- **Header/bar controls** (revealed on hover): *Split horizontally* (hover: Split vertically, New
  tab, New unpinned tab, Wrap in tab group) and *Close pane* (hover: Clear pane, disabled on an
  empty pane). Plugin header buttons (`PaneController.headerActions`, e.g. Clear scrollback) come
  first. Docked root's bar: *New tab* (hover: New unpinned tab) instead of the split group.
- **Context menus.** Header: Edit title (not when a plugin's view fills the title slot; double-click
  neither), Unpin. Group bar: Unpin (not the root), Ungroup (single-tab group, not the root). Tab:
  Edit title, Unpin. A floating pane's own chrome: Pin.
- **Dragging.** Press on a tab or a pane's chrome (header; a group's bar or grip; never the docked
  root's bar) → drag after 5pt. Source dims to 40%, ghost with its title follows. Targets, in
  precedence order:
  - tab bar: accent bar at the insertion point (before/after the hovered tab by pointer half). In
    the dragged tab's own bar the drop index skips the dragged tab but the indicator is placed
    against the full strip, so past the dragged tab it shows one slot early
    (`TabStripView.dropIndex`; scenario `drag-tab-bar`);
  - edge zone: within ¼ of a pane's edge → that half (a tab lands as a one-tab group, a pane
    bare); within 1/10 of an enclosing group's own edge → the whole group splits; the docked
    root has no edges;
  - empty pane: dashed outline, content takes its place (edges beat it);
  - rest of a pane: merge into its group, or make one.

  Hover a tab 550ms → it opens (spring-load; source window only). Release elsewhere → ghost
  flies back (180ms), nothing changes; Escape cancels. A drag stays in its tree: floating
  content never lands in the docked layout or another floating pane.
- **Cross-window drag.** Pointer into another workspace window carries a docked tab or pane there,
  same targets. Not floating content; not into a fullscreen window unless the source is
  fullscreen too. A point inside the source window always belongs to it. Taking a window's only
  content leaves an empty pane.
- **Splits.** Separators take no space; a 10pt band grabs one. Every split whose band holds the
  pointer moves at once (crossings drag both ways). Neighbours stop at 5%, then push the next.
  *Snap resize to aligned separators* on: within 8pt of another split's separator (same
  orientation) → snaps. A drag moving several splits (a crossing) carries other separators
  aligned within 5pt. Sizes live while dragging, committed on release; a click without a drag
  activates the pane under it.
- **Floating panes.** Unpin lifts a pane or a group (tabs and all) into a floating window over its
  old place; Pin puts it back near where it came from; re-unpinning returns it to where it
  floated (this session). *New unpinned pane* (⌥⇧⌘T, or the split menu's New unpinned tab)
  opens in the section of the active pane the setting names (default top right). Moves by its
  chrome; resizes from edges (5pt) and corners (8pt); comes to front when anything in it
  activates; re-clamped when the window resizes; closes with its own pane.
- **Keyboard.** ⌘P palette ([NEW-CONTENT.md](NEW-CONTENT.md)). ⌘T new tab, ⇧⌘T split horizontally,
  ⌥⌘T split vertically, ⌥⇧⌘T new unpinned pane (each with new content like the active pane).
  ⌘W closes the active pane. ⌘←→↑↓ move focus one step within the active
  pane's tree: left/right walk a group's tabs before leaving it, up/down never reveal a hidden
  tab, past the edge wraps; brief direction overlay (Settings ▸ Panes & Tabs). Not while an
  editable text view has the keyboard, nor mid-drag. All rebindable (Settings ▸ Keyboard,
  `tabs.setShortcut`; [KEYBOARD.md](KEYBOARD.md)).
- **Windows.** Root bar = title bar: traffic lights at (14, 9) in the 30pt bar, content starts
  89pt in; background drags the window (only it: the window isn't `isMovable`, else the window
  server drags it from the tabs too); double-click follows `AppleActionOnDoubleClick` (zoom by
  default). Fullscreen: an ordinary 24pt bar; the traffic lights are AppKit's (they come down
  with the menu bar at the top of the screen; placed for the root bar they'd fall out of the
  window AppKit moves the title bar into). View ▸ Enter/Exit Full Screen, always the menu's
  last item (core's ⌃⌘F item, which AppKit shows as its own fn-F one; both chords work), and
  the green button toggle it; Esc stays the pane's. ⌘N: 1200×800, cascaded 24pt from the front
  window (back to the work area's corner if it wouldn't fit); the first is centered.
- **Look.** The theme chosen in Settings ▸ Panes & Tabs ▸ Theme (System, Light, Dark, then the
  rest by name): every theme is a file of `PaneTheme`'s tokens in `Sources/Tabs/Resources/Themes`
  ([THEMES.md](THEMES.md)). Bars and headers alternate two shades by tab-group
  depth; indent 7pt per level. Only a pane that holds content (a leaf) is ever active, never a
  group or a split: outlined around its content (never its bar) in accent. Inactive content dims (grayscale, then brightness, in
  sRGB).
- **Theme is app-wide** ([THEMES.md](THEMES.md)). The app's own windows (Settings, Plugins,
  About, Caffeinate) are painted from the theme's tokens (`ThemedRoot`, `NSWindow.paint(with:)`);
  `AppShell` pins `NSApp.appearance` to the theme's dark or light (`NSAppearance.pinned(by:theme:)`;
  `system` = nil), so what macOS draws — alerts, file panels, menus, tooltips, web pages'
  `prefers-color-scheme` — follows live. Exception: the "Tabs is damaged" alert runs before
  settings load → follows the OS. Tests: `UITests.Appearance`, `UITests.ThemeReach`;
  `UITests.AppearanceSnapshots` renders each surface in every theme against a disagreeing OS
  (`TEST_RUNNER_TABS_SNAPSHOT_DIR`).

## How the chrome is drawn (`Sources/Tabs/Workspace`)

| File | What |
|---|---|
| `Chrome.swift` (`Metrics`, `ChromeText`, `ChromeIcon`, `ChromeControl`) | The panes' chrome lengths, text line box, chrome icons; the buttons' shared hover, press and accessibility (`ChromeControl`), and the icon button with its wash (`ChromeIconButton`) |
| `PaneViews.swift`, `TabStrip.swift` | Panes, headers, controls, bars, tabs |
| `TreeViews.swift`, `PaneBodies.swift` | Tree hosts and overlays, floating windows, pane bodies, empty panes |
| `DragController.swift` | Drag and drop, in and across windows: the gesture, the ghost, spring-load timing, and the geometry (which bar and index, which pane and zone, which empty pane); core says whether a target takes the drop and applies it |
| `SplitResizer.swift` | Separator drags, snapping, clusters |
| `WorkspaceInput.swift` | The navigation chords (the engine's `navigate` decides where focus goes) and their flash, click-to-activate |
| `Overlays.swift` | Header menus, context menus, title editor, nav flash, floating move/resize; the overlays' panel (`OverlayPanel`) and drop shadows (`applyOverlayShadow`) |
| `Palette.swift` | The ⌘P palette ([NEW-CONTENT.md](NEW-CONTENT.md)) |
| `Dialogs.swift` | A pane's question as a card over its window (`PaneDialog`) |
| `Signals.swift` | Signal icons in headers and tabs, and the cue outlines ([PANE-SIGNALS.md](PANE-SIGNALS.md)) |
| `Theme.swift` | `Theme` (the SDK's `PaneTheme`), color mixing, the dimming of inactive panes (`Dimming`), `PaneAppearance` (what the chrome is drawn with) |
| `WorkspaceRenderer.swift` | Core's `LayoutRenderer`: a window per `WindowLayout`, a body per leaf, reconciled by id; new windows' frames |
| `WorkspaceWindowController.swift` | One window: one view per node (`build`), what its chrome asks (`ChromeHost`), the chrome menus, full screen, the traffic lights |

- One view per node, reused while the node lives (`WorkspaceWindowController.build`); a leaf's
  `PaneBodyHost` (holding the plugin's view) lives as long as the leaf, wherever it moves.
- The panes' chrome takes its lengths from `Metrics` (bars, tabs, header buttons and their icon
  boxes, the wash, the rename field); each overlay (the palette, dialog cards, menus, the drag
  ghost, the nav flash) keeps its own beside its drawing. Text: a line box of the font's rounded
  ascent plus descent, baseline on a whole point.
- Layout fractional, carried down unsnapped (`FlippedView.layoutFrame`); only painting snaps: box
  edges on whole window points, text keeps its fractional x.
- Active outline, signal outlines ([PANE-SIGNALS.md](PANE-SIGNALS.md)) and the dock preview (on
  top) are drawn by each tree's `TreeOverlayView` above its panes: an outline may cross a
  neighbour's border.
- Tooltips: AppKit's, at the system's delay, like the plugins' and Settings'. A whole control
  carries its label as `toolTip`; a part of a view (a tab's close button, a header menu's rows, an
  empty pane's buttons) gets a tool tip rect whose owner, the view, names the text when AppKit
  asks. Tests: `UITests.ChromeTooltips` (the text; showing one needs a real pointer).

## Implementation notes

- **Cross-window moves are all or nothing**: every window is in one process, so a move takes the
  content out of one window's layout and puts it into the other's in one step
  (`WindowLayout` `extract`/`insert`); nothing to relay or roll back.

## Checking the look

`Visual/` (see its README) holds scenarios: windows the real engine and renderer put on screen,
never shown (`Tabs --render-scenarios`, Debug; `Visual/capture.sh`). Each renders to a 2x PNG and
the geometry of every pane, bar, tab, title, control and separator.

```
make visual-baseline                 # capture every scenario with the build before a change
make visual                          # capture them with the current build, compare with the baseline
make visual ONLY="two-tabs l-shape"  # a subset (any visual target)
open build/visual/compare/index.html
make visual-golden                   # re-record the goldens after an intended change
```

- **Gate:** `Visual/golden/<name>.geometry.json`, recorded from the app.
  `GeometryGoldenTests/theGeometryMatchesTheGolden` (in `make check`) holds every scenario's
  geometry to its golden within 0.5pt; `GeometryGoldenTests/everyScenarioHasAGolden` requires one
  per scenario. After an intended change to the chrome, or for a new scenario, re-record with
  `make visual-golden` and review the golden diff.
- **Pixels:** `make visual` (`compare.py`) diffs pixels and flags any rect edge moved > 0.5pt
  against the baseline; nothing gates on it.
- Layout scenarios: every one without an area prefix (`signal-`, `browser-`, `git-tree-`,
  `caffeinate-`, `palette-`): splits, grids, nesting, floating, fullscreen, both themes, hovers,
  context menu, drags mid-flight (`drag-dock-right`, `drag-dock-center`,
  `drag-tab-bar`).
