# New content and its shortcuts

Making a new pane: the creation chords (⌘T, ⇧⌘T, ⌥⌘T, ⌥⇧⌘T), the header and tab-strip
buttons, the empty pane's toolbar, and the ⌘P palette (File ▸ New Content…: a type, then a
placement). Port of Electron's. Chords, buttons and toolbar came with [LAYOUT.md](LAYOUT.md);
rebinding is [KEYBOARD.md](KEYBOARD.md).

## Scope

- No File ▸ New Tab With ▸ <type>: the palette is how a chosen type is created (D-1, F-2).

## Sources

| Native | Electron | What |
|---|---|---|
| `Sources/Tabs/Workspace/Palette.swift` (`Palette`, `PaletteView`, `PalettePlacement`, `NoContentTypes`) | `content/CommandPalette.tsx`, `core/store/commandPaletteStore.ts` | The overlay: two steps, keyboard, mouse, look |
| `CoreCommands.commandPalette` (`tabs.commandPalette`) | `shortcuts.ts` `command-palette` (⌘P, layer `menu`) | Command, default chord, File item "New Content…" |
| `LayoutEngine.newPane(ofType:from:in:placement:)`, `WorkspaceWindowController.newPane(ofType:from:placement:)` | `createFrom.ts:createContentFor`, `placement.ts:placeNewPane`/`placeNewUnpinnedPane` | A chosen type made from an origin pane, placed as tab, split or float |
| `LayoutEngine.newPane(like:in:placement:)`, `contentLike` | `content/contentLike.ts`, `paneShortcuts.ts` (`HANDLERS`) | ⌘T, ⇧⌘T, ⌥⌘T, ⌥⇧⌘T: content like the active pane |
| `Sources/Tabs/UI/MainMenu.swift` (`CommandRouter`, `MainMenu.build`) | `src/main/menu.ts` (`paneShortcutItem`, File submenu) | File menu's creation items |
| `Sources/Tabs/Workspace/PaneBodies.swift` (`EmptyPaneView`), `LayoutEngine.fill` | `content/empty/EmptyPaneRenderer.tsx` | Empty pane's toolbar |
| `Sources/Tabs/Workspace/PaneViews.swift` (header controls), `TabStrip.swift` ("+") | `content/PaneHeaderControls.tsx`, `content/tabs/TabBar.tsx` | Header and tab-strip buttons |
| `Sources/TabsCore/Panes/PaneRuntime.swift` (`creatableTypes`, `canCreate`, `create`) | `content/creationActions.ts`, `shared/content/enablement.ts` | Creation gate |
| `Sources/TabsCore/Commands/Shortcuts.swift` | `packages/plugin-sdk/shared/shortcuts.ts` | Shortcut table, conflicts, user bindings |
| `Floating.spawnRect(in:at:)`, `WorkspaceWindowController.spawnRect(from:)` | `shared/model/floating.ts:spawnRectIn` | Where an unpinned pane spawns |

## Cases

### Opening the palette

| Id | Case | Electron | Native test |
|---|---|---|---|
| P-1 | ⌘P (File ▸ New Content…) opens on the type step, aimed at the pane active now | `paneShortcuts.ts:handleOpenCommandPalette` | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| P-2 | No active pane in any tree → nothing (`Palette.open` returns nil) | `handleOpenCommandPalette` (`findNodeAnywhere` guard) | — (a window always has an active pane) |
| P-3 | Per window: opens in the window the chord was used in; others untouched | one renderer per window | `UITests.PaletteTests/itOpensOnlyInTheWindowTheChordWasUsedIn` |
| P-4 | Above floating panes (window overlay, over the floating layer); later overlays (dialog, tooltip) above it | `global.css` z-index 2100 | `UITests.PaletteTests/itIsAboveAFloatingPane` |
| P-5 | Chord works while a browser page holds the keyboard (menu key equivalent, not a key listener) | `layer: 'menu'` | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` (a text editor stands in for a page) |
| P-6 | Opening makes the palette first responder, out of whatever held the keyboard | `CommandPalette` focus effect | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` |
| P-7 | Chord again while open: re-aims at the active pane, back to the type step. From placement: highlight → row 0; from type: highlight **kept** (Q-1) | `open()`; highlight resets on `step.kind` change | `UITests.PaletteTests/openingAgainResetsTheHighlightOnlyOnAChangeOfStep` |
| P-8 | Rebindable and unbindable (`tabs.setShortcut`, Settings ▸ Keyboard); unbound → item stays, no key equivalent. A plugin default can't take ⌘P (core defaults claim first) | `resolveBinding` | `UITests.PaletteTests/theChordIsRebindableAndUnbindable`, `ShortcutsTests/theCommandPaletteIsCommandPAndItsChordIsRebindableAndUnbindable`, `ShortcutsTests/aPluginsDefaultForCommandPLeavesTheCommandPaletteItsChord` |

