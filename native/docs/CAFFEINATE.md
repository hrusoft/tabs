# Caffeinate

Keeps the Mac awake: File ▸ Caffeinate… picks `caffeinate(8)` assertions and an optional
timer, then runs one managed `/usr/bin/caffeinate` for the whole app. While it runs, File ▸
Decaf and a cup on every window's title bar stop it. Port of Electron's; the dialog is a
native window (see Known differences).

## Sources

| Native | Electron | What |
|---|---|---|
| `Sources/TabsCore/Caffeinate/Caffeinate.swift` | `src/main/caffeinateArgs.ts`, `caffeinateProcess.ts`, `caffeinate.ts`; `src/shared/api.ts` (`CaffeinateFlags`) | `CaffeinateFlags`, `argsFor`, the managed process and its running state. Core (app-wide, no pane). Owned by `CoreRuntime`, so a test reset kills it |
| `CoreCommands.caffeinate` | `packages/plugin-sdk/shared/shortcuts.ts` (`caffeinate`) | Rebindable command, no default chord |
| `Sources/Tabs/UI/MainMenu.swift` (`CommandRouter.caffeinate`) | `src/main/menu.ts` (`caffeinateMenuItem`) | File ▸ Caffeinate… / Decaf |
| `Sources/Tabs/Workspace/PaneViews.swift` (`TabBarView.caffeinateButton`, `RootIconButton`), `Chrome.swift` (`ChromeIcon.coffeeCup`) | `TabBar.tsx` (`CaffeinateButton`), `content/icons.tsx` (`CoffeeCupIcon`), `global.css` (`.tab-bar-icon-button`), `caffeinate/caffeinateStore.ts` | Title-bar cup |
| `Sources/Tabs/Caffeinate/CaffeinateWindow.swift` | `caffeinate/CaffeinateDialog.tsx`, `installCaffeinate.ts`, `core/modal.ts`, `Modal.tsx` | The dialog |
| `Sources/Tabs/Testing/TestControlVerbs.swift` (`tabs.test.caffeinate`, `tabs.test.caffeinateDialog`) | `src/main/e2e.ts` (`caffeinatePid`, `startCaffeinateForTests`) | Debug-only e2e hooks |

## Cases

### The process (core)

