# Visual comparison: Electron vs native

Each `scenarios/<name>.json` is rendered by both apps; `compare.py` diffs pixels and element
geometry; `VisualParityTests` holds native geometry to the committed Electron dumps in `golden/`.
See also [docs/LAYOUT.md](../docs/LAYOUT.md).

## Running

From `native/`:

```
make visual [ONLY="name …"]        # visual-electron + visual-native (builds first) + compare.py
node Visual/capture-electron.mjs [--out DIR] [--headed] [names…]
    # -> build/visual/electron/<name>.png + <name>.geometry.json
Visual/capture-native.sh [names…]  # needs the Debug build (make build); make visual-native builds
    # -> build/visual/native/<name>.png + <name>.geometry.json
python3 Visual/compare.py [--electron DIR] [--native DIR] [--out DIR] [--scenarios DIR]
        [--threshold 24] [--tolerance 0.5] [--ignore X,Y,W,H …] [names…]
    # -> build/visual/compare/{index.html, summary.txt, <name>.diff.png, <name>.side.png}
```

- **Electron**: needs the repo root's `node_modules` (vite, playwright + Chromium). Own vite server
  (`vite.harness.config.ts`, free port) → `src/renderer/harness.html` in headless Chromium, 2x,
  `timezoneId: 'UTC'`, color scheme from `colorTheme`. Exit 1 if any scenario fails.
- **Native**: `Tabs --render-scenarios <dir> --out <dir> [names…]` (Debug only, `VisualCapture.swift`),
  `TZ=UTC`, scratch `TABS_DATA_DIR`; real engine and renderer in a never-shown window. Exit 1 if any
  scenario fails.
- **compare.py**: Python 3 + Pillow + numpy. Exit 0 whatever it finds, 2 when inputs are missing.
- **Goldens**: `VisualParityTests/everyScenarioHasAGolden`;
  `VisualParityTests/theGeometryIsTheElectronApps` diffs each scenario's native geometry as
  `compare.py` does (tolerance 0.5, `TZ=UTC`, no pixels). New or changed scenario → Electron
  capture, copy `build/visual/electron/<name>.geometry.json` into `golden/`.
- Both comparers flatten whatever keys the dumps hold: a new geometry block changes both captures,
  never the comparers.

## Scenario files (`scenarios/<name>.json`)