### Step 1: choosing a type

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-1 | One row per creatable type, UI order, labelled with `displayName` ("Terminal"), not the button label ("New terminal") | `useCreationActions` `displayName` | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| T-2 | Each row: the type's creation icon before its label | `item.Icon` | ″ |
| T-3 | Rows 1–9 get a numbered badge; row 10+ none | `index < 9 &&` badge | `UITests.PaletteTests/onlyTheFirstNineRowsAreNumbered` |
| T-4 | First row highlighted on opening | `useState(0)` + step effect | `UITests.PaletteTests/theChordOpensTheTypeStepAimedAtTheActivePaneAndTakesTheKeyboard` |
| T-5 | Disabled type has no row; enabling/disabling while open updates the list live (`WorkspaceRenderer.refreshEmptyPanes` → `refreshTypes`) | `isContentTypeEnabled`, `subscribeToRegistry` | `UITests.PaletteTests/aTypeTurnedOffWhileOpenLeavesTheList` |
| T-6 | Nothing enabled → no list, only "No content types are enabled — turn one on in Settings → General → Content types." (the empty pane's sentence, `NoContentTypes.message`) | `NO_CONTENT_TYPES_MESSAGE` | `UITests.PaletteTests/withNothingToCreateItSaysSoAndIgnoresEveryKeyButEscape` |
| T-7 | Empty state: arrows, digits, Return do nothing; Escape closes | `items.length === 0` early return | ″ |

### Step 2: choosing a placement

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-1 | Choosing a type → same panel, four rows: Tab, Horizontal Split, Vertical Split, Unpinned Pane | `PLACEMENT_STRATEGY_IDS` | `UITests.PaletteTests/theSecondStepListsTheFourPlacements` |
| S-2 | Each row has the matching header button's icon (new tab, split H, split V, new unpinned tab) | `PLACEMENT_ICONS` | ″ |
| S-3 | Rows numbered 1–4; first highlighted (step changed) | step effect | ″ |
| S-4 | Chosen type not shown; no way back: Escape closes everything (Q-5) | (absent) | `UITests.PaletteTests/escapeFromTheSecondStepClosesEverything` |
| S-5 | Labels = command titles minus leading "New " (`PalettePlacement.label`), independent of chords; no chord shown | `label.replace(/^New /, '')` | `UITests.PaletteTests/theSecondStepListsTheFourPlacements` |

### Keyboard

| Id | Case | Electron | Native test |
|---|---|---|---|
| K-1 | ↓/↑ move the highlight, wrapping at both ends | `handleKeyDown` | `UITests.PaletteTests/arrowsMoveTheHighlightAndWrap` |
| K-2 | Return (and keypad Enter) chooses the highlighted row; a hovered row is the highlighted one (Q-4) | `Enter` branch | `UITests.PaletteTests/returnAndTheDigitsChoose` |
| K-3 | Digits 1–9 choose that row directly; past the last row → nothing | `/^Digit[1-9]$/` | ″ |
| K-4 | Digits by physical key code, any modifier held; keypad digits don't count (Q-3) | same | ″ |
| K-5 | Escape closes, keyboard back to the pane active at opening | `handleDismiss` → `focusPane` | `UITests.PaletteTests/escapeReturnsTheKeyboardToThePane` |
| K-6 | Every other key (Tab, letters) does nothing; no search field | falls through | `UITests.PaletteTests/otherKeysDoNothing` |
| K-7 | Handled keys consumed. **Deviation:** unhandled keys swallowed too (Electron: bubble); the one listener that would act on them, pane nav, runs first natively (Q-10) | `preventDefault` per branch | — |

### Mouse

| Id | Case | Electron | Native test |
|---|---|---|---|
| M-1 | Entering a row highlights it (only on entry); highlight stays where the pointer left it | `onMouseEnter` | `UITests.PaletteTests/enteringARowHighlightsIt` |
| M-2 | Click a row = Return on it | `onClick` → `select` | `UITests.PaletteTests/clickingARowChoosesIt` |
| M-3 | Click the backdrop → close, keyboard back to the target pane | `onClick={handleDismiss}` | `UITests.PaletteTests/clickingTheBackdropDismissesAndReturnsTheKeyboard` |
| M-4 | Click inside the panel but off a row (padding, border, empty text) → nothing | `stopPropagation` | `UITests.PaletteTests/clickingThePanelOutsideItsRowsDoesNothing` |
| M-5 | Backdrop swallows every pointer event: nothing under it reacts | `position: fixed; inset: 0` | `UITests.PaletteTests/thePanesBeneathTheBackdropDontReact` |
| M-6 | Right-click on the backdrop does nothing (Q-6) | `onClick` | `UITests.PaletteTests/aRightClickOnTheBackdropDoesNothing` |

### Creating and placing

| Id | Case | Electron | Native test |
|---|---|---|---|
| C-1 | Type + Tab on a non-empty pane → new tab beside the target | `placeNewPane(target, content)` → `openContent` | `UITests.PaletteTests/aTypeThenATabOpensItBesideTheTarget` |
| C-2 | …on an **empty** pane → fills it in place (same slot, no new tab or pane) | `tree.openContent` empty branch | `UITests.PaletteTests/aTabOnAnEmptyPaneFillsItInPlaceAndTakesTheKeyboard`, `UITests/thePaletteOffersOnlyCreatableTypes` |
| C-3 | Horizontal / Vertical Split split the target | `placeNewPane(…, direction)` | `UITests.PaletteTests/aTypeThenASplitSplitsTheTarget` |
| C-4 | Unpinned Pane → floating pane in the target section `newUnpinnedPanePosition` names; never docked | `placeNewUnpinnedPane` | `UITests.PaletteTests/aTypeThenAnUnpinnedPaneFloatsIt` |
| C-5 | Palette closes *before* the pane is made (Q-7); natively creation is synchronous | `commit`: `close()` then `await createContentFor` | `UITests.PaletteTests/theOverlayIsGoneByTheTimeThePaneExists` |
| C-6 | Target = pane active when the palette **opened**, not at commit | `step.targetPaneId` | `UITests.PaletteTests/itAimsAtThePaneThatWasActiveWhenItOpened` |
| C-7 | Target looked up at commit: gone → nothing created, palette still closes | `if (!origin) return` | `UITests.PaletteTests/aTargetClosedMeanwhileCreatesNothing`, `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt` |
| C-8 | New pane made from the target's entry leaf (active tab, else a split's first child), per the **created** type's rule: terminal → the shell's live directory; git tree → the target's repository; browser → blank page; empty target or no directory → type default | `createContentFor`, `applyDerivedConfig`, `resolveOriginLeaf`, `exposedCwdOf` | `UITests.PaletteTests/theNewPaneIsMadeFromTheTargetAndAnEmptyTargetOffersNothing`, `LayoutEngineTests/aNewPaneOfAChosenTypeIsMadeFromItsOriginAndPlacedBesideIt`, `UITests.GitTreeUITests/aGitTreeFromATerminalOpensWhereTheShellIs`, `UITests.GitTreeUITests/aTerminalFromAGitTreeStartsInItsRepository` |
| C-9 | New pane active and has the keyboard | focus-follows-active | `UITests.PaletteTests/aTabOnAnEmptyPaneFillsItInPlaceAndTakesTheKeyboard` |
| C-10 | Rows are the only filter. **Deviation:** core's gate (`PaneRuntime.create`) refuses a type disabled while on step 2 (nothing made, palette closed); Electron creates it from the stale row | `createContentFor` (no gate) | `PaneRuntimeTests/creationIsGatedButRestorationIsNot` |
| C-11 | Rows re-derived live; the highlight isn't clamped, so it can point past the end → Return does nothing (Q-2) | `items[highlighted]` undefined → `select` no-op | `UITests.PaletteTests/aTypeTurnedOffWhileOpenLeavesTheList` |
| C-12 | Palette content starts with the type's default title (no override) | `createLeaf` | — (`newPane(ofType:)` passes no title) |
| C-13 | On an empty target nothing is inherited (origin nil), as Electron's toolbar, which passes the blank pane as origin. Native toolbar differs for N-7's empties (Q-8) | `EmptyPaneRenderer` comment | `LayoutEngineTests/aNewPaneOfAChosenTypeOnAnEmptyOriginFillsItAndInheritsNothing` |