| Id | Case | Electron | Native test |
|---|---|---|---|
| P-1 | All flags off → argv is only `-w <pid>` | `caffeinateArgs.ts:argsFor` | `CaffeinateTests/everyFlagOffProducesOnlyTheMandatoryW` |
| P-2 | Each flag → its switch, before `-w`: display `-d`, idle `-i`, disk `-m`, system `-s`, user active `-u` | ″ | `CaffeinateTests/eachBooleanFlagMapsToItsOwnSwitchAheadOfW` |
| P-3 | Order: `-d -i -m -s -u`, then `-w` | ″ | `CaffeinateTests/flagsCombineInTheOrderTheDialogListsThem` |
| P-4 | Positive whole timer → `-t <seconds>`, after the flags, before `-w` | ″ | `CaffeinateTests/aPositiveIntegerTimerBecomesT` |
| P-5 | No timer → no `-t` (runs until Decaf) | ″ | `CaffeinateTests/anAbsentTimerOmitsT` |
| P-6 | Timer 0, negative or fractional = none | ″ | `CaffeinateTests/aNonPositiveOrNonIntegerTimerIsTreatedAsAbsent` |
| P-7 | `-w` carries the watched pid verbatim | ″ | `CaffeinateTests/wAlwaysCarriesTheWatchedPid` |
| P-8 | Start spawns `/usr/bin/caffeinate` with `argsFor(flags, <app pid>)`, stdio to null; running → true, observers notified | `caffeinate.ts:startCaffeinate` | `CaffeinateTests/startRunsTheRealProcessWithTheFlags`, `CaffeinateEndToEndTests/theMenuOpensTheDialogAndStartLaunchesTheRealProcess` |
| P-9 | Start while running: no-op | `startCaffeinate` | `CaffeinateTests/startWhileRunningIsANoOp` |
| P-10 | Stop sends SIGTERM; "not running" announced only after the real exit | `caffeinateProcess.ts:stopCaffeinate` | `CaffeinateTests/stopEndsTheProcessAndItsExitIsAnnounced`, `CaffeinateEndToEndTests/decafFromTheMenuStopsTheRealProcess` |
| P-11 | Process exits on its own (timer, external kill) → running false, menu and cup revert | `startCaffeinate` `exit` handler | `CaffeinateTests/aProcessEndingOnItsOwnIsNoticed`, `CaffeinateEndToEndTests/aTimerEndingTheProcessRevertsBothSurfaces` |
| P-12 | Late exit of a superseded or forgotten process changes nothing | `onExit` (`caffeinateProcess() !== child`) | `CaffeinateTests/aLateExitOfAnOldProcessChangesNothing` |
| P-13 | Failed spawn → not running | `child.on('error', onExit)` | `CaffeinateTests/aSpawnThatFailsLeavesItNotRunning` |
| P-14 | Quit kills synchronously and forgets the process first, so its exit is a no-op (`killNow`) | `index.ts` before-quit → `killCaffeinateSync` | `CaffeinateTests/killNowForgetsTheProcessAtOnce`, `CaffeinateRelaunchTests/quittingStopsTheRealProcess` |
| P-15 | App SIGKILLed → caffeinate ends through `-w`, not the quit path | `argsFor` `-w` | `CaffeinateRelaunchTests/aKilledAppStillEndsTheProcessThroughW` |
| P-16 | Test reset kills a leftover process | `e2e.ts` → `resetCaffeinateForTests` | `CaffeinateEndToEndTests/aResetStopsTheProcess` |
| P-17 | State is app-wide: every window's cup and the one menu item read it | `broadcastRunning` | `UITests.Caffeinate/theCupShowsOnEveryWindowsRootBar` |

### The menu

| Id | Case | Electron | Native test |
|---|---|---|---|
| M-1 | File ends with a separator, then Caffeinate… (after Close Pane) | `menu.ts` File submenu | `UITests.Caffeinate/theFileMenuEndsWithCaffeinate` |
| M-2 | While running the item reads Decaf; relabels live on start, stop and the process's own exit | `caffeinateMenuItem`, `broadcastRunning` → `applyMenu` | `UITests.Caffeinate/theItemReadsDecafWhileRunning`, `CaffeinateEndToEndTests/decafFromTheMenuStopsTheRealProcess` |
| M-3 | Caffeinate… opens the dialog, starts nothing | `caffeinateMenuItem` | `UITests.Caffeinate/theMenuOpensTheDialogAndStartsNothing`, `CaffeinateEndToEndTests/theMenuOpensTheDialogAndStartLaunchesTheRealProcess` |
| M-4 | Decaf stops the process directly, no dialog | `caffeinateMenuItem` | `UITests.Caffeinate/theItemReadsDecafWhileRunning`, `CaffeinateEndToEndTests/decafFromTheMenuStopsTheRealProcess` |
| M-5 | Rebindable: Settings ▸ Keyboard lists "Caffeinate…" last in Application, summary "Open the Caffeinate dialog to keep the Mac awake, or turn it off if already running.", no default chord. A user chord runs whichever label the item has | `shortcuts.ts` `caffeinate` | `UITests.Caffeinate/itIsARebindableCommandWithNoDefaultChord`, `ShortcutsTests` |
| M-6 | Works whichever window is key (workspace, Settings, About) or with none open. **Deviation:** no workspace window is chosen or reopened to host the dialog | `caffeinateMenuItem` target-window rule | `UITests.Caffeinate/theMenuWorksWithNoWorkspaceWindow` |

### The cup button

