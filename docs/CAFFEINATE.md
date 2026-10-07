# Caffeinate

Keeps the Mac awake: File ▸ Caffeinate… picks `caffeinate(8)` assertions and an optional
timer, then runs one managed `/usr/bin/caffeinate` for the whole app. While it runs, File ▸
Decaf and a cup on every window's title bar stop it. Code: `Sources/TabsCore/Caffeinate` (the
process) and `Sources/Tabs/Caffeinate` (the dialog, a window of its own).

## Sources

| File | What |
|---|---|
| `Sources/TabsCore/Caffeinate/Caffeinate.swift` | `CaffeinateFlags`, `argsFor`, the managed process and its running state. Core (app-wide, no pane). Owned by `CoreRuntime`, so a test reset kills it |
| `CoreCommands.caffeinate` | Rebindable command, no default chord |
| `Sources/Tabs/UI/MainMenu.swift` (`CommandRouter.caffeinate`) | File ▸ Caffeinate… / Decaf |
| `Sources/Tabs/Workspace/PaneViews.swift` (`TabBarView.caffeinateButton`, `RootIconButton`), `Chrome.swift` (`ChromeIcon.coffeeCup`) | Title-bar cup |
| `Sources/Tabs/Caffeinate/CaffeinateWindow.swift` | The dialog |
| `Sources/Tabs/Testing/TestControlVerbs.swift` (`tabs.test.caffeinate`, `tabs.test.caffeinateDialog`) | Debug-only e2e hooks |

## Cases

### The process (core)

| Id | Case | Test |
|---|---|---|
| P-1 | All flags off → argv is only `-w <pid>` | `CaffeinateTests/everyFlagOffProducesOnlyTheMandatoryW` |
| P-2 | Each flag → its switch, before `-w`: display `-d`, idle `-i`, disk `-m`, system `-s`, user active `-u` | `CaffeinateTests/eachBooleanFlagMapsToItsOwnSwitchAheadOfW` |
| P-3 | Order: `-d -i -m -s -u`, then `-w` | `CaffeinateTests/flagsCombineInTheOrderTheDialogListsThem` |
| P-4 | Positive whole timer → `-t <seconds>`, after the flags, before `-w` | `CaffeinateTests/aPositiveIntegerTimerBecomesT` |
| P-5 | No timer → no `-t` (runs until Decaf) | `CaffeinateTests/anAbsentTimerOmitsT` |
| P-6 | Timer 0, negative or fractional = none | `CaffeinateTests/aNonPositiveOrNonIntegerTimerIsTreatedAsAbsent` |
| P-7 | `-w` carries the watched pid verbatim | `CaffeinateTests/wAlwaysCarriesTheWatchedPid` |
| P-8 | Start spawns `/usr/bin/caffeinate` with `argsFor(flags, <app pid>)`, stdio to null; running → true, observers notified | `CaffeinateTests/startRunsTheRealProcessWithTheFlags` |
| P-9 | Start while running: no-op | `CaffeinateTests/startWhileRunningIsANoOp` |
| P-10 | Stop sends SIGTERM; "not running" announced only after the real exit | `CaffeinateTests/stopEndsTheProcessAndItsExitIsAnnounced` |
| P-11 | Process exits on its own (timer, external kill) → running false, menu and cup revert | `CaffeinateTests/aProcessEndingOnItsOwnIsNoticed` |
| P-12 | Late exit of a superseded or forgotten process changes nothing | `CaffeinateTests/aLateExitOfAnOldProcessChangesNothing` |
| P-13 | Failed spawn → not running | `CaffeinateTests/aSpawnThatFailsLeavesItNotRunning` |
| P-14 | Quit kills synchronously and forgets the process first, so its exit is a no-op (`killNow`) | `CaffeinateTests/killNowForgetsTheProcessAtOnce`, `RelaunchTests/quittingRemovesThisBootsSocketAndStopsCaffeinate` |
| P-15 | App SIGKILLed → caffeinate ends through `-w`, not the quit path | `RelaunchTests/aCrashLosesOnlyWhatWasNotYetSavedAndCaffeinateStillEnds` |
| P-16 | Test reset kills a leftover process | `CaffeinateEndToEndTests/aResetStopsTheProcess` |
| P-17 | State is app-wide: every window's cup and the one menu item read it | `UITests.Caffeinate/theCupShowsOnEveryWindowsRootBar` |

