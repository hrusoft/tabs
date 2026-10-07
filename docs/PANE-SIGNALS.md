# Pane signals

A cue asking for the user's eye without taking focus: an icon before the pane's title, its
content outlined in the kind's color and pulsing, optionally the icon on every tab holding the
pane. One mechanism any plugin can declare kinds for; core declares **controlled**, the terminal
the **bell**. Code: `Sources/TabsCore/Panes/PaneSignals.swift` (who carries what) and
`Sources/Tabs/Workspace/Signals.swift` (the look).

## Scope

- Mechanism only: plugins declare kinds (`PaneSignalContribution`, point `tabs.paneSignals`,
  namespaced ids). The bell is the terminal plugin's `terminal.bell` ([TERMINAL.md](TERMINAL.md)).
- Core declares one kind, `controlled` (`ControlledSignal`), raised while the ownership ledger
  (`PaneOwnership`, [BROWSER.md](BROWSER.md) H-2…H-6) has an owner for the pane. Core's because
  ownership is, and the cue must look the same whichever plugin's pane it is.
- A plugin raises and withdraws only its own kinds, only on its own panes; another plugin's,
  core's or an undeclared kind is refused and logged
  (`PaneSignalsTests/aPluginRaisesAndWithdrawsOnlyItsOwnKinds`). Core's package API may put any
  kind on any pane.
- One switch per kind: Settings ▸ Panes & Tabs ▸ Indicators, with the kind's title and detail.
- Signals follow their pane across windows, `.untilSeen` ones too (S-15).
- Tests and `Visual/` use a core-declared stand-in `bell` (`Sources/Tabs/Testing/SignalFixtures.swift`,
  Debug) with the terminal bell's parameters and glyph; its switch's detail reads "…when a pane
  signals for attention."

## The API

```swift
// activate: declare a kind
context.register(PaneSignalContribution(
    id: "terminal.bell", label: "Bell", icon: .image(TerminalGlyphs.bell), color: .alert,
    pulse: 3, marksTabs: true, lifetime: .untilSeen, requestsAttention: true,
    setting: .init(title: "Bell indicator", detail: "…")))

// on one of your panes (PaneContext)
pane.raise(TerminalSignals.bell.signal)     // contribution.signal == PaneSignal("terminal.bell")
pane.withdraw(PaneSignal("terminal.bell"))  // nothing if not carried
```

| Field | Default | `terminal.bell` | `controlled` |
|---|---|---|---|
| `label` (accessibility) | — | "Bell" | "Controlled by another pane" |
| `icon`: `.symbol(name)` or template `.image` (alpha only; 16×16 box, 1.2 stroke, round caps) | — | bell glyph (L-3) | robot glyph (L-4) |
| `color`: `.alert` (`bellAlert`), `.agent` (`agent`), `.accent`, `.custom(dark:light:)` | — | `.alert` | `.agent` |
| `pulse` (seconds; nil = steady) | 3 | 3 | 4.5 |
| `marksTabs` | false | true | false |
| `lifetime`: `.untilSeen` (gone once looked at), `.untilWithdrawn` | — | `.untilSeen` | `.untilWithdrawn` |
| `requestsAttention` (Dock bounce) | false | true | false |
| `tooltip` (system tool tip on the icon) | nil | nil | "Controlled by another pane" |
| `setting` (title, detail) | — | "Bell indicator" | "Control indicator" |

- **Declaration checks** (`CoreExtensionPoints.problem(with:)`; the plugin fails to load):
  non-blank label; the SF Symbol exists; pulse > 0 and finite; non-blank setting title; tooltip
  nil or non-blank; id in the plugin's namespace. `PaneSignalsTests/aKindsDeclarationIsChecked`.
- **Kind order** = icon order, left to right; the outline is the last shown kind's: plugins in UI
  order, each in registration order, then core's (`PaneSignals.declare`: tests and `Visual/`
  only), `controlled` always last.
  `PaneSignalsTests/kindsArePluginsInUIOrderEachInRegistrationOrderThenCores`.