### Creation chords, header buttons, tab-strip "+"

| Id | Case | Electron | Native test |
|---|---|---|---|
| N-1 | ⌘T: new tab beside the active pane, content *like* it (terminal → terminal; empty stays empty) | `paneShortcuts.ts:handleNewPane()` | `UITests/windowShortcutsOpenAndCloseTabs`, `LayoutEngineTests/aNewPaneLikeALiveOneIsAnotherOfItsTypeMadeFromIt` |
| N-2 | ⇧⌘T: horizontal split, content like the active pane | `handleNewPane('horizontal')` | `UITests.Keyboard/theNewPaneShortcutsAndClose` |
| N-3 | ⌥⌘T: vertical split | `handleNewPane('vertical')` | ″ |
| N-4 | ⌥⇧⌘T: floating unpinned pane like the active one, in the section the setting names | `handleNewUnpinnedPane` | `UITests.Keyboard/theNewPaneShortcutsAndClose`, `FloatingTests.SpawnRectIn/shippedDefault` |
| N-5 | Chords act on the active pane wherever it is, floating included | handlers look the pane up across every tree | `WindowLayoutTests.OpenContent/insideFloating`, `UITests.Keyboard/theNewPaneShortcutsAndClose` |
| N-6 | Active = docked root group → redirect to its shown tab; ⇧⌘T/⌥⌘T never split the root out of itself | `layoutStore.ts:redirectFromDockedRoot` | `WindowLayoutTests.SplitPane/redirectsFromRoot`, `UITests.HeaderControls/theRootBarsControlsActOnTheShownTab` |
| N-7 | Origin type can't be created (disabled) → empty pane instead of a copy | `createContentLike` | `LayoutEngineTests/aNewPaneLikeOneThatCantBeMadeIsEmptyAndFillsInPlaceFromIt` |
| N-8 | Header Split horizontally (the visible button), Split vertically, New tab, New unpinned tab, tab-strip "+": as the chords, aimed at their own pane/group. Docked root's bar: New tab and New unpinned tab only | `PaneHeaderControls.tsx`, `TabBar.tsx` | `UITests.HeaderControls/splitHorizontallyIsTheRootButton`, `UITests.HeaderControls/theMenuSplitsVerticallyOpensTabsAndWraps`, `UITests.HeaderControls/aNewTabAtAnEmptyPaneReplacesIt`, `UITests.HeaderControls/aNewUnpinnedTabFloatsOverTheTopRightOfItsPane`, `UITests.HeaderControls/theRootBarsControlsActOnTheShownTab`, `UITests.TabStrip/thePlusButtonAddsATabToItsOwnGroupOnly` |
| N-9 | Empty pane toolbar: one segmented button per creatable type; press → fills in place, pane stays active and focused | `EmptyPaneRenderer.tsx` | `UITests/creatingATextPaneFromAnEmptyPaneFocusesIt`, `RendererTests/theEmptyPaneToolbarShowsEachTypesIconAndLabel` |
| N-10 | Empty pane, nothing creatable → the T-6 sentence instead of the toolbar | `NO_CONTENT_TYPES_MESSAGE` | — |

