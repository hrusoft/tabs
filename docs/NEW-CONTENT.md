# New content and its shortcuts

Making a new pane: the creation chords (⌘T, ⇧⌘T, ⌥⌘T, ⌥⇧⌘T), the header and tab-strip
buttons, the empty pane's toolbar, and the ⌘P palette (File ▸ New Content…: a type, then a
placement). Code: `Sources/Tabs/Workspace/Palette.swift` (the palette) and `LayoutEngine.newPane`
(creation). Chords, buttons and toolbar in the layout: [LAYOUT.md](LAYOUT.md); rebinding:
[KEYBOARD.md](KEYBOARD.md).

## Scope

- No File ▸ New Tab With ▸ <type>: the palette is how a chosen type is created (D-1, F-2).

## Sources

| File | What |
|---|---|
| `Sources/Tabs/Workspace/Palette.swift` (`Palette`, `PaletteState`, `PaletteView`, `PalettePlacement`, `NoContentTypes`) | The overlay: two steps and the keys (`PaletteState`), mouse, look |
| `CoreCommands.commandPalette` (`tabs.commandPalette`) | Command, default chord ⌘P, File item "New Content…" |
| `LayoutEngine.newPane(ofType:from:in:placement:)`, `WorkspaceWindowController.newPane(ofType:from:placement:)` | A chosen type made from an origin pane, placed as tab, split or float |
| `LayoutEngine.newPane(like:in:placement:)`, `contentLike` | ⌘T, ⇧⌘T, ⌥⌘T, ⌥⇧⌘T: content like the active pane |
| `Sources/Tabs/UI/MainMenu.swift` (`CommandRouter`, `MainMenu.build`) | File menu's creation items |
| `Sources/Tabs/Workspace/PaneBodies.swift` (`EmptyPaneView`), `LayoutEngine.fill` | Empty pane's toolbar |
| `Sources/Tabs/Workspace/PaneViews.swift` (header controls), `TabStrip.swift` ("+") | Header and tab-strip buttons |
| `Sources/TabsCore/Panes/PaneRuntime.swift` (`creatableTypes`, `canCreate`, `create`) | Creation gate |
| `Sources/TabsCore/Commands/Shortcuts.swift` | Shortcut table, conflicts, user bindings |
| `Floating.spawnRect(in:at:)`, `WorkspaceWindowController.spawnRect(from:)` | Where an unpinned pane spawns |

## Cases

### Opening the palette

| Id | Case | Test |
|---|---|---|
| P-1 | ⌘P (File ▸ New Content…) opens on the type step, aimed at the pane active now | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| P-2 | No active pane in any tree → nothing (`Palette.open` returns nil) | — (a window always has an active pane) |
| P-3 | Per window: opens in the window the chord was used in; others untouched | `UITests.PaletteTests/itOpensOnlyInTheWindowTheChordWasUsedIn` |
| P-4 | Above floating panes (window overlay, over the floating layer); later overlays (a dialog) above it | `UITests.PaletteTests/itIsAboveAFloatingPane` |
| P-5 | Chord works while a browser page holds the keyboard (menu key equivalent, not a key listener) | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` (a text editor stands in for a page) |
| P-6 | Opening makes the palette first responder, out of whatever held the keyboard | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` |
| P-7 | Chord again while open: re-aims at the active pane, back to the type step. The highlight resets only on a change of step kind (Q-1): from placement → row 0; from type, or with the list changing under it, kept | `UITests.PaletteTests/openingAgainResetsTheHighlightOnlyOnAChangeOfStep` |
| P-8 | Rebindable and unbindable (`tabs.setShortcut`, Settings ▸ Keyboard); unbound → item stays, no key equivalent. A plugin default can't take ⌘P (core defaults claim first) | `ShortcutsTests/theCommandPaletteIsCommandPAndItsChordIsRebindableAndUnbindable`, `ShortcutsTests/aPluginsDefaultForCommandPLeavesTheCommandPaletteItsChord`, `MenuTests/newContentFollowsItsChordAndStaysWhenUnbound`, `UITests/aRebindingTakesEffectAtOnce` (the menu follows a rebind at once) |

### Step 1: choosing a type

