# Keyboard settings

Settings ▸ Keyboard: every rebindable command with its chord, a recorder, a search box that
also takes a pressed combination, and Clear, Reset, Restore Defaults. Code:
`Sources/Tabs/UI/KeyboardSettingsPage.swift` (the page) on core's shortcut table
(`Sources/TabsCore/Commands`).

## Scope

- What may be recorded, and what happens to a command that loses its chord: core's rules
  (`Shortcuts`), the same ones `tabs.setShortcut` follows (V-1–V-6, C-1–C-5, M-5).
- Fixed (stock) items are neither listed nor rebindable (K-5).
- A standard Settings page (grouped `Form`); no `Visual/` scenario.
- While a chip records or the search field edits, a key monitor on the page takes keys before
  the menu (Implementation notes).

## Sources

| File | What |
|---|---|
| `Sources/Tabs/UI/KeyboardSettingsPage.swift` (`KeyboardSettingsModel`, `KeyboardSettingsKeys`, `KeyboardSettingsView`) | Model (recording, notice, query), rows, key monitor, search field |
| `Sources/TabsCore/Commands/ShortcutText.swift` | Chord text, search grammar, which rows a query shows |
| `Sources/TabsCore/Commands/Shortcuts.swift` | Fixed commands, reserved chords, `Binding.reason`, `holders(of:for:)`, `bind`/`reset`/`resetAll` |
| `Sources/TabsCore/Commands/CoreCommands.swift` | Each core command's label, summary, group, fixed or not |
| SDK `CommandContribution.summary` | A plugin command's row description |
| `Shortcuts.resetAll()` → `SettingsStore.setShortcuts([:])` | Restore Defaults |
| `Sources/Tabs/UI/PluginsWindow.swift` (`makeSettingsWindow`, `SettingsPageSizing`) | Page position and size |
| `MainMenu.swift` (`build`, `arm`), `WorkspaceInput.swift`, `PaneRuntime.isAppShortcut` | Enforcement; each reads the table live, the menu is rebuilt on every change |

## Cases