### The menu

| Id | Case | Test |
|---|---|---|
| M-1 | File ends with a separator, then Caffeinate… (after Close Pane) | `MenuTests/theFileMenuListsItsCommandsAndHasNoNewTabWith` |
| M-2 | While running the item reads Decaf; relabels live on start, stop and the process's own exit | `UITests.Caffeinate/theItemReadsDecafWhileRunning` |
| M-3 | Caffeinate… opens the dialog, starts nothing | `UITests.Caffeinate/theMenuOpensTheDialogAndStartsNothing` |
| M-4 | Decaf stops the process directly, no dialog | `UITests.Caffeinate/theItemReadsDecafWhileRunning` |
| M-5 | Rebindable: Settings ▸ Keyboard lists "Caffeinate…" last in Application, summary "Open the Caffeinate dialog to keep the Mac awake, or turn it off if already running.", no default chord. A user chord runs whichever label the item has: opens the dialog, or stops the process | `UITests.Caffeinate/itIsARebindableCommandWithNoDefaultChord`, `ShortcutsTests` |
| M-6 | Works whichever window is key (workspace, Settings, About) or with none open: the dialog is its own window, so no workspace window is chosen or reopened to host it | `UITests.Caffeinate/theMenuWorksWithNoWorkspaceWindow` |

### The cup button