| Id | Case | Test |
|---|---|---|
| T-1 | One row per creatable type, UI order, labelled with `displayName` ("Terminal"), not the button label ("New terminal") | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| T-2 | Each row: the type's creation icon before its label | ″ |
| T-3 | Rows 1–9 get a numbered badge; row 10+ none | `GeometryGoldenTests/theGeometryMatchesTheGolden` (`palette-many`) |
| T-4 | First row highlighted on opening | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| T-5 | Disabled type has no row; enabling/disabling while open updates the list live (`WorkspaceRenderer.refreshEmptyPanes` → `refreshTypes`) | `UITests.PaletteTests/aTypeTurnedOffWhileOpenLeavesTheList` |
| T-6 | Nothing enabled → no list, only "No content types are enabled — turn a plugin on in Tabs ▸ Plugins…" (the empty pane's sentence, `NoContentTypes.message`; see Notes) | `PaletteStateTests/withNothingToCreateItSaysSoAndIgnoresEveryKeyButEscape`, `GeometryGoldenTests/theGeometryMatchesTheGolden` (`palette-empty`) |
| T-7 | Empty state: arrows, digits, Return do nothing; Escape closes | `PaletteStateTests/withNothingToCreateItSaysSoAndIgnoresEveryKeyButEscape` |

### Step 2: choosing a placement

| Id | Case | Test |
|---|---|---|
| S-1 | Choosing a type → same panel, four rows: Tab, Horizontal Split, Vertical Split, Unpinned Pane | `PaletteStateTests/theSecondStepListsTheFourPlacements`, `GeometryGoldenTests/theGeometryMatchesTheGolden` (`palette-placement`) |
| S-2 | Each row has the matching header button's icon (new tab, split H, split V, new unpinned tab) | ″ |
| S-3 | Rows numbered 1–4; first highlighted (step changed) | ″ |
| S-4 | Chosen type not shown; no way back: Escape from step 2 closes everything (Q-5) | `PaletteStateTests/escapeFromTheSecondStepClosesEverything` |
| S-5 | Labels = command titles minus leading "New " (`PalettePlacement.label`), independent of chords; no chord shown on either step (Q-9) | `PaletteStateTests/theSecondStepListsTheFourPlacements` |

### Keyboard

| Id | Case | Test |
|---|---|---|
| K-1 | ↓/↑ move the highlight, wrapping at both ends | `PaletteStateTests/arrowsMoveTheHighlightAndWrap`, `UITests.PaletteTests/openingAgainResetsTheHighlightOnlyOnAChangeOfStep` |
| K-2 | Return (and keypad Enter) chooses the highlighted row, not a focused button; a hovered row is the highlighted one (Q-4) | `PaletteStateTests/returnAndTheDigitsChoose`, `UITests.PaletteTests/openingAgainResetsTheHighlightOnlyOnAChangeOfStep` |
| K-3 | Digits 1–9 choose that row directly; past the last row → nothing | `PaletteStateTests/returnAndTheDigitsChoose`, `UITests.PaletteTests/aTypeThenASplitSplitsTheTarget` |
| K-4 | Digits matched on the physical key alone, any modifier held; keypad digits don't count (Q-3) | `PaletteStateTests/returnAndTheDigitsChoose`, `UITests.PaletteTests/aTypeThenASplitSplitsTheTarget` |
| K-5 | Escape closes, keyboard back to the pane active at opening | `UITests.PaletteTests/escapeReturnsTheKeyboardToThePane` |
| K-6 | Every other key (Tab, letters) does nothing; no search field | `PaletteStateTests/otherKeysDoNothing` |
| K-7 | Every key that reaches the palette is consumed, handled or not. Pane nav chords (⌘←→↑↓) never reach it: `WorkspaceInput`'s monitor takes them first, so they still move pane focus while it's open; the target stays the pane active at opening (Q-10) | — |

### Mouse

| Id | Case | Test |
|---|---|---|
| M-1 | Entering a row highlights it (only on entry); highlight stays where the pointer left it | `UITests.PaletteTests/enteringARowHighlightsIt` |
| M-2 | Click a row = Return on it | `UITests.PaletteTests/clickingARowChoosesIt` |
| M-3 | Click the backdrop → close, keyboard back to the target pane | `UITests.PaletteTests/clickingTheBackdropDismissesAndReturnsTheKeyboard` |
| M-4 | Click inside the panel but off a row (padding, border, empty text) → nothing | `UITests.PaletteTests/clickingThePanelOutsideItsRowsDoesNothing` |
| M-5 | Backdrop swallows every pointer event: nothing under it reacts | `UITests.PaletteTests/thePanesBeneathTheBackdropDontReact` |
| M-6 | Right-click on the backdrop does nothing: only the primary button clicks (Q-6) | `UITests.PaletteTests/aRightClickOnTheBackdropDoesNothing` |

### Creating and placing

| Id | Case | Test |
|---|---|---|
| C-1 | Type + Tab on a non-empty pane → new tab beside the target | `UITests.PaletteTests/itAimsAtThePaneThatWasActiveWhenItOpened`, `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt` |
| C-2 | …on an **empty** pane → fills it in place (same slot, no new tab or pane) | `UITests/thePaletteOffersOnlyCreatableTypes`, `LayoutEngineTests/aNewPaneOfAChosenTypeOnAnEmptyOriginFillsItAndInheritsNothing` |
| C-3 | Horizontal / Vertical Split split the target | `UITests.PaletteTests/aTypeThenASplitSplitsTheTarget` |
| C-4 | Unpinned Pane → floating pane in the target section `newUnpinnedPanePosition` names; never docked | `UITests.PaletteTests/clickingARowChoosesIt`, `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt` |
| C-5 | Palette closes *before* the pane is made (Q-7); creation is synchronous | `UITests.PaletteTests/theOverlayIsGoneByTheTimeThePaneExists` |
| C-6 | Target = pane active when the palette **opened**, not at commit | `UITests.PaletteTests/itAimsAtThePaneThatWasActiveWhenItOpened` |
| C-7 | Target looked up at commit: gone → nothing created, palette still closes | `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt`, `UITests.PaletteTests/theOverlayIsGoneByTheTimeThePaneExists` (it closes before the target is looked up) |
| C-8 | New pane made from the target's entry leaf (active tab, else a split's first child), per the **created** type's rule: terminal → the shell's live directory; git tree → the target's repository; browser → blank page; empty target or no directory → type default | `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt`, `LayoutEngineTests/aNewPaneOfAChosenTypeOnAnEmptyOriginFillsItAndInheritsNothing`, `UITests.GitTreeUITests/aGitTreeFromAPaneOfferingADirectoryOpensThere`, `UITests.TerminalUITests/aTerminalFromAPaneOfferingADirectoryStartsThere` |
| C-9 | New pane active and has the keyboard | `UITests/thePaletteOffersOnlyCreatableTypes` |
| C-10 | A type disabled while on step 2: core's gate (`PaneRuntime.create`) refuses it at commit; nothing made, palette closed | `PaneRuntimeTests/creationIsGatedButRestorationIsNot` |
| C-11 | Rows re-derived live; the highlight is never clamped, so a list shrinking under it can leave it past the end → Return does nothing (Q-2) | `UITests.PaletteTests/aTypeTurnedOffWhileOpenLeavesTheList` |
| C-12 | Palette content starts with the type's default title (no override) | — (`newPane(ofType:)` passes no title) |
| C-13 | On an empty target nothing is inherited (origin nil): the type's defaults (Q-8). The toolbar of an empty pane made by N-7 differs: it remembers the live pane it was made like (`LayoutEngine.creationOrigins`) and `fill` inherits from that pane | `LayoutEngineTests/aNewPaneOfAChosenTypeOnAnEmptyOriginFillsItAndInheritsNothing` |