### The File menu

| Id | Case | Electron | Native test |
|---|---|---|---|
| F-1 | File: New Window ⌘N — New Content… ⌘P — New Tab ⌘T, New Horizontal Split ⇧⌘T, New Vertical Split ⌥⌘T, New Unpinned Pane ⌥⇧⌘T, Close Pane ⌘W — Caffeinate…. **Deviation:** Settings… ⌘, is in the app menu (Electron: File, after New Window) | `menu.ts` File submenu | `UITests.PaletteTests/theFileMenuMatchesElectronsAndHasNoNewTabWith` |
| F-2 | No File ▸ New Tab With ▸ <type> (Electron has none) | absent | ″ |
| F-3 | New Content… always enabled; does nothing while a non-workspace window (Settings, Plugins) is key, or with no workspace window | `paneShortcutItem` forwards to the focused window; Settings has no listener | — (`CommandRouter.showPalette`) |
| F-4 | Menu labels are the command titles (`CoreCommand.title`): a rename is one edit | `paneShortcutItem` | — (compile-time) |

### Settings and persistence

| Id | Case | Electron | Native test |
|---|---|---|---|
| D-1 | File ▸ New Tab With removed; the palette replaces it (Scope) | — | see F-2 |
| D-2 | `core.panes.newUnpinnedPanePosition` (nine positions, default `top-right`) places C-4/N-4/N-8; read when the pane is made | `resolveSpawnPosition`, `spawnRectIn` | `FloatingTests.SpawnRectIn/shippedDefault`, `FloatingTests.SpawnRectIn/distinct`, `UITests.HeaderControls/aNewUnpinnedTabFloatsOverTheTopRightOfItsPane` |
| D-3 | Creation gate: a disabled plugin's types get no palette row, no toolbar button, no `contentLike` copy; open panes keep running (Known differences) | `enablement.ts` | `PaneRuntimeTests/creationIsGatedButRestorationIsNot`, `MenuTests/theCreationGateOffersOnlyCreatableTypes`, `UITests/thePaletteOffersOnlyCreatableTypes` |
| D-4 | Palette persists nothing (never in layout.json) | store not persisted | `UITests.PaletteTests/theLayoutIsUntouchedByAPaletteThatCreatesNothing` |
| D-5 | Shortcut overrides in settings.json `core.shortcuts` (stored chord, or null = unbound) | `Settings.shortcuts` | `ShortcutsTests/theUsersBindingsComeFirstAndPersist` |

