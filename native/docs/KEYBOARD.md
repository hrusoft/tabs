# Keyboard settings

Settings ▸ Keyboard: every rebindable command with its chord, a recorder, a search box that
also takes a pressed combination, and Clear, Reset, Restore Defaults. Port of Electron's
`KeyboardSettings.tsx`, on core's shortcut rules and with a native look (Scope).

## Scope

- What may be recorded, and what happens to a command that loses its chord: native core's
  rules (`Shortcuts`), not Electron's (V-2–V-4, C-1, C-2).
- Fixed (stock) items are neither listed nor rebindable (K-5).
- Native Settings look; not measured against Electron.
- A key monitor on the page replaces Electron's capture mode (Can't be ported as-is).

## Sources

| Native | Electron | What |
|---|---|---|
| `Sources/Tabs/UI/KeyboardSettingsPage.swift` (`KeyboardSettingsModel`, `KeyboardSettingsKeys`, `KeyboardSettingsView`) | `src/renderer/src/settings/KeyboardSettings.tsx`, `settingsRows.tsx` (`SettingsActionRow`), `settings.css` | Model (recording, notice, query), rows, key monitor, search field |
| `Sources/TabsCore/Commands/ShortcutText.swift` | `shortcuts.ts` (`formatBinding`, `parseSearchChord`, `formatChordAsQuery`, `hasRequiredModifier`, `isBareCtrlLetterChord`); `KeyboardSettings.tsx` (`visibleGroups`, `heldModifiers`) | Chord text, search grammar, which rows a query shows |
| `Sources/TabsCore/Commands/Shortcuts.swift` | `shortcuts.ts` (`RESERVED`, `isReservedBinding`, `findConflict`, `resolveBinding`, `isOverridden`); `KeyboardSettings.tsx` (`commit`) | Fixed commands, reserved chords, `Binding.reason`, `holders(of:for:)`, `bind`/`reset`/`resetAll` |
| `Sources/TabsCore/Commands/CoreCommands.swift` | `shortcuts.ts` (`ACTION_SPECS`) | Each core command's label, summary, group, fixed or not |
| SDK `CommandContribution.summary` | `ShortcutActionSpec.description` | A plugin command's row description |
| `Shortcuts.resetAll()` → `SettingsStore.setShortcuts([:])` | `setSetting('shortcuts', {})` | Restore Defaults |
| `Sources/Tabs/UI/PluginsWindow.swift` (`makeSettingsWindow`, `SettingsPageSizing`) | `registerBuiltinPages.ts` (Keyboard at order 5) | Page position and size |
| `MainMenu.swift` (`build`, `arm`), `WorkspaceInput.swift`, `PaneRuntime.isAppShortcut` | `src/main/menu.ts` (`acceleratorFor`), `content/spatialNav.ts`, `plugin-browser/main/guestNavKeys.ts` | Enforcement; each reads the table live, the menu is rebuilt on every change |
| — | `src/main/shortcuts.ts`, `src/main/shortcutCapture.ts` | Capture mode (Can't be ported as-is) |

## Cases

`UITests.KeyboardSettings` (`Tests/TabsAppTests/KeyboardSettingsTests.swift`): the real page
in a Settings window beside a real workspace and its menu. `ShortcutsTests`,
`ShortcutTextTests`: `Tests/TabsCoreTests`.

### The list

| Id | Case | Electron | Native test |
|---|---|---|---|
| K-1 | Every rebindable command at its effective chord, grouped: Application, Panes & Tabs, Navigation (core's, Electron's order), then one group per plugin with commands, titled with its display name, in UI order | `visibleGroups` | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding`, `ShortcutsTests/everyCommandHasItsLabelDescriptionAndGroup`, `ShortcutTextTests/anEmptyQueryShowsEveryRebindableCommandInItsGroups` |
| K-2 | Row: label, description, chip (chord in macOS order ⌃⌥⇧⌘ then key: "⌘T", "⌘←", "⌥⌘T", "⌘Enter", "⌃Space", "⌘⌫", "F5"), Clear; Reset only while overridden | `ShortcutRow`, `formatBinding` | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding`, `ShortcutTextTests/usesMacOSGlyphsInTheOrderMacOSItselfShowsThem`, `ShortcutTextTests/namesTheKeysAsTheElectronPageDoes` |
| K-3 | Unbound: chip reads "Not set", dimmed; Clear disabled | `data-unbound`, `disabled={binding === null}` | `UITests.KeyboardSettings/clearingStoresAnExplicitUnbinding` |
| K-4 | Nothing overridden → no Reset anywhere | `isOverridden` | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding` |
| K-5 | Fixed items not listed: Quit, Hide, Hide Others, Undo, Redo, Cut, Copy, Paste, Select All, Minimize | not in `SHORTCUT_ACTIONS` (stock roles) | `UITests.KeyboardSettings/theFixedItemsAreNotListed`, `ShortcutsTests/theFixedCommandsCantBeRebound` |
| K-6 | Paragraph: "Click a shortcut to record a new combination, then press it. Escape cancels. Combinations the system owns (Copy, Quit, Undo…) and keys scoped to one control (Escape, Enter, Tab) can’t be reassigned." | page copy | — (in the `settings-keyboard` snapshot) |
| K-7 | Default chord given way to another command → "Not set" + which command has it ("⌘W is taken by New Tab.") | — (native-only: Electron stores the loser as unset, C-1) | `UITests.KeyboardSettings/recordingAChordAnotherCommandHoldsTakesIt` |
| K-8 | Stored shortcut unusable → row keeps its default, says "Your shortcut “cmd+c” can’t be used here, so it has its default.", offers Reset | — (native-only: Electron drops a malformed entry at load, `sanitizeShortcutOverrides`) | `UITests.KeyboardSettings/storedBindingsShowOnThePageAndInTheMenu`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable` |
| K-9 | Tab order: Panes & Tabs, Keyboard, plugins' pages, AI last | `registerBuiltinPages` order 5 | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding` |

### Recording

| Id | Case | Electron | Native test |
|---|---|---|---|
| R-1 | Click a chip → reads "Press keys…", accent bezel; gets every key in the Settings window, menu chords included (⌘T, ⌘W, ⌘K, ⌘,) | `startCapture`, capture mode | `UITests.KeyboardSettings/recordingACombinationWritesItAndDisarms`, `UITests.KeyboardSettings/aChordTheMenuHoldsIsRecordedNotPerformed`, `UITests.KeyboardSettings/theMonitorGetsTheAppsKeysFirst` |
| R-2 | Held modifiers show live in the chip ("⌃", "⌃⌥"), back to "Press keys…" on release | `heldModifiers`, keyup listener | `UITests.KeyboardSettings/heldModifiersShowInTheChip` |
| R-3 | A combination → recorded, stored, disarmed | `commit` | `UITests.KeyboardSettings/recordingACombinationWritesItAndDisarms` |
| R-4 | Escape (any modifiers) cancels; binding untouched, nothing stored | `event.key === 'Escape'` | `UITests.KeyboardSettings/escapeCancelsLeavingTheBindingUntouched` |
| R-5 | Clicking the armed chip again cancels | `startCapture` toggle | `UITests.KeyboardSettings/clickingTheArmedChipAgainCancelsAndAnotherMovesTheRecording` |
| R-6 | Clicking another chip moves the recording there | `setCapturing(id)` | ″ |
| R-7 | Tab (⇧Tab too) ends the recording and moves focus on; never recorded | `event.key === 'Tab'` | `UITests.KeyboardSettings/tabEndsTheRecordingAndIsNeverRecorded` |
| R-8 | Settings window resigning key ends the recording | `window` `blur` | `UITests.KeyboardSettings/theWindowLosingFocusEndsTheRecording` |
| R-9 | Leaving the page or closing the window ends the recording, menu chords work again; the monitor goes with the page (reopened window records again) | effect cleanup | `UITests.KeyboardSettings/closingTheSettingsWindowMidRecordingLetsGoOfTheKeyboard`, `UITests.KeyboardSettings/leavingThePageEndsTheRecording`, `UITests.KeyboardSettings/thePagesMonitorGoesWithThePage` |
| R-10 | Clear, Reset, Restore Defaults first end any recording and clear the notice | `settleAnd` | `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce` |
| R-11 | Refused press leaves the chip armed (a correction, not a cancel) | `commit` refusals | `UITests.KeyboardSettings/aCombinationWithoutCommandOrControlIsRefused` |
| R-12 | Arming a chip clears the previous notice | `startCapture` | `UITests.KeyboardSettings/aNoticeIsItsRowsUntilTheNextRecording` |
| R-13 | One notice at a time, under its own row in place of the description (error red, info accent), until the next interaction | `Notice`, `SettingsActionRow` `tone` | `UITests.KeyboardSettings/aNoticeIsItsRowsUntilTheNextRecording`, `UITests.KeyboardSettings/aCombinationWithoutCommandOrControlIsRefused` |
| R-14 | Recording: a fixed item's chord (⌘Q, ⌘H, ⌘M…) is refused as reserved, not performed. **Deviation:** Electron on macOS runs the stock item | role accelerators stay in capture mode | `UITests.KeyboardSettings/aCombinationTheSystemOwnsIsRefused` |

### What may be recorded (core's rules)

| Id | Case | Electron | Native test |
|---|---|---|---|
| V-1 | Key with no shortcut form (Home, End, Page Up/Down, forward Delete, a dead key) → error "That key cannot be used as a shortcut." | `toAccelerator` null | `UITests.KeyboardSettings/aKeyWithNoShortcutFormIsRefused`, `ShortcutTextTests/keysWithNoShortcutFormAreRefused` |
| V-2 | No ⌘ or ⌃ (bare key, ⇧ or ⌥ alone) → error "Add ⌘ or ⌃ to the combination." **Deviation:** Electron accepts ⌥ alone ("Add ⌘, ⌃ or ⌥") | `hasRequiredModifier` | `UITests.KeyboardSettings/aCombinationWithoutCommandOrControlIsRefused`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-3 | Command for every pane (no `appliesTo`), ⌃ without ⌘ → error "Add ⌘ to the combination: ⌃ alone is left to the pane you’re typing in." **Deviation:** Electron accepts it (with V-6's notice) | — | `UITests.KeyboardSettings/controlAloneIsLeftToThePaneForCommandsThatWorkEverywhere`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-4 | Bare function key (F5) accepted. **Deviation:** Electron refuses it | `hasRequiredModifier` | `UITests.KeyboardSettings/aBareFunctionKeyIsAccepted`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-5 | Reserved chord (fixed items' chords, ⌃⌘F) → error "⌘C is reserved by the system." | `isReservedBinding` | `UITests.KeyboardSettings/aCombinationTheSystemOwnsIsRefused`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable` |
| V-6 | ⌃ + letter on a pane type's command → accepted with info "⌃L is also used inside Terminal panes." (the command's type; Electron: "…is also used by programs in terminal panes.") | `isBareCtrlLetterChord` notice | `UITests.KeyboardSettings/controlLetterOnAPaneTypesCommandWarns` |

### Conflicts

| Id | Case | Electron | Native test |
|---|---|---|---|
| C-1 | Chord another command holds (overlapping scope) → taken, info "Taken from Close Pane."; the loser isn't stored, gets its default back once the chord is free. **Deviation:** Electron stores the loser as unset ("…, now unset.") | `findConflict` | `UITests.KeyboardSettings/recordingAChordAnotherCommandHoldsTakesIt`, `ShortcutsTests/theLoserGivesWayOrGoesBackToItsDefault`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-2 | Loser held the chord by the user's own binding → that binding is dropped, back to its default. **Deviation:** Electron: unset | — | `UITests.KeyboardSettings/aChordForEveryPaneTakesItFromEveryPaneTypesCommand`, `ShortcutsTests/theLoserGivesWayOrGoesBackToItsDefault` |
| C-3 | Commands for different pane types may share a chord: no conflict, no notice | — (native-only: no scopes in Electron) | `UITests.KeyboardSettings/commandsForDifferentPaneTypesShareAChord`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-4 | Chord for every pane over several pane types' commands takes it from all: "Taken from Clear Buffer and Refresh." | — (native-only: one holder at most in Electron) | `UITests.KeyboardSettings/aChordForEveryPaneTakesItFromEveryPaneTypesCommand`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-5 | Recording a command back onto its default drops the override (no Reset), unless that default would then lose to another default: then it stays the user's | `bindingsEqual(binding, defaultBinding)` | `UITests.KeyboardSettings/recordingACommandBackOntoItsDefaultDropsTheOverride`, `ShortcutsTests/bindingACommandBackToItsDefaultDropsTheOverride` |

### Clear, Reset, Restore Defaults

| Id | Case | Electron | Native test |
|---|---|---|---|
| E-1 | Clear stores an explicit unbinding (null): "Not set", Clear disabled, Reset shown | ShortcutRow Clear | `UITests.KeyboardSettings/clearingStoresAnExplicitUnbinding` |
| E-2 | Reset removes that row's override only | ShortcutRow Reset | `UITests.KeyboardSettings/resettingARowRemovesItsOverrideEntirely` |
| E-3 | Restore Defaults ("Put every shortcut back to the combination it ships with.") removes every override at once | `setSetting('shortcuts', {})` | `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce`, `ShortcutsTests/resetAllForgetsEveryBinding` |
| E-4 | A second rebind keeps the first | `write` (whole record) | `UITests.KeyboardSettings/aSecondRebindKeepsTheFirst` |

### Search

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-1 | Search field above the list: "Search shortcuts, or press a combination…" | page | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups` |
| S-2 | Text filters to rows whose label, description or group contains it, case-insensitively | `visibleGroups` | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups`, `ShortcutTextTests/typingTextFiltersToMatchingLabelsDescriptionsAndGroups` |
| S-3 | A group with no matching row loses its heading | `visibleGroups` | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups` |
| S-4 | Typed combination ("cmd+t"; modifier words in any order: cmd/command/mod, ctrl/control, alt/opt/option, shift; keys: a character, f1–f20, left/right/up/down, space, return, backspace/delete, tab, escape/esc) matches the command bound to it now, exactly (⇧⌘T isn't ⌘T) | `parseSearchChord` | `UITests.KeyboardSettings/typingABoundCombinationFiltersToItExactly`, `ShortcutTextTests/doesNotCareAboutTokenOrder`, `ShortcutTextTests/parsesDigitsFKeysAndNamedKeys`, `ShortcutTextTests/aCombinationMatchesTheCommandBoundToItExactly` |
| S-5 | Combination query follows a rebind, not the default | `resolveBinding` | `UITests.KeyboardSettings/aCombinationQueryFollowsARebind` |
| S-6 | Clear button empties the field, whole list back | clear button | `UITests.KeyboardSettings/theClearButtonEmptiesTheFieldAndRestoresTheList` |
| S-7 | No match → "No shortcuts match your search." | empty state | `UITests.KeyboardSettings/aQueryMatchingNothingShowsTheEmptyState` |
| S-8 | Field focused: a combination with ⌘, ⌃ or ⌥ types its query text ("cmd+t", modifiers ordered cmd, ctrl, alt, shift) instead of running | `handleSearchKeyDown` | `UITests.KeyboardSettings/pressingABoundCombinationInTheSearchFieldTypesIt` |
| S-9 | …a nav chord too ("cmd+left"), moving nothing | ″ | `UITests.KeyboardSettings/pressingANavCombinationWhileSearchingTypesItToo` |
| S-10 | …at the cursor, replacing the selection | ″ | `UITests.KeyboardSettings/pressingACombinationInsertsItAtTheCursor` |
| S-11 | Bare typing and ⇧ letters are ordinary typing | `hasRequiredModifier` | `UITests.KeyboardSettings/bareTypingInTheSearchFieldIsUntouched` |
| S-12 | Reserved chords keep their meaning in the field (⌘A, ⌘V, ⌘C, ⌘Z): the monitor leaves them to the menu | stock role accelerators aren't suspended | `UITests.KeyboardSettings/aFixedItemsChordKeepsItsMeaningInTheField` (the menu acting on the field isn't driven: no window is key in tests) |
| S-13 | Focusing the field ends a chip's recording and the field takes typing; clicking a chip takes the keyboard back from the field | `onFocus` | `UITests.KeyboardSettings/focusingTheSearchFieldEndsARecording`, `UITests.KeyboardSettings/clickingAChipTakesTheKeyboardFromTheSearchField` |
| S-14 | Key with no query spelling (Home…) passes through | `formatChordAsQuery` null | `ShortcutTextTests/returnsNilForAKeyWithNoSpelling` |

### Effects, persistence, control

| Id | Case | Electron | Native test |
|---|---|---|---|
| M-1 | Rebind → menu item's key equivalent changes at once; item still works | menu rebuilt | `UITests.KeyboardSettings/aRebindChangesTheMenuAtOnceAndTheItemStillWorks` |
| M-2 | Cleared command keeps its menu item, no key equivalent, still usable | `acceleratorFor` → none | `UITests.KeyboardSettings/aClearedCommandKeepsItsMenuItemWithNoKeyEquivalent` |
| M-3 | Rebound nav chord moves pane focus; the old one doesn't | `spatialNav` | `UITests.KeyboardSettings/aReboundNavigationChordMovesPaneFocus` |
| M-4 | settings.json `core.shortcuts`: stored chord (`opt+cmd+n`), null = unbound, absent = default; relaunch restores menu and page | `Settings.shortcuts` | `UITests.KeyboardSettings/storedBindingsShowOnThePageAndInTheMenu`, `ShortcutsTests/theUsersBindingsComeFirstAndPersist` |
| M-5 | `tabs.setShortcut` (`none` unbinds, `default` resets) follows the same rules: fixed commands and reserved chords refused, back-to-default drops the override | — (native-only verb) | `ShortcutsTests/theFixedCommandsCantBeRebound`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable`, `ShortcutsTests/bindingACommandBackToItsDefaultDropsTheOverride`, `ShortcutsTests/theControlVerbsListAndRebind` |
| M-6 | `tabs.shortcuts` reports `fixed` per command | — (native-only verb) | `ShortcutsTests/theControlVerbsListAndRebind` |

## Look

Native Settings page (grouped `Form`, like Panes & Tabs and AI); not compared with Electron.

| Id | Element | Native |
|---|---|---|
| L-1 | Page | Grouped form, 600pt wide (`SettingsPageContribution.width`), as tall as the window allows (≤ 640pt, less on a short screen); list scrolls under a pinned header (search field + how-to line) over a divider |
| L-2 | Search | `NSSearchField` (own clear button, shown while there's text), aligned with the cards |
| L-3 | Chip | Push button ≥ 104pt wide, chord as title; "Not set" in secondary label color; recording: accent bezel |
| L-4 | Notice | In place of the description: error system red, info accent color; a "taken by" / "can't be used" line joins it, secondary |
| L-5 | Clear, Reset, Restore Defaults | Push buttons, 6pt apart. Row order Reset (while overridden), chip, Clear, so chip and Clear keep their columns (Electron: chip, Clear, Reset). Restore Defaults below the last group, right-aligned, description beside it |
| L-6 | No match | "No shortcuts match your search." centered in a card; Restore Defaults still below |

## Electron quirks kept

- ⌘← / ⌘→ in the search field type "cmd+left" / "cmd+right" instead of moving the caret (S-9).
- ⌥ counts as a real modifier in the search field (`hasRequiredModifier`): on a layout that
  types characters with ⌥ (⌥L = @ on German) the field gets "alt+l", not the character.
- Restore Defaults also forgets overrides of commands whose plugins aren't loaded (Electron
  writes `{}`).

## Can't be ported as-is

- **Capture mode.** Electron strips every customizable accelerator off the menu while a chip
  records or the search field has focus (`src/main/shortcuts.ts`), since macOS gives the menu
  a key equivalent before the page sees it. Native: a local key monitor
  (`KeyboardSettingsKeys`) on the page's own window, installed while the page is in the window,
  acting only while a chip records or the search field edits. The menu keeps its chords. It
  leaves with the page (another tab, window closed), so it can't outlive the window as a stuck
  capture mode could. Visible effect: R-14.
- **Physical keys.** Electron stores `KeyboardEvent.code`; native chords are the characters
  keys make, as AppKit menus match them. ⇧⌘1 records as ⌘!, query text "cmd+!".

## Checking the look

With `TABS_SNAPSHOT_DIR` set, `UITests.KeyboardSettings` writes `settings-keyboard.png` (at
rest), `-recording`, `-refused`, `-taken`, `-empty`.

## Known differences

- Rules for what may be recorded and for losers are core's (Scope; V-2–V-4, C-1, C-2).
- Reserved chords: fixed items' and ⌃⌘F (AppKit's Enter Full Screen). Electron also reserves
  ⌘Y, ⇧⌘V, ⌥⌘I, ⇧⌘I, ⌘0, ⌘-, ⇧⌘= for menu items native doesn't have.
- Clear Buffer and Refresh are plugin commands in Terminal and Git tree groups, acting on
  their own pane type, not app-wide Panes & Tabs actions (TERMINAL.md T-125, GIT-TREE.md
  K-1). Every plugin command is listed, grouped under its plugin's name.
- Open Plugins (Application) is a native-only row.
- Recording refuses a fixed item's chord instead of running it (R-14).
- Row button order Reset, chip, Clear (L-5).
- Search clear button is `NSSearchField`'s: hidden while empty (Electron: × disabled, "Clear
  search" tooltip).