### Creation chords, header buttons, tab-strip "+"

| Id | Case | Test |
|---|---|---|
| N-1 | ⌘T: new tab beside the active pane, content *like* it (terminal → terminal; empty stays empty) | `UITests/windowShortcutsOpenAndCloseTabs`, `LayoutEngineTests/aNewPaneLikeALiveOneIsAnotherOfItsTypeMadeFromIt` |
| N-2 | ⇧⌘T: horizontal split, content like the active pane | `UITests.Keyboard/theNewPaneShortcutsAndClose` |
| N-3 | ⌥⌘T: vertical split | ″ |
| N-4 | ⌥⇧⌘T: floating unpinned pane like the active one, in the section the setting names | `UITests.Keyboard/theNewPaneShortcutsAndClose`, `FloatingTests.SpawnRectIn/shippedDefault` |
| N-5 | Chords act on the active pane wherever it is, floating included | `WindowLayoutTests.OpenContent/insideFloating`, `UITests.Keyboard/theNewPaneShortcutsAndClose` |
| N-6 | Active = docked root group → redirect to its shown tab (`redirectFromDockedRoot`); ⇧⌘T/⌥⌘T never split the root out of itself | `WindowLayoutTests.SplitPane/redirectsFromRoot`, `UITests.HeaderControls/theRootBarsControlsActOnTheShownTab` |
| N-7 | Origin type can't be created (disabled) → empty pane instead of a copy | `LayoutEngineTests/aNewPaneLikeOneThatCantBeMadeIsEmptyAndFillsInPlaceFromIt` |
| N-8 | Header Split horizontally (the visible button), Split vertically, New tab, New unpinned tab, tab-strip "+": as the chords, aimed at their own pane/group. Docked root's bar: New tab and New unpinned tab only | `UITests.HeaderControls/splitHorizontallyIsTheRootButton`, `UITests.HeaderControls/theMenuSplitsVerticallyOpensTabsAndWraps`, `UITests.HeaderControls/aNewTabAtAnEmptyPaneReplacesIt`, `UITests.HeaderControls/aNewUnpinnedTabFloatsOverTheTopRightOfItsPane`, `UITests.HeaderControls/theRootBarsControlsActOnTheShownTab`, `UITests.TabStrip/thePlusButtonAddsATabToItsOwnGroupOnly` |
| N-9 | Empty pane toolbar: one segmented button per creatable type; press → fills in place, pane stays active and focused | `UITests/creatingATextPaneFromAnEmptyPaneFocusesIt`, `RendererTests/theEmptyPaneToolbarShowsEachTypesIconAndLabel` |
| N-10 | Empty pane, nothing creatable → the T-6 sentence instead of the toolbar | — |