### Errors and edge cases

| Id | Case | Electron | Native test |
|---|---|---|---|
| E-1 | Plugin refuses to build the pane → palette closed, nothing placed, nothing shown to the user | `fireAndReport` | `UITests.PaletteTests/aRefusedPaneLeavesNoTrace` |
| E-2 | Window resized while open → panel stays centered | flexbox centering | `UITests.PaletteTests/thePanelStaysCenteredWhenTheWindowIsResized` |
| E-3 | Target closed meanwhile (e.g. a control verb) → commit makes nothing (C-7); dismissal focuses nothing | `focusPane` on a missing id no-ops | `UITests.PaletteTests/aTargetClosedMeanwhileCreatesNothing` |
| E-4 | Tall list: panel ≤ 70% of window height, rows keep 30pt, list scrolls (wheel). Unreachable with today's three content types | `max-height: 70vh; overflow-y: auto` | `UITests.PaletteTests/aTallListIsCappedAtSeventyPercentOfTheWindow` (wheel not driven) |
| E-5 | Entering/leaving fullscreen while open → stays centered | flexbox | `UITests.PaletteTests/thePanelStaysCenteredWhenTheWindowIsResized` |

## Look

From `global.css` (`.command-palette*`), `shared/theme.ts`, `content/icons.tsx`. px = pt.
Colors dark / light.