- A pane may raise inside `makePane`: kept through placement (an `.untilSeen` one is seen as the
  new pane takes focus). `PaneSignalsTests/aPaneMayRaiseFromInsideMakePane`.
- What changes during a layout pass is drawn by that pass (its render, or once it's done), never
  over the previous layout's views. `PaneSignalsTests/aPassDrawsTheSignalsItClearsWithTheViewsItBuilds`,
  `aSignalRaisedAfterAPassRendersIsToldOnceThePassIsDone`.

## Sources

| File | What |
|---|---|
| SDK `Sources/TabsPluginSDK/Signals.swift`; `PaneContext.raise`/`withdraw` (`Contributions/ContentType.swift`) | Kinds; raising from a pane |
| `Sources/TabsCore/Panes/PaneSignals.swift` | Who carries what; raise gates (setting, looked-at, Dock); withdraw; seen; end with the pane; kind order; tab marks |
| `…/Panes/ControlledSignal.swift`, `PaneRuntime.swift`; `…/Control/PaneOwnership.swift` | The `controlled` kind and robot glyph; raised on grant / attach, withdrawn with the pane |
| `…/Extensions/CoreExtensionPoints.swift` | The `tabs.paneSignals` point; declaration checks |
| `…/Layout/LayoutEngine.swift` (`PaneSignalHost`) | When a signal is seen; panes leaving the layout end theirs; "looked at" and "focused" |
| `Sources/Tabs/Workspace/Signals.swift` (`SignalStyle`, `SignalPulse`, `SignalIconView`, `SignalOutlineView`); `PaneViews.swift` (header), `TabStrip.swift` (tabs), `TreeViews.swift` (outlines) | Icons, outline + glow, pulse, tool tips |
| `…/Workspace/WorkspaceRenderer.swift` (`requestUserAttention`, `isFocused`), `WorkspaceWindowController.swift` (key), `App/AppShell.swift` (app active) | Dock bounce; window focus |
| `Sources/Tabs/UI/PaneSettingsPage.swift`; `SettingsStore` (`core.panes.disabledSignals`) | The switches |
| `Plugins/Terminal/Sources/TerminalPlugin.swift` (`TerminalSignals.bell`), `TerminalPane.swift` (`surfaceBell`) | The real bell, raised on BEL |
| `Sources/Tabs/Testing/SignalFixtures.swift` (Debug) | Stand-in `bell` |

## Cases

"Active" = exactly the window's `activePaneId` (may be a tab group). "Focused" = key window of
the active app (`NSApp.isActive && isKeyWindow`). "Looked at" = active and focused.

### Raising a bell

| Id | Case | Test |
|---|---|---|
| S-1 | Bell in a pane that isn't its window's active pane → flagged: icon before the header title, content outlined in the bell color with inner glow, pulsing | `PaneSignalsTests/aBellOnAPaneThatIsntActiveFlagsIt`, `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle`, `UITests.Signals/theOutlineCoversThePanesContentInItsKindsColor` |
| S-2 | Bell in the active pane of a focused window → dropped: nothing shown, nothing kept | `PaneSignalsTests/aBellInTheActivePaneOfAFocusedWindowIsDropped`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-3 | Bell in the active pane of an unfocused window → flagged | `PaneSignalsTests/aBellInTheActivePaneOfAnUnfocusedWindowFlagsIt`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-4 | A tab group being active doesn't count as looking at its leaves: a bell inside flags (exact id compare) | `PaneSignalsTests/aTabGroupBeingActiveIsntLookingAtItsPanes` |
| S-5 | Second bell in a flagged pane changes nothing (Dock aside, S-20) | `PaneSignalsTests/raisingAgainChangesNothing` |
| S-6 | Indicator off → bell dropped outright: not kept, no Dock bounce | `PaneSignalsTests/aSwitchedOffBellIsDroppedWithoutBouncing` |
| S-7 | Indicator off hides every flag at once; back on shows those still kept | `PaneSignalsTests/switchingOffHidesWhatsUpAndSwitchingOnShowsItAgain`, `PaneSignalsTests/flippingASwitchRedrawsThePanesCarryingThatKind`, `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt` |
| S-8 | A flag lasts until seen, however long (no timer) | `PaneSignalsTests/aFlagLastsUntilSeen` |

### Seeing a bell (it clears)

| Id | Case | Test |
|---|---|---|
| S-9 | Pane becomes its window's active pane (click, tab switch landing on it, keyboard nav, plugin focusing it), even in an unfocused window → clears | `PaneSignalsTests/becomingTheActivePaneClearsItEvenInAnUnfocusedWindow`, `UITests.Signals/clickingASignalledPaneClearsItsBellButNotItsStatus` |
| S-10 | Window gains focus while the flagged pane is its active pane → clears | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-11 | Window gains focus: flagged panes that aren't active stay flagged | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-12 | Clicking a background tab whose entry pane is flagged shows it and activates that pane: tab and header flags clear | `PaneSignalsTests/showingABackgroundTabWhoseEntryPaneRingsClearsIt`, `UITests.Signals/clickingItsTabClearsABackgroundPanesBell` |
| S-13 | Tab switch activating another pane of that tab: the flagged one stays flagged, its tab keeps the icon | `PaneSignalsTests/aTabSwitchLandingOnAnotherPaneKeepsTheFlag` |
| S-14 | Pane closes → its signals end | `PaneSignalsTests/closingAPaneEndsItsSignals`, `UITests.ControlledPanes/closingTheOwnedPaneEndsItsCue` |
| S-15 | Pane moves to another window → its flag follows it | `PaneSignalsTests/aSignalFollowsItsPaneIntoAnotherWindow` |
| S-16 | Pane moves within its window (split, dock, unpin, pin, reorder) → flag stays, unless the pane becomes active | `PaneSignalsTests/movingInsideTheWindowKeepsItUnlessThePaneBecomesActive` |

### Where a bell shows

| Id | Case | Test |
|---|---|---|
| S-17 | Pane header: right after the grip, before the title | `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle` |
| S-18 | Every tab whose content holds the flagged pane, at every depth, active tab included: icon before the tab's title (one per kind; pulse from the earliest raise) | `PaneSignalsTests/tabsMarkTheirPanesSignalsAtEveryDepthButNotStatuses`, `PaneSignalsTests/aTabsMarkRunsFromTheEarliestRaise`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows` |
| S-19 | Flagged pane in a background tab: its tabs show the icon though the pane isn't on screen | `PaneSignalsTests/showingABackgroundTabWhoseEntryPaneRingsClearsIt`, `UITests.Signals/clickingItsTabClearsABackgroundPanesBell` |
| S-20 | Dock bounces once (informational) per bell while the pane's window isn't focused and the indicator is on — repeats on a flagged pane too; never while focused (macOS ignores it while the app is active). Tests count requests; the bounce itself isn't seen | `PaneSignalsTests/aKindAskingForAttentionBouncesTheDockEveryTimeWhileUnfocused`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |

### Controlled panes

| Id | Case | Test |
|---|---|---|
| S-21 | A pane another pane owns → robot before the header title, outline in the agent color, slow pulse (4.5s) | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab`, `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab` |
| S-22 | Never on a tab, not even a background one: a kind that doesn't mark tabs shows nothing while its pane is in a background tab | `PaneSignalsTests/tabsMarkTheirPanesSignalsAtEveryDepthButNotStatuses`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows` |
| S-23 | Activation, focus, being looked at never clear it | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `UITests.Signals/clickingASignalledPaneClearsItsBellButNotItsStatus` |
| S-24 | Ownership released → cue goes | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `ControlPlaneTests/closingThePaneWithdrawsItWhoeverClosesIt` |
| S-25 | Indicator off hides it; state kept, so back on shows every pane owned now | `PaneSignalsTests/aStatusRaisedWhileSwitchedOffIsKeptHidden` |
| S-26 | Follows its pane into another window | `PaneSignalsTests/aSignalFollowsItsPaneIntoAnotherWindow` |
| S-27 | Hovering the robot shows the system tool tip "Controlled by another pane"; the bell has none. Tool tip rects on header and tab icons (`SignalIconRow.installTooltips`) | — (tool tips need a shown window and a real pointer) |
| S-28 | Raised when a pane is created through tabs-ctl from inside another pane (`create-browser-pane`), from the instant its plugin builds it; withdrawn by `close-pane`. A pane the user closes by hand leaves the ledger with it (its owner is then told it's gone) | `ControlPlaneTests/aPaneIsOwnedFromTheInstantItsPluginBuildsIt`, `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab`, `ControlPlaneTests/closingThePaneWithdrawsItWhoeverClosesIt` |

### Several cues

| Id | Case | Test |
|---|---|---|
| S-29 | Pane both flagged and controlled: bell, then robot; outline takes the controlled color and pulse (the last kind's) | `PaneSignalsTests/severalSignalsShowInKindOrderAndTheLastOutlines`, `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle` |
| S-30 | A cue on the active pane replaces its accent outline (pulsing) | `UITests.Signals/aCueOnTheActivePaneReplacesItsAccentOutline` |
| S-31 | A cue's icons and outline breathe together; separate cues and panes keep their own time (from the raise) | `UITests.Signals/aPulsingIconAnimatesFromItsRaiseAndASteadyOneDoesnt`, `UITests.Signals/thePulseFollowsItsKeyframes` |
| S-32 | Dragged pane dims to 40% with its cues; a dock preview over a cued pane covers its cue | `UITests.Signals/aDraggedPanesOutlineDimsWithIt`, `UITests.Signals/theDockPreviewCoversASignalledPanesOutline` |
| S-33 | An inactive, dimmed pane's cue isn't dimmed (the dim applies to the content only) | — (`Visual/` `signal-header` pixels: its signalled pane is dimmed) |
| S-34 | A cue at the window's bottom corner follows the corner radius, as the active outline does | — (shares the active outline's radii) |
| S-35 | Any number of panes carry cues at once, each with its own outline | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |

### Settings (Settings ▸ Panes & Tabs, live)

| Id | Case | Test |
|---|---|---|
| S-36 | One switch per kind, default on, in the Indicators section (the page's last), with the kind's title and detail; stored sparse in `core.panes.disabledSignals`; id `settings-signal-<kind>-checkbox`; a disabled plugin's kinds leave the page. The terminal's: **Bell indicator**, "Pulse a bell icon and bounce the Dock icon when a terminal rings its bell." | `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `UITests.Signals/aDisabledPluginsKindsLeaveTheSettingsPage`, `PaneSignalsTests/aDisabledPluginsKindsHaveNoSwitch`, `PaneSignalsTests/theSwitchesPersistAndABadValueFallsBackAlone`, `TerminalPluginTests/theBellIsAPulsingAlertSignalUntilSeen` |
| S-37 | **Control indicator** (core's `controlled`), after every plugin's: "Pulse a robot icon and highlight a pane's own border while another pane is controlling it." | `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `PaneSignalsTests/aStatusRaisedWhileSwitchedOffIsKeptHidden` |

### Accessibility and ids

| Id | Case | Test |
|---|---|---|
| S-38 | Each icon is an image labelled "Bell" / "Controlled by another pane"; clicks pass to the chrome under it. Ids `pane-signal-<kind>`, `tab-signal-<kind>` | `UITests.Signals/anIconIsAnImageLabelledForAccessibility`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab` |

## Look

Lengths in pt; colors dark / light (`PaneTheme`).

| Id | Element | Box | Colors dark / light | States | Scenario |
|---|---|---|---|---|---|
| L-1 | Header icon | 16×16 in the header's row, 8 gaps: grip, bell, robot, title. Centered in the 24 bar (4 from its top). Title moves right 24 per icon | cue color | pulsing (L-7), dragging (40%) | `signal-header` |
| L-2 | Tab icon | 16×16 before the title; the tab's left padding 10 → 2, 2 gap to the title; centered in the tab's 21 content box (2.5 below its top). Tab grows 10, still at most 220 (title truncates sooner) | cue color, on the tab's own surface | pulsing, hover, dragging | `signal-tabs` |
| L-3 | Bell glyph | 16-unit box: body `M8 2.5c-2 0-3 1.6-3 4v1.3c0 .9-.3 1.7-.9 2.4l-.6.7h9l-.6-.7c-.6-.7-.9-1.5-.9-2.4V6.5c0-2.4-1-4-3-4z`, clapper `M6.5 12.3a1.5 1.5 0 0 0 3 0`; stroke 1.2, round caps and joins, no fill | `bellAlert` #ff453a / #d70015 | | `signal-header` |
| L-4 | Robot glyph | antenna dot ⌀2 at (8, 1), filled; stem (8, 2)→(8, 3.5) stroke 1.2 round; head rect (2.5, 3.5) 11×9 r2 stroke 1.2; eyes ⌀2.2 at (5.7, 8) and (10.3, 8), filled; mouth (5.5, 10.8)→(10.5, 10.8) stroke 1.2 round | `agent` #b48cff / #7b45d8 | | `signal-controlled` |
| L-5 | Outline | the active outline's box: the content area (below the chrome bar), 1 past it left, right and bottom; 1 border in the cue color; bottom corners follow the window radius | cue color | pulsing, dragging | `signal-header` |
| L-6 | Glow | inner shadow from the outline's inner edge inward, blur 14, the cue color at 55% | cue at 55% | pulsing | `signal-header` |
| L-7 | Pulse | opacity 0.3 from 0% to 30%, ease-in-out up to 1 at 56%, ease-in-out down to 0.3 at 69%, 0.3 to 100%; infinite; bell 3s, controlled 4.5s; icons and outline (with glow) alike | — | peak (1), trough (0.3) | `signal-trough`, `signal-rise` |
| L-8 | Both cues | bell then robot in the header; outline in the controlled color | | | `signal-both` |

## Implementation notes

- **Pulse**: a Core Animation keyframe animation (`SignalPulse`, L-7's curve) on the icons' and
  outline's layers, `beginTime` = the raise, so one signal's views breathe together whenever
  they're built, and a view rebuilt after a move keeps its phase.
- **Tool tips**: AppKit tool tip rects over the icons (header and tab), for kinds with a
  `tooltip` (S-27).
- **Dock bounce**: `NSApp.requestUserAttention(.informationalRequest)`, only when windows are
  presented; tests read `attentionRequests` (S-20).
- **Focus**: "focused" is the key window of the active app, followed through
  `windowDidBecomeKey` and the app's `didBecomeActive`.

## Checking the look

Scenarios `Visual/scenarios/signal-*.json` (method: [LAYOUT.md](LAYOUT.md), Checking the look).
`signals`: `{"<pane id>": ["bell" | "controlled"]}` (the stand-in bell and core's `controlled`);
`pulse`: every pulse frozen that many seconds in (without it: the peak, opacity 1). The geometry
adds `signalIcons` (per header and tab) and `cue` (the kind outlining a pane), only where present.

| Scenario | Shows |
|---|---|
| `signal-header` | bell on an inactive pane: header icon, outline + glow; the root tab holding it |
| `signal-controlled` | controlled pane: robot, agent outline, no tab icon |
| `signal-both` | both on one pane: bell then robot, controlled outline |
| `signal-active` | bell on the active pane (window unfocused): replaces the accent outline |
| `signal-tabs` | tab icons at two depths, a background root tab (truncated title), the active root tab holding a nested background tab's bell; a controlled pane at depth 2 |
| `signal-light` | light theme: a bell, and a controlled active pane |
| `signal-trough` | pulse low point (0.3) |
| `signal-rise` | 1.3s in: bells mid-rise (0.665), robot and outline still low |
| `signal-off` | both switches off: nothing shows (same as `split-horizontal`) |
| `signal-floating` | bell in a floating pane |

## Notes

- Never seen in a shown window by the tests: the live pulse, the Dock bounce, tool tips (captures
  render frozen layers; tests never show windows).