### The File menu

| Id | Case | Test |
|---|---|---|
| F-1 | File: New Window ⌘N — New Content… ⌘P — New Tab ⌘T, New Horizontal Split ⇧⌘T, New Vertical Split ⌥⌘T, New Unpinned Pane ⌥⇧⌘T, Close Pane ⌘W — Caffeinate…. Settings… ⌘, is in the app menu | `MenuTests/theFileMenuListsItsCommandsAndHasNoNewTabWith` |
| F-2 | No File ▸ New Tab With ▸ <type> | ″ |
| F-3 | New Content… always enabled; does nothing while a non-workspace window (Settings, Plugins) is key, or with no workspace window | — (`CommandRouter.showPalette`) |
| F-4 | Menu labels are the command titles (`CoreCommand.title`): a rename is one edit | — (compile-time) |

### Settings and persistence

| Id | Case | Test |
|---|---|---|
| D-1 | No File ▸ New Tab With; the palette is how a chosen type is created (Scope) | see F-2 |
| D-2 | `core.panes.newUnpinnedPanePosition` (nine positions, default `top-right`) places C-4/N-4/N-8; read when the pane is made | `FloatingTests.SpawnRectIn/shippedDefault`, `FloatingTests.SpawnRectIn/distinct`, `UITests.HeaderControls/aNewUnpinnedTabFloatsOverTheTopRightOfItsPane` |
| D-3 | Creation gate: a disabled plugin's types get no palette row, no toolbar button, no `contentLike` copy; open panes keep running (Notes) | `PaneRuntimeTests/creationIsGatedButRestorationIsNot`, `MenuTests/theCreationGateOffersOnlyCreatableTypes`, `UITests/thePaletteOffersOnlyCreatableTypes` |
| D-4 | Palette persists nothing (never in layout.json) | `UITests.PaletteTests/theLayoutIsUntouchedByAPaletteThatCreatesNothing` |
| D-5 | Shortcut overrides in settings.json `core.shortcuts` (stored chord, or null = unbound) | `ShortcutsTests/theUsersBindingsComeFirstAndPersist` |

### Errors and edge cases

| Id | Case | Test |
|---|---|---|
| E-1 | Plugin refuses to build the pane → palette closed, nothing placed, nothing shown to the user | `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt`, `UITests.PaletteTests/theOverlayIsGoneByTheTimeThePaneExists` (it closes before the pane is made) |
| E-2 | Window resized while open → panel stays centered | `UITests.PaletteTests/thePanelStaysCenteredWhenTheWindowIsResized` |
| E-3 | Target closed meanwhile (e.g. a control verb) → commit makes nothing (C-7); dismissal focuses nothing | `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt` |
| E-4 | Tall list: panel ≤ 70% of window height, rows keep 30pt, list scrolls (wheel). Unreachable with today's three content types | `PaletteStateTests/aTallListIsCappedAtSeventyPercentOfTheWindow` (wheel not driven) |
| E-5 | Entering/leaving fullscreen while open → stays centered | `UITests.PaletteTests/thePanelStaysCenteredWhenTheWindowIsResized` |