| Id | Case | Test |
|---|---|---|
| B-1 | Only while running, on the docked root's bar, immediately before Settings | `UITests.Caffeinate/theCupAppearsBeforeSettingsOnlyWhileRunning` |
| B-2 | Click = Decaf; disappears once the exit is noticed | `UITests.Caffeinate/clickingTheCupStops` |
| B-3 | Tooltip and accessibility label "Decaf"; id `caffeinate-decaf-button` | `UITests.Caffeinate/theCupIsNamedDecaf` |
| B-4 | Never on nested or floating groups' bars | `UITests.Caffeinate/theCupIsOnlyOnTheDockedRootsBar` |
| B-5 | A window opened while running shows the cup from its first draw | `UITests.Caffeinate/theCupShowsOnEveryWindowsRootBar` |
| B-6 | Press neither drags the window nor activates panes (carved out of the title bar's drag area) | `UITests.Caffeinate/pressingTheCupDoesNotDragTheWindow` |

### The dialog

| Id | Case | Test |
|---|---|---|
| D-1 | Title "Caffeinate" (no ellipsis) | `UITests.CaffeinateDialog/itIsTitledCaffeinate` |
| D-2 | Five switches, in order, with hints: Prevent display sleep · Prevent idle system sleep · Prevent disk idle sleep · Prevent system sleep ("Only applies on AC power.") · Declare the user active ("Wakes the display; lasts 5 seconds unless a timer is also set below."). Without a timer, `-u` holds its assertion only caffeinate's 5 s, but the process (and the cup) stay until Decaf | `UITests.CaffeinateDialog/itListsTheFiveAssertionsInOrderWithTheirHints` |
| D-3 | Defaults: idle and system sleep on; display, disk, user active off (`CaffeinateFlags.dialogDefaults`) | `CaffeinateDialogModelTests/theDefaultsKeepTheMacRunningButLetTheDisplaySleep`, `CaffeinateTests/theDialogsDefaultsKeepTheMacRunningButLetTheDisplaySleep` |
| D-4 | "Stop after" row, hint "Leave empty to run until Decaf.", minutes field + "minutes" | `UITests.CaffeinateDialog/itListsTheFiveAssertionsInOrderWithTheirHints` |
| D-5 | Start: starts with the switches as set (+ `timerSeconds` = minutes × 60 if given), closes | `UITests.CaffeinateDialog/startSendsTheToggledFlagsAndCloses` |
| D-6 | Empty timer → no `timerSeconds` | `CaffeinateDialogModelTests/anEmptyTimerRunsUntilDecaf` |
| D-7 | Timer text trimmed; only a positive whole number of minutes counts, anything else (`1.5`, `0`) silently means none: runs until Decaf | `CaffeinateDialogModelTests/timerTextParsesAsAPositiveWholeNumberOfMinutes` |
| D-8 | Cancel, Escape, close button: dismiss, start nothing | `UITests.CaffeinateDialog/cancelEscapeAndCloseStartNothing` |
| D-9 | One at a time: asking again brings the open one forward, typed values kept | `UITests.CaffeinateDialog/askingAgainKeepsTheOpenDialogAndWhatWasTyped` |
| D-10 | Each new dialog starts from the defaults | `UITests.CaffeinateDialog/eachNewDialogStartsFromTheDefaults` |
| D-11 | Tab cycles within the dialog | — (AppKit key view loop) |
| D-12 | Return presses Start (the default button) | `UITests.CaffeinateDialog/returnPressesStart` |
| D-13 | Start while already running changes nothing (unreachable from the menu) | `CaffeinateTests/startWhileRunningIsANoOp` |
| D-14 | Test reset closes an open dialog | `CaffeinateEndToEndTests/aResetStopsTheProcess` |
| D-15 | Own standard window: fixed size, not resizable/zoomable, centered; never shown or focused in hidden mode | `EndToEndTests/hiddenModeShowsNoWindowNotEvenSettingsPluginsAboutOrCaffeinate`, `UITests.CaffeinateDialog/itIsTitledCaffeinate` |

## Look

### The cup button

Lengths in pt; colors dark / light (`PaneTheme`).

| Id | Element | Box | Colors dark / light | States | Scenario |
|---|---|---|---|---|---|
| L-1 | Button | 15×15 icon + 4 padding = 23×23, radius 3. Margin right 6 + the bar's 8 gap → right edge 14 left of Settings (Settings: the same 6 margin, then the bar's 4 right padding). Vertically centered | glyph `textDim`; hover: glyph `text`, fill `hover` at 12% | rest, hover | `caffeinate-running`, `caffeinate-light`, `caffeinate-hover` |
| L-2 | Icon | 16-unit box drawn at 15. Cup `M3.5 7H10.5V11.5A2 2 0 0 1 8.5 13.5H5.5A2 2 0 0 1 3.5 11.5Z`, stroke 1.2, round joins. Handle `M10.5 8.2C12.1 8.2 13.1 9.1 13.1 10.3S12.1 12.4 10.5 12.4`, stroke 1.2, round caps. Steam at x = 4.5, 7.5, 10.5: `M x 6 c0-1 .9-1 .9-2 s-.9-1-.9-2`, stroke 1, round caps | the button's glyph color | — | ″ |
| L-3 | Placement | Root bar only; same right-aligned slot in fullscreen | — | fullscreen | `caffeinate-fullscreen`, `caffeinate-floating` |

### The dialog

Standard titled window, 440pt wide, like Settings: grouped `Form`; one section with the five
switches (title + hint per row), one with "Stop after" (field 56pt wide) + "minutes"; Cancel and
Start (default) bottom right, 8pt apart. System fonts and colors; follows the app's theme like
Settings.

## Implementation notes

- **A window of its own**: the dialog belongs to no workspace window, so it needs none to host
  it (M-6) and has the system's look and keys (D-12, D-15).
- **State**: the shell reads and observes core's `Caffeinate` directly, so the menu item and
  every window's cup follow the process (P-17, B-5).

## Checking the look

Scenarios `Visual/scenarios/caffeinate-*.json` (method: [LAYOUT.md](LAYOUT.md), Checking the
look) set `"caffeinate": true` (the capture sets `appearance.caffeinateRunning`). Geometry:
`tabBars.<id>.caffeinate` (cup rect; key omitted when not running) beside `settings`.

The dialog has no scenario: `UITests.CaffeinateDialog/itListsTheFiveAssertionsInOrderWithTheirHints`
draws it and, with `TEST_RUNNER_TABS_SNAPSHOT_DIR` set (xcodebuild passes it as
`TABS_SNAPSHOT_DIR`), writes `caffeinate-dialog.png` there, to read by eye.