| Id | Element | Box | Text | Colors | States | Scenario |
|---|---|---|---|---|---|---|
| L-1 | Backdrop | Whole window (content view, title-bar band included), `position: fixed; inset: 0`; flex-centers the panel; z 2100 | — | `--bg` at 40% over the layout: `#1e1f24` / `#ffffff` | — | `palette-types` |
| L-2 | Panel | 320 wide (border-box), height = content, ≤ 70% of window; padding 4; border 1; radius 8; column | — | fill `--bg-elevated` `#2a2c33` / `#eff0f3`; border `--border` `#3a3b44` / `#d2d3da`; shadow `0 16 40` black × 0.5 × strength (1 / 0.45) | — | `palette-types` |
| L-3 | Row | Full width of the panel's content box; flex row, centered, gap 8; padding 7 10; radius 4; height = max(icon 16, badge 16, label line 16) + 14 = 30 | system 13, regular, `--text` `#e6e6eb` / `#1c1d22`, left | transparent | highlight (hover/keys): fill `--accent` `#4f8cff` / `#2f6fe4`, text `--on-accent` `#ffffff` | `palette-types`, `palette-types-hover` |
| L-4 | Badge | min-width 16, height 16, padding 0 4, radius 4; content centered | 10, tabular-nums, `currentColor` | `currentColor` at 14% | follows the row's text | `palette-types` |
| L-5 | Type icon | 16×16 (plugin icon, `currentColor`); a text stand-in (harness stub's "▣") is as wide as its glyph (11.25×16), label 8 after it | — | `currentColor` | follows the row | `palette-types` |
| L-6 | Placement icon | 16×16: new tab (13×11 frame + cross), split H, split V, new unpinned (window + corner arrow) | — | `currentColor` | follows the row | `palette-placement` |
| L-7 | Label | `flex: 1`, one line, ellipsis | 13 | inherits the row | — | `palette-types` |
| L-8 | List | column, `overflow-y: auto` | — | — | — | (E-4) |
| L-9 | Empty state | `<p>`, margin 0, padding 10; sentence wraps to 2 lines → panel 60 tall | 12, `--text` at 65% | — | — | `palette-empty` |
| L-10 | Over a floating pane | backdrop and panel paint above the float and its shadow | — | — | — | `palette-over-floating` |
| L-11 | Light theme | light tokens, shadow strength 0.45 | — | see rows | — | `palette-light` |
| L-12 | Backdrop focus ring | Chromium's `outline: auto 1px` on the script-focused backdrop (`tabIndex=-1`): outermost 1px of the window, radius 2, every step (`PaletteView.draw`) | — | `#99c8ff` over dark, `#005fcc` over light, opaque | — | every palette scenario |

## Electron quirks kept for parity

- Q-1: highlight resets only on a step *kind* change (`useEffect([step.kind])`): reopening on
  the type step, or the list changing under it, keeps the old index.
- Q-2: highlight never clamped: a list shrinking under it (type disabled while open) leaves
  Return with nothing to choose.
- Q-3: digits matched on physical key alone (`event.code`), any modifier held; keypad digits
  don't match.
- Q-4: Return chooses the *highlighted* row, not a focused button.
- Q-5: Escape from step 2 closes everything; no way back.
- Q-6: right-click on the backdrop doesn't dismiss (`onClick` = primary button only).
- Q-7: closes before creating (`close()`, then `await createContentFor`); in Electron a slow
  `deriveConfig` shows neither palette nor pane for a moment.
- Q-8: an empty origin offers nothing: the palette on a blank target and Electron's toolbar
  (which passes the blank pane as origin) both give the type's default directory.
  **Deviation:** an empty pane made by N-7 remembers the live pane it was made like
  (`LayoutEngine.creationOrigins`); its toolbar (`fill`) inherits from that pane.
- Q-9: step 1 labels are type display names; step 2 drops "New ". Neither shows a chord or
  the chosen type.
- Q-10: pane nav chords (⌘←/→/↑/↓) still move pane focus while open (`spatialNav` guards
  only modal dialogs); natively `WorkspaceInput`'s monitor takes them before the palette. The
  target stays the pane active at opening.
- Q-11: the backdrop focus ring (L-12) is Chromium's default indicator, not a design; kept
  because Electron shows it.

## Can't be ported as-is

- **Focus theft from a `<webview>` guest**: Electron moves DOM focus off the guest; natively
  the palette becomes first responder, which takes the keyboard from a `WKWebView` the same
  way (P-5, P-6).
- **Chromium focus ring** (L-12): drawn by hand in `PaletteView.draw`.
- **`font-variant-numeric: tabular-nums`**: `NSFont.monospacedDigitSystemFont`
  (`ChromeText(tabularNumbers:)`).

## Checking the look

Scenarios `Visual/scenarios/palette-*.json`: key `palette: {step: "type" | "placement",
highlight?, hover?}`, plus `paletteTypes` (extra stub types). Electron:
`__fakeApi.fireShortcut('command-palette')`, then real keys and mouse; native:
`VisualCapture.openPalette` (`Palette.open`, `choose(0)`, `setHighlight`, `simulatePointer`).
Geometry key `palette`: backdrop, panel, rows (rect, badge, icon, label, baselines), `empty`.

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

- Expected residue: glyph rasterization and shadow blur; geometry exact (half-point tolerance).
- Layer shadow gotchas (shared with the context menu and dialog card): a shadow set in `init`
  is reset before the view shows → set it in `layout()`; `shadowRadius` = the CSS blur, not
  half of it.

## Known differences

- **Settings… is in the app menu**, not File (F-1); the rest of File is Electron's, in order.
- **Creation gate is per plugin** (Tabs ▸ Plugins…), not per content type; the T-6/N-10
  sentence is still Electron's word for word ("Settings → General → Content types"), a place
  that doesn't exist natively.
- **A type disabled on step 2 can't be created** (C-10): core's gate refuses at commit.
- **Unhandled keys are swallowed** (K-7).
- **Toolbar of an N-7 empty pane inherits** from the pane it was made like (Q-8).