## Look

Lengths in pt; colors dark / light (`PaneTheme`).

| Id | Element | Box | Text | Colors | States | Scenario |
|---|---|---|---|---|---|---|
| L-1 | Backdrop | Whole window (content view, title-bar band included), above the floating layer; centers the panel | — | `bg` at 40% over the layout: `#1e1f24` / `#ffffff` | — | `palette-types` |
| L-2 | Panel | 320 wide (border included), height = content, ≤ 70% of window; padding 4; border 1; radius 8; column | — | fill `bgElevated` `#2a2c33` / `#eff0f3`; border `border` `#3a3b44` / `#d2d3da`; shadow 16 down, blur 40, black × 0.5 × `shadowStrength` (1 / 0.45) | — | `palette-types` |
| L-3 | Row | Full width of the panel's content box; a row, vertically centered, gap 8; padding 7 10; radius 4; height = max(icon 16, badge 16, label line 16) + 14 = 30 | system 13, regular, `text` `#e6e6eb` / `#1c1d22`, left | transparent | highlight (hover/keys): fill `accent` `#4f8cff` / `#2f6fe4`, text `onAccent` `#ffffff` | `palette-types`, `palette-types-hover` |
| L-4 | Badge | min width 16, height 16, padding 0 4, radius 4; content centered | 10, tabular digits, the row's text color | the row's text color at 14% | follows the row's text | `palette-types` |
| L-5 | Type icon | 16×16 (the type's icon, in the row's text color); a text stand-in (the test stub's "▣") is as wide as its glyph (11.25×16), label 8 after it | — | the row's text color | follows the row | `palette-types` |
| L-6 | Placement icon | 16×16: new tab (13×11 frame + cross), split H, split V, new unpinned (window + corner arrow) | — | the row's text color | follows the row | `palette-placement` |
| L-7 | Label | The rest of the row, one line, truncated with an ellipsis | 13 | inherits the row | — | `palette-types` |
| L-8 | List | column; scrolls when taller than the panel | — | — | — | (E-4) |
| L-9 | Empty state | padding 10; sentence wraps to 2 lines → panel 60 tall | 12, `text` at 65% | — | — | `palette-empty` |
| L-10 | Over a floating pane | backdrop and panel paint above the float and its shadow | — | — | — | `palette-over-floating` |
| L-11 | Light theme | light tokens, shadow strength 0.45 | — | see rows | — | `palette-light` |
| L-12 | Backdrop focus ring | The outermost 1pt of the window, radius 2, every step (`PaletteView.draw`) | — | `#99c8ff` over dark, `#005fcc` over light, opaque | — | every palette scenario |

## Implementation notes

- **Taking the keyboard from a page** (P-5, P-6): the palette becomes first responder, which takes
  the keyboard from a `WKWebView` as from any view.
- **Tabular digits** (L-4): `ChromeText(tabularNumbers:)`, `NSFont.monospacedDigitSystemFont`.
- **Panel shadow** (L-2), as for the context menu and dialog card: set in `layout()`, since a
  layer shadow set in `init` is reset before the view shows; `shadowRadius` is the whole blur
  (40), not half of it.

## Checking the look

Scenarios `Visual/scenarios/palette-*.json` (method: [LAYOUT.md](LAYOUT.md), Checking the look):
key `palette: {step: "type" | "placement", highlight?, hover?}`, plus `paletteTypes` (extra stub
types). The capture opens the palette with `VisualCapture.openPalette` (`Palette.open`,
`choose(0)`, `setHighlight`, `simulatePointer`). Geometry key `palette`: backdrop, panel, rows
(rect, badge, icon, label, baselines), `empty`.

| Scenario | Shows |
|---|---|
| `palette-types` | Step 1, dark: Browser + Stub, row 0 highlighted |
| `palette-types-hover` | Step 1, row 1 (Stub) hovered |
| `palette-placement` | Step 2, row 0 highlighted |
| `palette-placement-hover` | Step 2, row 3 (Unpinned Pane) hovered |
| `palette-empty` | Every type disabled: the sentence |
| `palette-light` | Step 1, light |
| `palette-over-floating` | Step 1 over `floating.json` (docked split + two floating panes) |
| `palette-many` | Ten types: row 10 has no badge; list at natural height |

## Notes

- **The creation gate is per plugin** (Tabs ▸ Plugins…), not per content type: the T-6/N-10
  sentence sends the user there.
