# Visual scenarios

Each `scenarios/<name>.json` is a window the real engine and renderer put on screen (never shown):
a layout, settings, and a hover, drag, menu or palette applied. Rendering one gives a picture
(`<name>.png`) and the geometry of every piece of chrome (`<name>.geometry.json`).

- **Where**: core's scenarios are here (`Visual/scenarios`, chrome only: empty panes, splits, tab
  groups, floating panes); a plugin's are in its own folder (`Plugins/<Name>/Visual/scenarios`),
  so deleting a plugin takes its scenarios and goldens with it. Each folder's goldens sit beside
  its scenarios (`golden/`). A name is used once across all folders.
- **Goldens**: `golden/<name>.geometry.json` is each scenario's geometry as recorded from the app.
  `GeometryGoldenTests/theGeometryMatchesTheGolden` renders every scenario and holds its geometry to
  the golden within 0.5pt; `GeometryGoldenTests/everyScenarioHasAGolden` requires one per scenario.
  After an intended change to the chrome, or for a new scenario, re-record with `make
  visual-golden` and review the golden diff like code.
- **Pixels**: `make visual-baseline` captures the scenarios with the build before a change; `make
  visual` captures them with the current build and compares the two (`compare.py`). Use it to see
  what a change does to the look; nothing gates on it.

See also [docs/LAYOUT.md](../docs/LAYOUT.md).

## Running

From the repository root:

```
make visual-baseline [ONLY="name …"]   # build/visual/baseline/<name>.{png,geometry.json}
make visual [ONLY="name …"]            # build/visual/current/…, then compare.py
make visual-golden [ONLY="name …"]     # re-record each golden/<name>.geometry.json, beside its scenario
Visual/capture.sh <dir> [names…]       # every folder's scenarios; needs the Debug build (make build)
python3 Visual/compare.py [--baseline DIR] [--current DIR] [--out DIR] [--scenarios DIR …]
        [--threshold 24] [--tolerance 0.5] [--ignore X,Y,W,H …] [names…]
    # -> build/visual/compare/{index.html, summary.txt, <name>.diff.png, <name>.side.png}
```

- **Capture**: `Tabs --render-scenarios <dir> [--render-scenarios <dir> …] --out <dir> [names…]`
  (Debug builds only, `Sources/Tabs/Testing/VisualCapture.swift`), `TZ=UTC`, scratch
  `TABS_DATA_DIR`. Exit 1 if any scenario fails, or a name is in two folders. `capture.sh` passes
  `Visual/scenarios` and every `Plugins/*/Visual/scenarios`; `golden.py` writes each golden into
  its scenario's folder; `compare.py` reads descriptions from every folder.