| Id | Case | Electron | Native test |
|---|---|---|---|
| B-1 | Only while running, on the docked root's bar, immediately before Settings | `TabBar.tsx` (`isRoot && caffeinateRunning`) | `UITests.Caffeinate/theCupAppearsBeforeSettingsOnlyWhileRunning` |
| B-2 | Click = Decaf; disappears once the exit is noticed | `CaffeinateButton` → `caffeinate.stop()` | `UITests.Caffeinate/clickingTheCupStops`, `CaffeinateEndToEndTests/theCupStopsTheRealProcess` |
| B-3 | Tooltip and accessibility label "Decaf"; id `caffeinate-decaf-button` | `HeaderButton label="Decaf"` | `UITests.Caffeinate/theCupIsNamedDecaf` |
| B-4 | Never on nested or floating groups' bars | `isRoot` | `UITests.Caffeinate/theCupIsOnlyOnTheDockedRootsBar` |
| B-5 | A window opened while running shows the cup from its first draw | `caffeinateStore` (`isRunningSync()`) | `UITests.Caffeinate/theCupShowsOnEveryWindowsRootBar` |
| B-6 | Press neither drags the window nor activates panes (carved out of the title-bar drag region) | `.tab-bar-icon-button { -webkit-app-region: no-drag }` | `UITests.Caffeinate/pressingTheCupDoesNotDragTheWindow` |

### The dialog

| Id | Case | Electron | Native test |
|---|---|---|---|
| D-1 | Title "Caffeinate" (no ellipsis) | `openCaffeinateDialog` | `UITests.CaffeinateDialog/itIsTitledCaffeinate` |
| D-2 | Five switches, in order, with hints: Prevent display sleep · Prevent idle system sleep · Prevent disk idle sleep · Prevent system sleep ("Only applies on AC power.") · Declare the user active ("Wakes the display; lasts 5 seconds unless a timer is also set below.") | `CaffeinateForm` | `UITests.CaffeinateDialog/itListsTheFiveAssertionsInOrderWithTheirHints` |
| D-3 | Defaults: idle and system sleep on; display, disk, user active off (`CaffeinateFlags.dialogDefaults`) | `DEFAULT_FLAGS` | `UITests.CaffeinateDialog/theDefaultsKeepTheMacRunningButLetTheDisplaySleep`, `CaffeinateTests/theDialogsDefaultsKeepTheMacRunningButLetTheDisplaySleep` |
| D-4 | "Stop after" row, hint "Leave empty to run until Decaf.", minutes field + "minutes" | `CaffeinateForm` | `UITests.CaffeinateDialog/itListsTheFiveAssertionsInOrderWithTheirHints` |
| D-5 | Start: starts with the switches as set (+ `timerSeconds` = minutes × 60 if given), closes | `handleStart` → `caffeinate.start` | `UITests.CaffeinateDialog/startSendsTheToggledFlagsAndCloses`, `CaffeinateEndToEndTests/aTimerTypedIntoTheDialogReachesTheRealProcessAsT` |
| D-6 | Empty timer → no `timerSeconds` | `parseTimerMinutes` | `UITests.CaffeinateDialog/anEmptyTimerRunsUntilDecaf` |
| D-7 | Timer text trimmed; only a positive whole number of minutes counts, anything else = no timer | `parseTimerMinutes` | `UITests.CaffeinateDialog/timerTextParsesAsElectronParsesIt` |
| D-8 | Cancel, Escape, close button: dismiss, start nothing | `openModal` `dismissValue: null`, `Modal.tsx` | `UITests.CaffeinateDialog/cancelEscapeAndCloseStartNothing` |
| D-9 | One at a time: asking again brings the open one forward, typed values kept | `openModal` refuses a second modal | `UITests.CaffeinateDialog/askingAgainKeepsTheOpenDialogAndWhatWasTyped` |
| D-10 | Each new dialog starts from the defaults | `useState(DEFAULT_FLAGS)`, mounted per open | `UITests.CaffeinateDialog/eachNewDialogStartsFromTheDefaults` |
| D-11 | Tab cycles within the dialog | `Modal.tsx` focus trap | — (AppKit key view loop) |
| D-12 | Return presses Start. **Deviation:** native default button (Electron: Enter only activates a focused button) | — | `UITests.CaffeinateDialog/returnPressesStart` |
| D-13 | Start while already running changes nothing (unreachable from the menu) | `startCaffeinate` no-op | `CaffeinateTests/startWhileRunningIsANoOp` |
| D-14 | Test reset closes an open dialog | — (Electron reloads renderers) | `CaffeinateEndToEndTests/aResetStopsTheProcess` |
| D-15 | Own standard window: fixed size, not resizable/zoomable, centered; never shown or focused in hidden mode | — | `CaffeinateEndToEndTests/theDialogIsAWindowOfItsOwn`, `UITests.CaffeinateDialog/itIsTitledCaffeinate` |