| Key | Meaning |
|---|---|
| `description` | What the capture must show (shown in `compare.py`'s report) |
| `size` | `{width, height}`: the window's content size, points = CSS px |
| `settings` | Partial `Settings` (`src/shared/settings.ts`) over the defaults; always has `colorTheme` (`dark`/`light`). Native applies only `colorTheme`, `dimInactivePanes`, `dimInactivePanesIntensity`, `snapResizeSeparators`, `enableBellIndicator`/`enableControlIndicator` (with `signals`), `disabledContentTypes` (creation actions), `contentTypes.gitTree`; map any other in `VisualCapture.stage` |
| `layout` | `LayoutSnapshot` (`src/shared/layout.ts`): `{version: 1, root, activePaneId, floating}`, `root` a tabs group. Leaves: `empty`; `gitTree` (config `{cwd, branchScope?, detailFraction?, detailCollapsed?}`; needs `gitTree`); `browser` (config `{url}`, leaf `title` = the page title shown; needs `browser`). Node ids are the geometry keys. Native renames `gitTree` → `git-tree` |
| `pointer` | `{x, y}`: mouse there, no buttons |
| `drag` | `{from, to}`: left button down at `from`, 10 steps to `to`, captured while held |
| `fullscreen` | `true`: native fullscreen (root bar loses its traffic-light gutter and extra height) |
| `caffeinate` | `true`: caffeinate running → the cup before Settings on the root bar (Electron: `emitCaffeinateRunningChanged(true)`; native: `PaneAppearance.caffeinateRunning`) |
| `contextMenu` | `{x, y}`: right-click there (Electron's pointer stays there) |
| `palette` | `{step: "type" \| "placement", highlight?, hover?}`: ⌘P palette open; `placement` = first row chosen; `highlight` = that many ArrowDown; `hover` = pointer on that row's center (takes the highlight). Electron fails unless step, row count and highlight match |
| `paletteTypes` | Integer ≥ 0: extra stub types after the stub (`sample-<n>`, "Sample <n>", "New sample <n>", icon ▣, n from 2), for lists over nine rows |
| `tooltip` | `true`: wait for the hover tooltip (400 ms delay) and capture it; otherwise tooltips are hidden |
| `signals` | `{"<leaf id>": ["bell" \| "controlled", …]}`, raised before any pointer step. `bell` rings as if the window were unfocused (kept on the active pane); `controlled` = owned by another pane. Electron fails unless each pane shows its cue, or doesn't when `enableBellIndicator`/`enableControlIndicator` is false |
| `pulse` | Seconds: every CSS animation (cue pulses, `::after` included) held at that time; without it pulses show at their peak (opacity 1). Bell cycle 3 s, controlled 4.5 s; both at their 0.3 trough at 0 |
| `gitTree` | `{"<leaf id>": {…}}`, exactly one leaf (the fake git is global). Below |
| `browser` | `{"<leaf id>": {…}}`, one per browser leaf. Below |
| `creationActions` | `["browser"]` (the only value): empty panes also offer "New browser" (globe) before the stub; otherwise the stub alone |
| `ignore` | `[[x, y, w, h], …]`: CSS-px regions `compare.py` leaves out of the pixel diff |

- Coordinates: content area, top-left origin, y down (flip AppKit's). Take pointer and drag points
  from the Electron dump.
- Step order, both sides: fullscreen → contextMenu → palette → pointer → drag, then settle
  (Electron 400 ms; native 450 ms, 800 with `tooltip`). Without `pointer`, `drag`, `contextMenu` or
  a palette `hover`, the pointer is off the window.

### `gitTree` entry

- Exactly one of `log` `{root, commits: [Commit…], hasMore, hasUncommittedChanges}` or `failure`
  (a `GitFailure`: `git-missing`, `no-such-directory` `{path}`, `not-a-repo` `{path}`, `no-commits`
  `{root}`, `failed` `{message}`).
- `details` `{"<hash>": CommitDetail}`: an unset hash gets one synthesized from its log entry
  (message = subject, no files).
- `workingTree`: a `CommitDetail` (hash `""`). `head`: a `GitHead` (default
  `{kind: "branch", name: "main"}`).
- `select`: a hash, or `""` for the working-tree row (needs `hasUncommittedChanges`); default the
  newest commit. Electron clicks it with a DOM click event (pointer stays away); native
  `pane.select`.
- Shapes: `packages/plugin-gitTree/shared/types.ts`. Dates ISO, shown in UTC.
- Electron fails unless the path bar, the row count, the HEAD label, the selection and (unless
  collapsed) the selected detail's message and file count match; the detail read is debounced
  100 ms. Native: `git-tree.test.script` settles every pane.

### `browser` entry

`{"page": "#2b3a55", "canGoBack"?: bool, "canGoForward"?: bool, "focusAddress"?: bool}`

- `page`: the stand-in page's solid CSS color. Page text is never compared.
- `canGoBack`/`canGoForward` (default false): history flags → Back/Forward enabled.
- `focusAddress`: address field focused without the pointer (Electron: script `focus()`; native:
  first responder).
- The address bar shows the leaf's `config.url` (default `about:blank`); the title segment its
  `title` (absent without one). Hover: `pointer`; controlled cue: `signals`.
- Both captures fail unless the chrome shows exactly this: button states, address, title, focus.

## Output: `<name>.png`

The content area only, at 2x (`2·width × 2·height` px), sRGB. No title bar, window shadow or
traffic lights on either side; the root bar's 89pt gutter is empty. `compare.py` composites
transparent pixels on magenta.

## Output: `<name>.geometry.json`

- Rects are `[x, y, width, height]`: CSS px = points, content coordinates, top-left origin, 2
  decimals, border box.
- Only what's rendered: a background tab's subtree is absent (Electron: `display: none`), never
  zero-sized.
- Opacity-hidden controls (hover-revealed buttons, a tab's close) are laid out and reported, with
  `visible` where the shape has it.
- Not clipped by scrolling ancestors (`many-tabs`: its last tabs sit past the strip's end).
- Empty object `{}`; absent thing `null`. Keys marked "omitted" are left out when not applicable, so
  older goldens hold.
- Text rects: the text's line box (a Range), clipped to its element. Baselines: the bottom of a
  zero-size inline-block probe.

```jsonc
{
  "scenario": "split-horizontal",             // Electron only; ignored by both comparers
  "size": {"width": 1200, "height": 800},
  "panes": {                                  // every pane: leaves AND tab groups (not splits)
    "<node id>": {
      "rect": R,                              // the pane box, own border included
      "body": R,                              // leaf: below the header; group: inside the border (tab bar included)
      "header": R | null,                     // leaf title bar (groups have a tab bar instead)
      "title": R | null,                      // header title's text line box, clipped to its label;
      "titleBaseline": number | null,         //   all three null when a plugin draws the title
      "titleText": string | null,             //   (git tree, browser); "Empty pane" for empty leaves
      "grip": R | null,                       // the header's grip glyph
      "depth": int,                           // tab groups enclosing it (root = 0)
      "active": bool,                         // == layout.activePaneId
      "dimmed": bool,                         // content dimmed: inactive leaf with dimInactivePanes on
      "dragging": bool,                       // this pane is the drag source
      "signalIcons": {"bell": R, "controlled": R},  // header cue icons (16×16, after the grip);
                                              //   only the kinds shown; omitted when none
      "cue": "bell" | "controlled"            // the cue coloring the content outline (controlled wins);
                                              //   omitted when none
    }
  },
  "tabBars": {
    "<tabs group id>": {
      "rect": R, "strip": R,                  // the bar, and the tab strip inside it
      "root": bool,                           // the docked root's bar
      "grip": R | null,                       // null on the root bar
      "newTab": R | null,                     // "+" after the last tab (laid out even while hidden)
      "settings": R | null,                   // gear button, root bar only
      "caffeinate": R,                        // the cup, root bar only, while caffeinate runs; omitted otherwise
      "tabs": {
        "<tab id>": {
          "rect": R,
          "title": R,                         // text line box, clipped to titleBox
          "titleBox": R,                      // the title label (max-width truncation shows here)
          "baseline": number,
          "text": string, "truncated": bool,  // truncated = drawn with an ellipsis
          "close": R,                         // close button (visible only on hover)
          "active": bool, "dragging": bool,
          "signalIcons": {"bell": R}          // bell before the title on a tab holding a ringing pane
                                              //   (never "controlled"); omitted when none
        }
      }
    }
  },
  "controls": {                               // header / tab-bar button rows, keyed by the owning pane id
    "<pane id>": {
      "rect": R,
      "visible": bool,                        // revealed (chrome hovered)
      "buttons": {"<button id>": R},          // the row's root buttons
      "separator": R | null,                  // 1px divider between the creation and destructive groups
      "dropdown": {"rect": R, "items": {"<button id>": R}} | null   // an open hover menu
    }
  },
  "separators": {"<split id>:<i>": R},        // i = index of the child after it (from 1); 0 thick
  "floating":   {"<floating id>": R},         // floating window frames
  "emptyToolbars": {"<pane id>": {"rect": R, "buttons": [R, …]}},  // empty-pane creation buttons
  "dockPreview": R | null, "dockPreviewPane": id | null,
  "emptyDropTarget": id | null,               // empty pane showing the dashed drop outline
  "dragGhost": R | null, "dragGhostText": string | null,
  "dropIndicator": R | null,                  // accent bar between tabs
  "tooltip": {"rect": R, "text": string} | null,
  "contextMenu": R | null,                    // an open context menu
  "gitTree": {…},                             // omitted without a git tree; see below
  "browser": {…},                             // omitted without a browser; see below
  "palette": {…}                              // omitted unless the palette is open; see below
}
```

Button ids are the app's test ids. The root bar's row is `pane-new-tab-button` +
`pane-close-button`; every other row `pane-split-horizontal-button` + `pane-close-button`. Dropdown
items: `pane-split-vertical-button`, `pane-new-tab-button`, `pane-new-unpinned-tab-button`,
`pane-tab-group-button`, `pane-clear-button`, …; a dropdown's first row repeats its root button as
`<root id>-menu-item`.

### Git trees (`gitTree`)

- Electron: the real git tree, the package's own content def seeded from the scenario
  (`packages/plugin-gitTree/testing/visualCapture.ts`). The toolbar (path input, browse button, HEAD
  label, branch-scope select) is the header's `HeaderTitle`; the body is `.git-tree-container` (list
  and detail).
- Native: `git-tree.test.geometry` reports in the git tree view's coordinates, the toolbar keys
  (`pathInput` … `selectBaseline`) in the header title view's; `VisualCapture` offsets each
  (`Staged.headerTitleKeys`).
- `pathBaseline`/`selectBaseline`: a form control can't hold a probe → measured on a hidden stand-in
  laid over it (same border box, padding, borders, font; one line centered in the content box, as
  Chromium places a text field's editor and a menulist's label). Matches the pixels and the HEAD
  label's probed baseline.
- Text rect over wrapped text (a long file path): the Range's bounding box, spanning every line.

```jsonc
"gitTree": {
  "<leaf id>": {
    "container": R,                           // .git-tree-container (= the pane body)
    "pathInput": R,                           // toolbar parts: in the header
    "browse": R,                              // the folder button
    "pathBaseline": number | null,            // the input's text baseline (stand-in)
    "head": R | null, "headText": R | null, "headBaseline": number | null,   // HEAD label box, its text; null without a log
    "select": R,
    "selectBaseline": number | null,          // the select's label baseline (stand-in)
    "state": "loading" | "list" | "notice",
    "notice": R | null,                       // the notice box (loading or failure)
    "noticeLines": [{"text": R, "baseline": number}],   // each <p> of the failure notice
    "list": R | null,                         // the scrolling commit list
    "rows": {                                 // every row, including ones scrolled out of view (not clipped)
      "<full hash, or 'working-tree'>": {
        "rect": R, "gutter": R,               // the row; its graph
        "hash": R | null, "hashBaseline": number | null,          // null on the working-tree row
        "subject": R,                         // the subject box (refs + text, flex 1, ellipsis)
        "subjectText": R | null,              // the subject's own text (after the pills), clipped to the box
        "subjectBaseline": number | null,
        "truncated": bool,                    // drawn with an ellipsis
        "refs": [R, …],                       // ref pill boxes, in order
        "author": R | null, "date": R | null, // text rects, when those columns are on
        "selected": bool, "phantom": bool     // phantom = the dimmed working-tree row
      }
    },
    "loadMore": R | null,                     // the Load more button box
    "divider": R | null,                      // 0 tall while the details are open, 8 collapsed
    "dividerCollapsed": bool,
    "detail": R | null,                       // the detail panel (null while collapsed)
    "message": R | null,                      // its <pre> box
    "fields": [{"dt": R, "dd": R}],           // text rects, in order (Commit, Author, Date, Parent(s), Refs)
    "files": [{"row": R, "stat": R,           // boxes
               "insertions": R | null, "deletions": R | null, "binary": R | null, "path": R}],  // text rects
    "detailNotes": [R]                        // text rects of the detail's dim paragraphs ("No files changed…")
  }
}
```

### Browsers (`browser`)

- **Electron**: `<webview>` doesn't render in the harness → real chrome around a stand-in
  (`packages/plugin-browser/testing/visualCapture.ts`, seeded via `window.__tabsVisualBrowser`).
  Header: `BrowserHeaderTitle` (Back, Forward, Refresh, address bar = title segment + input),
  history flags from a fake `BrowserInstance` published through the real `acquireBrowser`. Body:
  `.browser-content` > `.browser-webview` box in the page color.
- **Native** (`VisualCapture.stageBrowser`): real Browser plugin and `WKWebView`; the leaf's `url`
  and `title` are held aside, the pane starts on `about:blank`, nothing is fetched.
  - Pages are fixture files loaded for real (`browser.test.load`) so Back/Forward are real history:
    `#3a3a3a` "Previous"/"Next" fixtures around the page, Forward via `history.back()`. Not
    `loadHTMLString` (WebKit replaces the entry), not an unclicked `pushState` (adds none).
  - `browser.test.chrome` then shows the layout's URL and blanks the title where the layout has
    none (a title-less page gets a URL-derived one).
  - Focus: first responder, selection collapsed, caret hidden.
  - Pixels: `WKWebView` draws out of process → each page's `takeSnapshot` goes into the view's layer
    while the tree renders, dimmed by hand (`CALayer.render(in:)` ignores Core Image filters); cue
    glow and frame composite over it.
  - Nav-button hover: synthesized `mouseEntered` to the header view under the pointer (a
    never-shown window has no tracking).
  - Block from `browser.test.visual`, in the header title view's coordinates, offset to the window.
- Text rects: line boxes clipped to their element; the input's baseline via a stand-in (as
  `pathBaseline`). The header is `panes.<leaf>.header`; a controlled pane's cue icon is in
  `panes.<leaf>.signalIcons`.

```jsonc
"browser": {
  "<leaf id>": {
    "page": R,                        // the page (native: the WKWebView's frame) = the pane body
    "back": R, "forward": R, "refresh": R,   // the buttons' boxes (23×17, 13×13 icons)
    "backDisabled": bool, "forwardDisabled": bool,   // drawn at opacity 0.35, no hover wash
    "addressBar": R,                  // the bordered pill (height 20, border included)
    "titleSegment": R | null,         // null without a title; capped at 30% of the bar
    "titleText": R | null,            // the title's text line box, clipped to the segment
    "titleBaseline": number | null,
    "titleString": string | null,
    "titleTruncated": bool,           // drawn with an ellipsis
    "addressInput": R,                // the text field's box, inside the bar's border
    "addressText": R,                 // the typed text's line box, clipped to the field's content box
    "addressBaseline": number,
    "addressValue": string,
    "focused": bool                   // the address input has focus (the bar's border is the accent)
  }
}
```

### Palette (`palette`)

Only while the ⌘P palette is open.

```jsonc
"palette": {
  "step": "type" | "placement" | "empty",   // "empty": no rows, the sentence instead
  "backdrop": R, "panel": R,
  "rows": [{
    "rect": R, "highlighted": bool,
    "badge": R | null, "badgeText": R | null, "badgeBaseline": number | null,   // rows 1–9 only
    "icon": R, "label": R, "labelBaseline": number, "text": string
  }],
  "empty": {"text": R, "baseline": number, "string": string} | null
}
```

A badge is an inline-flex box, where a probe would become a flex item of its own: Electron takes
its baseline with the text wrapped in a span.

## What `compare.py` reports

- **Pixels**: a pixel differs when its largest channel delta exceeds `--threshold` (default 24,
  absorbs antialiasing). Per scenario: % differing, max and mean delta, the largest clusters as
  CSS-px boxes. A size mismatch is reported; the missing area counts as differing.
  - `diff.png`: native in grey; red = differs, amber = below threshold, blue = ignored, cyan boxes =
    largest clusters.
  - `side.png`: electron | native | diff at 1x.
- **Geometry**: both dumps flattened to leaf paths (`panes.leaf-a.header`,
  `tabBars.root.tabs.tab-a.active`, …). A key on one side only → missing/extra. A rect differs when
  any edge moves more than `--tolerance` (0.5 CSS px), reported per edge (`L T R B`, native minus
  electron). Other numbers within the tolerance; everything else equal.
- `summary.txt`: the whole report. `index.html`: the report with images; click a "flip" image to
  swap electron/native, `f` flips all.

## Known, ignorable differences

- Glyph antialiasing and subpixel text positions: amber noise along text, a few red pixels on
  glyph edges.
- Blurred shadows (active tab `0 7px 10px`; floating ring + `0 14px 36px`; dropdown, drag ghost,
  palette, context menu, tooltip): compare their extent, not exact values.
- Fractional split sizes (e.g. `deep-nesting`): each engine snaps them differently.
- Text line boxes: `title` height is Chromium's line box (13 for the 11px chrome font, top =
  baseline − 11). A native label's box may differ in T/B; baselines and L/R edges are what matter.
- Dim filter: CSS `grayscale(V) brightness(1 − 0.7·V)` on the pane's content (default V 0.34 →
  `grayscale(0.34) brightness(0.762)`); the native approximation may be off by a few levels.

## Reference values (from the Electron render)

- **Bars**: root bar 30 (`--window-titlebar-height`), strip from x = 90 (1 border + 89
  `--traffic-light-gutter`); fullscreen: 24, no gutter. Nested tab bars 24, leaf headers 25 (24 + 1
  bottom border). Indent (depth + 1) × 7, gap 8.
- **Tabs**: strip 24, bottom-aligned, overhangs 1 to cover the hairline. Inactive tab 21 (3 top
  margin); active 22 (2 margin + 1 top border). Top radius 3, max width 220, 2 apart. Width =
  31.02 + text (1 border, 10 pad, text, 2 gap, 15.02 close, 2 pad, 1 border).
- **Text**: chrome 11px system font, line box 13. Baselines: tab title = strip top + 17 (25 on the
  root bar); leaf header title = header top + 16.5. Grip `⠿` 10px (glyph from Apple Braille); tab `×`
  12px Arial.
- **Colors** (`src/shared/theme.ts`), dark / light: `--bg` `#1e1f24` / `#ffffff` (root bar, even
  depths); `--bg-elevated` `#2a2c33` / `#eff0f3` (odd depths, active tab on the root bar);
  `--border` `#3a3b44` / `#d2d3da` (every 1pt line); `--accent` `#4f8cff` / `#2f6fe4` (active
  outline); `--text` `#e6e6eb` / `#1c1d22` (active tab); `--text-dim` `#9a9ba6` / `#63646e` (the
  rest).
- **Cues**: `--bell-alert` `#ff453a` / `#d70015`, `--agent` `#b48cff` / `#7b45d8`. Outline: 1pt
  border in the cue color + inset `0 0 14px` glow of it at 55%, pulsing with the icons. Cue icons
  are 16×16 SVGs painted at their layout rect rounded to whole points (laid out at x 629.84 → drawn
  at 630; y 13.5 → 14).
- **Git tree select** (Chromium menulist): as wide as its widest option ("All local branches", 123
  at 11px); label ~9.5 in; bold chevron ~9×5.5, 4.5 from the right, vertically centered.