- **compare.py**: Python 3 + Pillow + numpy. Exit 0 whatever it finds, 2 when inputs are missing.
- Both comparers (`compare.py` and the tests' `GeometryDifferences`) flatten whatever keys the dumps
  hold: a new geometry block changes the dumps, never the comparers.

## Scenario files (`scenarios/<name>.json`)

| Key | Meaning |
|---|---|
| `description` | What the capture must show (shown in `compare.py`'s report) |
| `size` | `{width, height}`: the window's content size, in points |
| `settings` | Always has `colorTheme` (`dark`/`light`). Also applied: `dimInactivePanes`, `dimInactivePanesIntensity`, `snapResizeSeparators`, `enableBellIndicator`/`enableControlIndicator` (with `signals`), `disabledContentTypes` (creation actions), `plugins` (`{"<plugin id>": {…}}`: plugins' settings, as in settings.json). Map anything new in `VisualCapture.stage` |
| `layout` | One window's saved layout: `{version: 1, root, activePaneId, floating}`, `root` a tabs group. Leaves: `empty`, or a plugin's content type with the config the plugin saves (a plugin scenario's own; staged through `content`). Node ids are the geometry keys |
| `pointer` | `{x, y}`: mouse there, no buttons |
| `drag` | `{from, to}`: left button down at `from`, 10 steps to `to`, captured while held |
| `fullscreen` | `true`: native fullscreen (the root bar loses its traffic-light gutter and extra height) |
| `caffeinate` | `true`: caffeinate running → the cup before Settings on the root bar (`PaneAppearance.caffeinateRunning`) |
| `contextMenu` | `{x, y}`: right-click there |
| `palette` | `{step: "type" \| "placement", highlight?, hover?}`: ⌘P palette open; `placement` = first row chosen; `highlight` = that many ArrowDown; `hover` = pointer on that row's center (takes the highlight) |
| `paletteTypes` | Integer ≥ 0: extra stub types after the stub (`sample-<n>`, "Sample <n>", "New sample <n>", icon ▣, n from 2), for lists over nine rows |
| `signals` | `{"<leaf id>": ["bell" \| "controlled", …]}`, raised before any pointer step. `bell` rings as if the window were unfocused (kept on the active pane); `controlled` = owned by another pane. Hidden when `enableBellIndicator`/`enableControlIndicator` is false |
| `pulse` | Seconds: every cue pulse held at that time; without it pulses show at their peak (opacity 1). Bell cycle 3 s, controlled 4.5 s; both at their 0.3 trough at 0 |
| `content` | `{"<leaf id>": {…}}`: a plugin pane's content, as its plugin stages it (below); its shape is the plugin's (its spec's "Checking the look") |
| `creationActions` | Content types (a plugin scenario's own, e.g. `["browser"]`) that empty panes offer before the stub; otherwise the stub alone |
| `ignore` | `[[x, y, w, h], …]`: regions (points) `compare.py` leaves out of the pixel diff |

- Every scenario's empty panes offer one stub content type ("▣", "New stub").
- Coordinates: content area, top-left origin, y down (flip AppKit's). Take pointer and drag points
  from a geometry dump.
- The bundled plugins start only when the layout or `creationActions` names a content type.
- Step order: signals → content → fullscreen → contextMenu → palette → pointer → drag, then settle
  (a pending floating reclamp runs at once, fades are instant, then one 10 ms turn). Without
  `pointer`, `drag`, `contextMenu` or a palette `hover`, the pointer is off the window. Tooltips
  are AppKit's, a window of their own, so no capture shows one.

### Plugin panes (`content`)

A pane's content is its plugin's business. The capture reaches it through internal Debug verbs
named after the plugin that owns the pane's content type (`<owner>`), each targeted at the pane:

| Verb | Called | Does |
|---|---|---|
| `<owner>.test.stage {spec}` | for every `content` entry, after `signals` | Shows the entry: fixture data, overrides, focus. The capture fails if the plugin has no such verb, or the verb fails |
| `<owner>.test.visual` | for every staged pane, in the geometry | Answers `{title: {…}, body: {…}}`: rects and baselines in the header title view's coordinates (`title`, for a plugin that draws its header title) and in the pane view's (`body`). The capture offsets each to the window and merges them into `content.<leaf id>` |
| `<owner>.test.snapshot {path}` | for every staged pane on screen, in the picture | Writes a 2x PNG at `path` of what the layer tree can't render (a view whose content lives in another process). The capture puts it in place of the pane view's layer while the tree renders, dimmed as the view is (`CALayer.render(in:)` ignores Core Image filters) |

`visual` and `snapshot` are optional. A plugin's own views hear the pointer (`pointer`) as their
tracking areas would tell them: `mouseMoved` in the body, `mouseEntered` in the header title.

## Output: `<name>.png`

The content area only, at 2x (`2·width × 2·height` px), sRGB. No title bar, window shadow or
traffic lights; the root bar's 89pt gutter is empty. `compare.py` composites transparent pixels on
magenta.

## Output: `<name>.geometry.json`

- Rects are `[x, y, width, height]` in points, content coordinates, top-left origin, 2 decimals,
  frame including borders.
- Only what's shown: a background tab's subtree (a hidden view) is absent, never zero-sized.
- Controls revealed on hover (header buttons, a tab's close) are laid out and reported while hidden,
  with `visible` where the shape has it.
- Not clipped by scrolling ancestors (`many-tabs`: its last tabs sit past the strip's end).
- Empty object `{}`; absent thing `null`. Keys marked "omitted" are left out when not applicable, so
  existing goldens hold.
- Text rects: the text's line box (`ChromeText`: the font's rounded ascent plus descent), as wide
  as the text and clipped to its label. Baselines: the line top plus the ascent.

```jsonc
{
  "size": {"width": 1200, "height": 800},
  "panes": {                                  // every pane: leaves AND tab groups (not splits)
    "<node id>": {
      "rect": R,                              // the pane box, own border included
      "body": R,                              // leaf: below the header; group: inside the border (tab bar included)
      "header": R | null,                     // leaf title bar (groups have a tab bar instead)
      "title": R | null,                      // header title's text line box, clipped to its label;
      "titleBaseline": number | null,         //   all three null when a plugin draws the title
      "titleText": string | null,             //   (a header title view); "Empty pane" for empty leaves
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
      "separator": R | null,                  // 1pt divider between the creation and destructive groups
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
  "contextMenu": R | null,                    // an open context menu
  "content": {"<leaf id>": {…}},              // staged plugin panes, as their plugins measure them;
                                              //   omitted without one (each plugin's spec has its keys)
  "palette": {…}                              // omitted unless the palette is open; see below
}
```

Button ids are the buttons' accessibility identifiers (`HeaderAction.accessibilityID`). The root
bar's row is `pane-new-tab-button` + `pane-close-button`; every other row
`pane-split-horizontal-button` + `pane-close-button`. Dropdown items: `pane-split-vertical-button`,
`pane-new-tab-button`, `pane-new-unpinned-tab-button`, `pane-tab-group-button`,
`pane-clear-button`, …; a dropdown's first row repeats its root button as `<root id>-menu-item`.

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

## What `compare.py` reports

- **Pixels**: a pixel differs when its largest channel delta exceeds `--threshold` (default 24,
  absorbs antialiasing). Per scenario: % differing, max and mean delta, the largest clusters as
  boxes in points. A size mismatch is reported; the missing area counts as differing.
  - `diff.png`: the current capture in grey; red = differs, amber = below threshold, blue =
    ignored, cyan boxes = largest clusters.
  - `side.png`: baseline | current | diff at 1x.
- **Geometry**: both dumps flattened to leaf paths (`panes.leaf-a.header`,
  `tabBars.root.tabs.tab-a.active`, …). A key on one side only → gone/new. A rect differs when any
  edge moves more than `--tolerance` (0.5pt), reported per edge (`L T R B`, current minus
  baseline). Other numbers within the tolerance; everything else equal.
- `summary.txt`: the whole report. `index.html`: the report with images; click a "flip" image to
  swap baseline/current, `f` flips all.

## Reference values

- **Bars** (`Metrics`, `Sources/Tabs/Workspace/Chrome.swift`): root bar 30, strip from x = 90 (1
  border + 89 traffic-light gutter); fullscreen: 24, no gutter. Nested tab bars 24, leaf headers 25
  (24 + 1 bottom border). Indent (depth + 1) × 7, gap 8.
- **Tabs**: strip 24, bottom-aligned, overhangs 1 to cover the hairline. Inactive tab 21 (3 top
  margin); active 22 (2 margin + 1 top border). Top radius 3, max width 220, 2 apart. Width =
  31.02 + text (1 border, 10 pad, text, 2 gap, 15.02 close, 2 pad, 1 border).
- **Text**: chrome 11pt system font, line box 13. Baselines: tab title = strip top + 17 (25 on the
  root bar); leaf header title = header top + 16.5. Grip `⠿` 10pt (glyph from Apple Braille); tab
  `×` 12pt Arial.
- **Colors** (`PaneTheme`, `Sources/TabsPluginSDK/PaneTheme.swift`), dark / light: `bg` `#1e1f24` /
  `#ffffff` (root bar, even depths); `bgElevated` `#2a2c33` / `#eff0f3` (odd depths, active tab on
  the root bar); `border` `#3a3b44` / `#d2d3da` (every 1pt line); `accent` `#4f8cff` / `#2f6fe4`
  (active outline); `text` `#e6e6eb` / `#1c1d22` (active tab); `textDim` `#9a9ba6` / `#63646e` (the
  rest).
- **Cues**: `bellAlert` `#ff453a` / `#d70015`, `agent` `#b48cff` / `#7b45d8`. Outline: 1pt border
  in the cue color + an inset 14pt glow of it at 55%, pulsing with the icons. Cue icons are 16×16,
  painted at their layout rect rounded to whole points (laid out at x 629.84 → drawn at 630; y 13.5
  → 14).
- **Dimming**: an inactive pane's content gets `grayscale(V)` then `brightness(1 − 0.7·V)` (default
  V 0.34 → grayscale 0.34, brightness 0.762).