## Look

### The cup button (measured against Electron)

| Id | Element | Box | Colors dark / light | States | Scenario |
|---|---|---|---|---|---|
| L-1 | Button | `.pane-header-button` + `.tab-bar-icon-button`: 15×15 icon + 4px padding = 23×23, radius 3px. `margin-right: 6px` + the bar's 8px gap → right edge 14px left of Settings (same 6px margin, then the bar's 4px right padding). Vertically centered | glyph `--text-dim`; hover: glyph `--text`, bg `rgb(--hover-rgb / 0.12)` | rest, hover (+ "Decaf" tooltip) | `caffeinate-running`, `caffeinate-light`, `caffeinate-hover` |
| L-2 | Icon | 16-unit viewBox at 15px. Cup `M3.5 7H10.5V11.5A2 2 0 0 1 8.5 13.5H5.5A2 2 0 0 1 3.5 11.5Z`, stroke 1.2, round joins. Handle `M10.5 8.2C12.1 8.2 13.1 9.1 13.1 10.3S12.1 12.4 10.5 12.4`, stroke 1.2, round caps. Steam at x = 4.5, 7.5, 10.5: `M x 6 c0-1 .9-1 .9-2 s-.9-1-.9-2`, stroke 1, round caps | currentColor | — | ″ |
| L-3 | Placement | Root bar only; same right-aligned slot in fullscreen | — | fullscreen | `caffeinate-fullscreen`, `caffeinate-floating` |

### The dialog (native, not compared)

Standard titled window, 440pt wide, like Settings: grouped `Form`; one section with the five
switches (title + hint per row), one with "Stop after" (field 56pt wide, as
`.caffeinate-timer-input input`) + "minutes"; Cancel and Start (default) bottom right, 8pt
apart (`.modal-actions`). System fonts and colors; follows the app's theme like Settings.

## Electron quirks kept for parity

- Timer not a positive whole number of minutes (`1.5`, `0`) silently means none: runs until
  Decaf (`CaffeinateDialog.tsx:parseTimerMinutes`).
- `-u` without a timer holds the user-active assertion only caffeinate's 5 s, but the process
  (and the cup) stay until Decaf. The hint says so.
- No default chord. A bound chord toggles: opens the dialog, or stops the process.

## Can't be ported as-is

- **Modal inside the pane-tree window** (backdrop, `openModal`, menu forwarding
  `caffeinate:open-dialog` to a renderer): the dialog is its own window, so Electron's
  target-window rule (menu's window, else newest, else reopen the last closed) has no
  counterpart.
- **IPC and sync initial state** (`isRunningSync`, `onRunningChanged`): the shell reads and
  observes core's `Caffeinate` directly.

## Checking the look

Scenarios `Visual/scenarios/caffeinate-*.json` set `"caffeinate": true` (Electron: fake
bridge `emitCaffeinateRunningChanged(true)`; native: `appearance.caffeinateRunning`).
Geometry: `tabBars.<id>.caffeinate` (cup rect; key omitted when not running) beside
`settings`.

## Known differences

- **The dialog is a native window**, not a modal card in the workspace window: no per-window
  targeting, no reopening a closed window to host it (M-6); Return presses Start (D-12); the
  system's look (no scenario).