`UITests.KeyboardSettings` (`Tests/TabsAppTests/KeyboardSettingsTests.swift`): the real page
in a Settings window beside a real workspace and its menu, the plugins being the stand-ins
(`text.insertMarker` ⇧⌘D and `inert.refresh` ⌘R: two pane types' commands). Without the page
(`Tests/TabsAppTests/KeyboardSettingsModelTests.swift`, the same plugins): `KeyboardSettingsModelTests`,
the model's recording, notices and query; `UITests.KeyboardSettingsKeyHandling`, what the page's
keyboard does with each key, in a plain window with a search field. `ShortcutsTests`,
`ShortcutTextTests`: `Tests/TabsCoreTests`.

### The list

| Id | Case | Test |
|---|---|---|
| K-1 | Every rebindable command at its effective chord, grouped: Application, Panes & Tabs, Navigation (core's), then one group per plugin with commands, titled with its display name, in UI order | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding`, `ShortcutsTests/everyCommandHasItsLabelDescriptionAndGroup`, `ShortcutTextTests/anEmptyQueryShowsEveryRebindableCommandInItsGroups` |
| K-2 | Row: label, description, chip (chord in macOS order ⌃⌥⇧⌘ then key: "⌘T", "⌘←", "⌥⌘T", "⌘Enter", "⌃Space", "⌘⌫", "F5"), Clear; Reset only while overridden | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding`, `ShortcutTextTests/usesMacOSGlyphsInTheOrderMacOSItselfShowsThem`, `ShortcutTextTests/namesTheKeys` |
| K-3 | Unbound: chip reads "Not set", dimmed; Clear disabled | `UITests.KeyboardSettings/clearingStoresAnExplicitUnbinding` |
| K-4 | Nothing overridden → no Reset anywhere | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding` |
| K-5 | Fixed items not listed: Quit, Hide, Hide Others, Undo, Redo, Cut, Copy, Paste, Select All, Minimize | `ShortcutTextTests/anEmptyQueryShowsEveryRebindableCommandInItsGroups`, `ShortcutsTests/theFixedCommandsCantBeRebound` |
| K-6 | Paragraph: "Click a shortcut to record a new combination, then press it. Escape cancels. Combinations the system owns (Copy, Quit, Undo…) and keys scoped to one control (Escape, Enter, Tab) can’t be reassigned." | — (in the `settings-keyboard` snapshot) |
| K-7 | Default chord given way to another command → "Not set" + which command has it ("⌘W is taken by New Tab.") | `UITests.KeyboardSettings/recordingAChordAnotherCommandHoldsTakesIt` |
| K-8 | Stored shortcut unusable → row keeps its default, says "Your shortcut “cmd+c” can’t be used here, so it has its default.", offers Reset | `UITests.KeyboardSettings/storedBindingsShowOnThePageAndInTheMenu`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable` |
| K-9 | Tab order: Panes & Tabs, Keyboard, plugins' pages, AI last | `UITests.KeyboardSettings/listsEveryCommandAtItsDefaultBinding` |

### Recording

| Id | Case | Test |
|---|---|---|
| R-1 | Click a chip → reads "Press keys…", accent bezel; gets every key in the Settings window, menu chords included (⌘T, ⌘W, ⌘K, ⌘,) | `UITests.KeyboardSettings/recordingACombinationWritesItAndDisarms`, `UITests.KeyboardSettingsKeyHandling/aChordTheMenuHoldsIsRecordedNotPerformed`, `UITests.KeyboardSettings/theMonitorGetsTheAppsKeysFirst` |
| R-2 | Held modifiers show live in the chip ("⌃", "⌃⌥"), back to "Press keys…" on release | `UITests.KeyboardSettings/recordingACombinationWritesItAndDisarms`, `UITests.KeyboardSettingsKeyHandling/heldModifiersShowInTheChip` |
| R-3 | A combination → recorded, stored, disarmed | `UITests.KeyboardSettings/recordingACombinationWritesItAndDisarms` |
| R-4 | Escape (any modifiers) cancels; binding untouched, nothing stored | `UITests.KeyboardSettingsKeyHandling/escapeCancelsLeavingTheBindingUntouched` |
| R-5 | Clicking the armed chip again cancels | `KeyboardSettingsModelTests/clickingTheArmedChipAgainCancelsAndAnotherMovesTheRecording` |
| R-6 | Clicking another chip moves the recording there | ″ |
| R-7 | Tab (⇧Tab too) ends the recording and moves focus on; never recorded | `UITests.KeyboardSettingsKeyHandling/tabEndsTheRecordingAndIsNeverRecorded` |
| R-8 | Settings window resigning key ends the recording | `UITests.KeyboardSettingsKeyHandling/theWindowLosingFocusEndsTheRecording` |
| R-9 | Leaving the page or closing the window ends the recording, menu chords work again; the monitor goes with the page (reopened window records again) | `UITests.KeyboardSettings/closingTheSettingsWindowMidRecordingLetsGoOfTheKeyboard`, `UITests.KeyboardSettings/leavingThePageEndsTheRecording`, `UITests.KeyboardSettings/thePagesMonitorGoesWithThePage` |
| R-10 | Clear, Reset, Restore Defaults first end any recording and clear the notice | `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce`, `KeyboardSettingsModelTests/resettingARowRemovesItsOverrideEntirely` |
| R-11 | Refused press leaves the chip armed (a correction, not a cancel) | `KeyboardSettingsModelTests/aCombinationWithoutCommandOrControlIsRefused`, `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce` |
| R-12 | Arming a chip clears the previous notice | `KeyboardSettingsModelTests/aNoticeIsItsRowsUntilTheNextRecording` |
| R-13 | One notice at a time, under its own row in place of the description (error red, info accent), until the next interaction | `KeyboardSettingsModelTests/aNoticeIsItsRowsUntilTheNextRecording`, `KeyboardSettingsModelTests/aCombinationWithoutCommandOrControlIsRefused`, `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce` |
| R-14 | Recording: a fixed item's chord (⌘Q, ⌘H, ⌘M…) is refused as reserved, not performed | `UITests.KeyboardSettingsKeyHandling/aCombinationTheSystemOwnsIsRefused` |

### What may be recorded (core's rules)

| Id | Case | Test |
|---|---|---|
| V-1 | Key with no shortcut form (Home, End, Page Up/Down, forward Delete, a dead key) → error "That key cannot be used as a shortcut." | `UITests.KeyboardSettingsKeyHandling/aKeyWithNoShortcutFormIsRefused`, `ShortcutTextTests/keysWithNoShortcutFormAreRefused` |
| V-2 | No ⌘ or ⌃ (bare key, ⇧ or ⌥ alone) → error "Add ⌘ or ⌃ to the combination." | `KeyboardSettingsModelTests/aCombinationWithoutCommandOrControlIsRefused`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-3 | Command for every pane (no `appliesTo`), ⌃ without ⌘ → error "Add ⌘ to the combination: ⌃ alone is left to the pane you’re typing in." | `KeyboardSettingsModelTests/controlAloneIsLeftToThePaneForCommandsThatWorkEverywhere`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-4 | Bare function key (F5) accepted | `KeyboardSettingsModelTests/aBareFunctionKeyIsAccepted`, `ShortcutsTests/whatTheUserMayRecordFollowsCoresRules` |
| V-5 | Reserved chord (fixed items' chords; ⌃⌘F, AppKit's Enter Full Screen) → error "⌘C is reserved by the system." | `UITests.KeyboardSettingsKeyHandling/aCombinationTheSystemOwnsIsRefused`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable` |
| V-6 | ⌃ + letter on a pane type's command → accepted with info "⌃L is also used inside Terminal panes." (naming the command's pane type) | `KeyboardSettingsModelTests/controlLetterOnAPaneTypesCommandWarns` |

### Conflicts

| Id | Case | Test |
|---|---|---|
| C-1 | Chord another command holds (overlapping scope) → taken, info "Taken from Close Pane."; the loser isn't stored, gets its default back once the chord is free | `UITests.KeyboardSettings/recordingAChordAnotherCommandHoldsTakesIt`, `ShortcutsTests/theLoserGivesWayOrGoesBackToItsDefault`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-2 | Loser held the chord by the user's own binding → that binding is dropped, back to its default | `KeyboardSettingsModelTests/aChordForEveryPaneTakesItFromEveryPaneTypesCommand`, `ShortcutsTests/theLoserGivesWayOrGoesBackToItsDefault` |
| C-3 | Commands for different pane types may share a chord: no conflict, no notice | `KeyboardSettingsModelTests/commandsForDifferentPaneTypesShareAChord`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-4 | Chord for every pane over several pane types' commands takes it from all: "Taken from Clear Buffer and Refresh." | `KeyboardSettingsModelTests/aChordForEveryPaneTakesItFromEveryPaneTypesCommand`, `ShortcutsTests/holdersAreTheCommandsWithTheChordInAnOverlappingScope` |
| C-5 | Recording a command back onto its default drops the override (no Reset), unless that default would then lose to another default: then it stays the user's | `KeyboardSettingsModelTests/recordingACommandBackOntoItsDefaultDropsTheOverride`, `ShortcutsTests/bindingACommandBackToItsDefaultDropsTheOverride` |

### Clear, Reset, Restore Defaults

| Id | Case | Test |
|---|---|---|
| E-1 | Clear stores an explicit unbinding (null): "Not set", Clear disabled, Reset shown | `UITests.KeyboardSettings/clearingStoresAnExplicitUnbinding` |
| E-2 | Reset removes that row's override only | `UITests.KeyboardSettings/clearingStoresAnExplicitUnbinding`, `KeyboardSettingsModelTests/resettingARowRemovesItsOverrideEntirely` |
| E-3 | Restore Defaults ("Put every shortcut back to the combination it ships with.") removes every override at once, those of commands whose plugins aren't loaded included | `UITests.KeyboardSettings/restoreDefaultsClearsEveryOverrideAtOnce`, `ShortcutsTests/resetAllForgetsEveryBinding` |
| E-4 | A second rebind keeps the first | `KeyboardSettingsModelTests/aSecondRebindKeepsTheFirst` |

### Search

| Id | Case | Test |
|---|---|---|
| S-1 | Search field above the list: "Search shortcuts, or press a combination…" | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups` |
| S-2 | Text filters to rows whose label, description or group contains it, case-insensitively | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups`, `ShortcutTextTests/typingTextFiltersToMatchingLabelsDescriptionsAndGroups` |
| S-3 | A group with no matching row loses its heading | `UITests.KeyboardSettings/typingTextFiltersTheListAndDropsEmptyGroups` |
| S-4 | Typed combination ("cmd+t"; modifier words in any order: cmd/command/mod, ctrl/control, alt/opt/option, shift; keys: a character, f1–f20, left/right/up/down, space, return, backspace/delete, tab, escape/esc) matches the command bound to it now, exactly (⇧⌘T isn't ⌘T) | `UITests.KeyboardSettings/pressingABoundCombinationInTheSearchFieldTypesIt`, `ShortcutTextTests/doesNotCareAboutTokenOrder`, `ShortcutTextTests/parsesDigitsFKeysAndNamedKeys`, `ShortcutTextTests/aCombinationMatchesTheCommandBoundToItExactly` |
| S-5 | Combination query follows a rebind, not the default | `KeyboardSettingsModelTests/aCombinationQueryFollowsARebind` |
| S-6 | Clear button empties the field, whole list back | `UITests.KeyboardSettings/theClearButtonEmptiesTheFieldAndRestoresTheList` |
| S-7 | No match → "No shortcuts match your search." | `UITests.KeyboardSettings/theClearButtonEmptiesTheFieldAndRestoresTheList`, `ShortcutTextTests/typingTextFiltersToMatchingLabelsDescriptionsAndGroups` |
| S-8 | Field focused: a combination with ⌘, ⌃ or ⌥ types its query text ("cmd+t", modifiers ordered cmd, ctrl, alt, shift) instead of running. ⌥ counts too (`hasRequiredModifier`): on a layout that types characters with ⌥ (⌥L = @ on German) the field gets "alt+l", not the character | `UITests.KeyboardSettings/pressingABoundCombinationInTheSearchFieldTypesIt` |
| S-9 | …a nav chord too ("cmd+left"), moving neither pane focus nor the caret | `UITests.KeyboardSettingsKeyHandling/pressingANavCombinationWhileSearchingTypesItToo` |
| S-10 | …at the cursor, replacing the selection | `UITests.KeyboardSettingsKeyHandling/pressingACombinationInsertsItAtTheCursor` |
| S-11 | Bare typing and ⇧ letters are ordinary typing | `UITests.KeyboardSettingsKeyHandling/bareTypingInTheSearchFieldIsUntouched` |
| S-12 | Reserved chords keep their meaning in the field (⌘A, ⌘V, ⌘C, ⌘Z): the monitor leaves them to the menu | `UITests.KeyboardSettingsKeyHandling/aFixedItemsChordKeepsItsMeaningInTheField` (the menu acting on the field isn't driven: no window is key in tests) |
| S-13 | Focusing the field ends a chip's recording and the field takes typing; clicking a chip takes the keyboard back from the field | `UITests.KeyboardSettings/focusingTheSearchFieldEndsARecording`, `UITests.KeyboardSettings/clickingAChipTakesTheKeyboardFromTheSearchField` |
| S-14 | Key with no query spelling (Home…) passes through | `ShortcutTextTests/returnsNilForAKeyWithNoSpelling` |

### Effects, persistence, control

| Id | Case | Test |
|---|---|---|
| M-1 | Rebind → menu item's key equivalent changes at once; item still works | `UITests.KeyboardSettings/aRebindChangesTheMenuAtOnceAndTheItemStillWorks` |
| M-2 | Cleared command keeps its menu item, no key equivalent, still usable | `UITests.KeyboardSettings/aClearedCommandKeepsItsMenuItemWithNoKeyEquivalent` |
| M-3 | Rebound nav chord moves pane focus; the old one doesn't | `UITests.KeyboardSettings/aReboundNavigationChordMovesPaneFocus` |
| M-4 | settings.json `core.shortcuts`: stored chord (`opt+cmd+n`), null = unbound, absent = default; relaunch restores menu and page | `UITests.KeyboardSettings/storedBindingsShowOnThePageAndInTheMenu`, `ShortcutsTests/theUsersBindingsComeFirstAndPersist` |
| M-5 | `tabs.setShortcut` (`none` unbinds, `default` resets) follows the same rules: fixed commands and reserved chords refused, back-to-default drops the override | `ShortcutsTests/theFixedCommandsCantBeRebound`, `ShortcutsTests/reservedChordsAreRefusedAndAStoredOneIsUnusable`, `ShortcutsTests/bindingACommandBackToItsDefaultDropsTheOverride`, `ShortcutsTests/theControlVerbsListAndRebind` |
| M-6 | `tabs.shortcuts` reports `fixed` per command | `ShortcutsTests/theControlVerbsListAndRebind` |

## Look

A standard Settings page (grouped `Form`, like Panes & Tabs and AI).

| Id | Element | Look |
|---|---|---|
| L-1 | Page | Grouped form, 600pt wide (`SettingsPageContribution.width`), as tall as the window allows (≤ 640pt, less on a short screen); list scrolls under a pinned header (search field + how-to line) over a divider |
| L-2 | Search | `NSSearchField` (own clear button, shown while there's text), aligned with the cards |
| L-3 | Chip | Push button ≥ 104pt wide, chord as title; "Not set" in secondary label color; recording: accent bezel |
| L-4 | Notice | In place of the description: error system red, info accent color; a "taken by" / "can't be used" line joins it, secondary |
| L-5 | Clear, Reset, Restore Defaults | Push buttons, 6pt apart. Row order Reset (while overridden), chip, Clear, so chip and Clear keep their columns. Restore Defaults below the last group, right-aligned, description beside it |
| L-6 | No match | "No shortcuts match your search." centered in a card; Restore Defaults still below |

## Implementation notes

- **Key monitor**: macOS offers the menu its key equivalents before any view sees the key. A
  local key monitor (`KeyboardSettingsKeys`) on the page's own window, installed while the page
  is in the window, gets the keys first, acting only while a chip records or the search field
  edits. The menu keeps its chords. The monitor leaves with the page (another tab, window
  closed), so it can't outlive the window. Visible effect: R-14.
- **Characters, not physical keys**: a chord is the characters its keys make, as AppKit menus
  match them: ⇧⌘1 records as ⌘!, query text "cmd+!".

## Checking the look

No `Visual/` scenario. With `TEST_RUNNER_TABS_SNAPSHOT_DIR` set (xcodebuild passes it as
`TABS_SNAPSHOT_DIR`), `UITests.KeyboardSettings` writes `settings-keyboard.png` (at rest),
`-recording`, `-refused`, `-taken`, `-empty` there, to read by eye.

## Notes

- Clear Buffer and Refresh are plugin commands, listed under Terminal and Git tree and acting on
  their own pane type ([TERMINAL.md](TERMINAL.md) T-125, [GIT-TREE.md](GIT-TREE.md) K-1).
