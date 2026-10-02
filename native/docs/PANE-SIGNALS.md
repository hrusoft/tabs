# Pane signals

A cue asking for the user's eye without taking focus: an icon before the pane's title, its
content outlined in the kind's color and pulsing, optionally the icon on every tab holding the
pane. Port of Electron's two hard-wired cues (**bell**, **controlled**) as one mechanism any
plugin can declare kinds for.

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
  Debug) with Electron's bell parameters, text and glyph.

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

| Field | Default | Electron bell | Electron controlled |
|---|---|---|---|
| `label` (accessibility) | — | "Bell" | "Controlled by another pane" |
| `icon`: `.symbol(name)` or template `.image` (alpha only; 16×16 box, 1.2 stroke, round caps) | — | `BellIcon` | `RobotIcon` |
| `color`: `.alert` (`--bell-alert`), `.agent` (`--agent`), `.accent`, `.custom(dark:light:)` | — | `.alert` | `.agent` |
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
  only), `controlled` always last — Electron's CSS order (`.pane-controlled::after` after
  `.pane-alert::after`). `PaneSignalsTests/kindsArePluginsInUIOrderEachInRegistrationOrderThenCores`.
- A pane may raise inside `makePane`: kept through placement (an `.untilSeen` one is seen as the
  new pane takes focus). `PaneSignalsTests/aPaneMayRaiseFromInsideMakePane`.
- What changes during a layout pass is drawn by that pass (its render, or once it's done), never
  over the previous layout's views. `PaneSignalsTests/aPassDrawsTheSignalsItClearsWithTheViewsItBuilds`,
  `aSignalRaisedAfterAPassRendersIsToldOnceThePassIsDone`.

## Sources

Electron paths under `src/renderer/src/` unless rooted.

| Native | Electron | What |
|---|---|---|
| SDK `Sources/TabsPluginSDK/Signals.swift`; `PaneContext.raise`/`withdraw` (`Contributions/ContentType.swift`) | `packages/plugin-sdk/renderer/api.ts` (`ctx.bell`), `src/shared/api.ts` (`BellApi`) | Kinds; raising from a pane |
| `Sources/TabsCore/Panes/PaneSignals.swift` | `core/store/bellStore.ts`, `controlStore.ts`, `plugin/context.ts` (`bell.ring`) | Who carries what; raise gates (setting, looked-at, Dock); withdraw; seen; end with the pane; kind order; tab marks |
| `…/Panes/ControlledSignal.swift`, `PaneRuntime.swift`; `…/Control/PaneOwnership.swift` | `controlStore.ts`; `src/main/externalControl.ts` (`ownerOf`, `grantOwnership`, `releaseOwnership`) | The `controlled` kind and robot glyph; raised on grant / attach, withdrawn with the pane |
| `…/Extensions/CoreExtensionPoints.swift` | — | The `tabs.paneSignals` point; declaration checks |
| `…/Layout/LayoutEngine.swift` (`PaneSignalHost`) | `PaneFocusFollower` (`core/registry/paneHandles.ts`), `bellStore`'s window `focus` listener, `TerminalRenderer.tsx` teardown | When a signal is seen; panes leaving the layout end theirs; "looked at" and "focused" |
| `Sources/Tabs/Workspace/Signals.swift` (`SignalStyle`, `SignalPulse`, `SignalIconView`, `SignalOutlineView`); `PaneViews.swift` (header), `TabStrip.swift` (tabs), `TreeViews.swift` (outlines) | `content/Pane.tsx`, `content/tabs/TabBar.tsx`, `content/CueIcon.tsx`, `content/icons.tsx`, `styles/global.css` | Icons, outline + glow, pulse, tool tips |
| `…/Workspace/WorkspaceRenderer.swift` (`requestUserAttention`, `isFocused`), `WorkspaceWindowController.swift` (key), `App/AppShell.swift` (app active) | `src/main/bell.ts`, window `focus` | Dock bounce; window focus |
| `Sources/Tabs/UI/PaneSettingsPage.swift`; `SettingsStore` (`core.panes.disabledSignals`) | `settings/PanesSettings.tsx`, `src/shared/settings.ts` | The switches |
| `Plugins/Terminal/Sources/TerminalPlugin.swift` (`TerminalSignals.bell`), `TerminalPane.swift` (`surfaceBell`) | `packages/plugin-terminal/renderer/TerminalRenderer.tsx` (`term.onBell`) | The real bell, raised on BEL |
| `Sources/Tabs/Testing/SignalFixtures.swift` (Debug) | — | Stand-in `bell` |

## Cases

"Active" = exactly the window's `activePaneId` (may be a tab group). "Focused" = key window of
the active app (`NSApp.isActive && isKeyWindow`; Electron `document.hasFocus()`). "Looked at" =
active and focused.

### Raising a bell

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-1 | Bell in a pane that isn't its window's active pane → flagged: icon before the header title, content outlined in the bell color with inner glow, pulsing | `bellStore.ts:ring`; `Pane.tsx` (`.pane-alert`) | `PaneSignalsTests/aBellOnAPaneThatIsntActiveFlagsIt`, `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle`, `UITests.Signals/theOutlineCoversThePanesContentInItsKindsColor` |
| S-2 | Bell in the active pane of a focused window → dropped: nothing shown, nothing kept | `bellStore.ts:ring` | `PaneSignalsTests/aBellInTheActivePaneOfAFocusedWindowIsDropped`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt`, `SignalEndToEndTests/aBellInTheLookedAtPaneIsDroppedAndOthersBounceTheDockOnce` |
| S-3 | Bell in the active pane of an unfocused window → flagged | `bellStore.ts:ring` | `PaneSignalsTests/aBellInTheActivePaneOfAnUnfocusedWindowFlagsIt`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-4 | A tab group being active doesn't count as looking at its leaves: a bell inside flags (exact id compare) | `bellStore.ts:ring` (`id === activePaneId`) | `PaneSignalsTests/aTabGroupBeingActiveIsntLookingAtItsPanes` |
| S-5 | Second bell in a flagged pane changes nothing (Dock aside, S-20) | `bellStore.ts:ring` (`ringing.has`) | `PaneSignalsTests/raisingAgainChangesNothing` |
| S-6 | Indicator off → bell dropped outright: not kept, no Dock bounce | `plugin/context.ts:bell.ring`, `src/main/bell.ts` (both gate `enableBellIndicator`) | `PaneSignalsTests/aSwitchedOffBellIsDroppedWithoutBouncing` |
| S-7 | Indicator off hides every flag at once; back on shows those still kept | `Pane.tsx`, `TabBar.tsx` (draw gated, `ringing` kept) | `PaneSignalsTests/switchingOffHidesWhatsUpAndSwitchingOnShowsItAgain`, `PaneSignalsTests/flippingASwitchRedrawsThePanesCarryingThatKind`, `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt` |
| S-8 | A flag lasts until seen, however long (no timer) | `bellStore.ts` | `PaneSignalsTests/aFlagLastsUntilSeen` |

### Seeing a bell (it clears)

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-9 | Pane becomes its window's active pane (click, tab switch landing on it, keyboard nav, plugin focusing it), even in an unfocused window → clears | `PaneFocusFollower` → terminal focus handle (`bell.clear`) | `PaneSignalsTests/becomingTheActivePaneClearsItEvenInAnUnfocusedWindow`, `UITests.Signals/clickingASignalledPaneClearsItsBellButNotItsStatus` |
| S-10 | Window gains focus while the flagged pane is its active pane → clears | `bellStore.ts` window `focus` listener | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt`, `SignalEndToEndTests/aBellInTheLookedAtPaneIsDroppedAndOthersBounceTheDockOnce` |
| S-11 | Window gains focus: flagged panes that aren't active stay flagged | `bellStore.ts` `focus` listener (active pane only) | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |
| S-12 | Clicking a background tab whose entry pane is flagged shows it and activates that pane: tab and header flags clear | `TabBar.tsx` → `PaneFocusFollower` | `PaneSignalsTests/showingABackgroundTabWhoseEntryPaneRingsClearsIt`, `UITests.Signals/clickingItsTabClearsABackgroundPanesBell`, `SignalEndToEndTests/aShellsBellInABackgroundTabRaisesItsSignalAndLookingClearsIt` |
| S-13 | Tab switch activating another pane of that tab: the flagged one stays flagged, its tab keeps the icon | `PaneFocusFollower` (only the active pane is focused) | `PaneSignalsTests/aTabSwitchLandingOnAnotherPaneKeepsTheFlag` |
| S-14 | Pane closes → its signals end | `TerminalRenderer.tsx` teardown (`teardownLocal` → `bell.clear`) | `PaneSignalsTests/closingAPaneEndsItsSignals`, `UITests.ControlledPanes/closingTheOwnedPaneEndsItsCue` |
| S-15 | Pane moves to another window: Electron drops the flag (per-window `bellStore`; old window's teardown clears it). **Deviation:** follows its pane | `TerminalRenderer.tsx` (`abandonTerminal` → `teardownLocal`) | `PaneSignalsTests/aSignalFollowsItsPaneIntoAnotherWindow` |
| S-16 | Pane moves within its window (split, dock, unpin, pin, reorder) → flag stays, unless the pane becomes active | `TerminalRenderer.tsx` (`releaseTerminal` grace reattach) | `PaneSignalsTests/movingInsideTheWindowKeepsItUnlessThePaneBecomesActive` |

### Where a bell shows

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-17 | Pane header: right after the grip, before the title | `Pane.tsx` (`PaneGrip`, `CueIcon`, title) | `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle`, `SignalEndToEndTests/aStatusShowsInTheVisiblePanesHeaderAndOutlineButNeverOnItsTab` |
| S-18 | Every tab whose content holds the flagged pane, at every depth, active tab included: icon before the tab's title (one per kind; pulse from the earliest raise) | `TabBar.tsx` (`collectLeaves` vs `ringing`) | `PaneSignalsTests/tabsMarkTheirPanesSignalsAtEveryDepthButNotStatuses`, `PaneSignalsTests/aTabsMarkRunsFromTheEarliestRaise`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows` |
| S-19 | Flagged pane in a background tab: its tabs show the icon though the pane isn't on screen | `TabBar.tsx` | `PaneSignalsTests/showingABackgroundTabWhoseEntryPaneRingsClearsIt`, `UITests.Signals/clickingItsTabClearsABackgroundPanesBell`, `SignalEndToEndTests/aShellsBellInABackgroundTabRaisesItsSignalAndLookingClearsIt` |
| S-20 | Dock bounces once (informational) per bell while the pane's window isn't focused and the indicator is on — repeats on a flagged pane too; never while focused (macOS ignores it while the app is active). Tests count requests; the bounce itself isn't seen | `src/main/bell.ts:registerBellIpc` ← `plugin/context.ts:bell.ring` | `PaneSignalsTests/aKindAskingForAttentionBouncesTheDockEveryTimeWhileUnfocused`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt`, `SignalEndToEndTests/aBellInTheLookedAtPaneIsDroppedAndOthersBounceTheDockOnce` |

### Controlled panes

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-21 | A pane another pane owns → robot before the header title, outline in the agent color, slow pulse (4.5s) | `controlStore.ts`; `Pane.tsx` (`.pane-controlled`); `global.css` (`control-pulse`) | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab`, `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab` |
| S-22 | Never on a tab, not even a background one | `TabBar.tsx` (bells only) | `PaneSignalsTests/tabsMarkTheirPanesSignalsAtEveryDepthButNotStatuses`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows`, `SignalEndToEndTests/aStatusShowsInTheVisiblePanesHeaderAndOutlineButNeverOnItsTab` |
| S-23 | Activation, focus, being looked at never clear it | `controlStore.ts` (only `onOwnershipChanged` writes) | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `UITests.Signals/clickingASignalledPaneClearsItsBellButNotItsStatus` |
| S-24 | Ownership released → cue goes | `externalControl.ts:releaseOwnership` → `controlStore.ts:setControlled` | `PaneSignalsTests/aStatusStaysUntilWithdrawn`, `ControlPlaneTests/closingThePaneWithdrawsItWhoeverClosesIt` |
| S-25 | Indicator off hides it; state kept, so back on shows every pane owned now | `Pane.tsx` (`enableControlIndicator` gate) | `PaneSignalsTests/aStatusRaisedWhileSwitchedOffIsKeptHidden` |
| S-26 | Follows its pane into another window | `externalControl.ts:broadcastOwnership`; `controlStore.ts` (`getOwnedPanesSync` snapshot) | `PaneSignalsTests/aSignalFollowsItsPaneIntoAnotherWindow` |
| S-27 | Hovering the robot shows the system tool tip "Controlled by another pane"; the bell has none. Native: tool tip rects on header and tab icons (`SignalIconRow.installTooltips`) | `CueIcon.tsx`, `Pane.tsx` (`title`) | — (tool tips need a shown window and a real pointer) |
| S-28 | Raised when a pane is created through tabs-ctl from inside another pane (`create-browser-pane`), from the instant its plugin builds it; withdrawn by `close-pane`. **Deviation:** a pane the user closes by hand stays in Electron's ledger; natively it leaves with the pane (its owner is then told it's gone) | `externalControl.ts:grantOwnership` / `releaseOwnership` | `ControlPlaneTests/aPaneIsOwnedFromTheInstantItsPluginBuildsIt`, `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab`, `ControlPlaneTests/closingThePaneWithdrawsItWhoeverClosesIt` |

### Several cues

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-29 | Pane both flagged and controlled: bell, then robot; outline takes the controlled color and pulse (later rule wins) | `Pane.tsx` (icon order); `global.css` (`.pane-controlled::after` after `.pane-alert::after`) | `PaneSignalsTests/severalSignalsShowInKindOrderAndTheLastOutlines`, `UITests.Signals/aSignalsIconSitsBeforeTheHeaderTitle` |
| S-30 | A cue on the active pane replaces its accent outline (pulsing) | `global.css` (`.pane-alert::after` after `.pane-active::after`) | `UITests.Signals/aCueOnTheActivePaneReplacesItsAccentOutline`, `SignalEndToEndTests/aStatusShowsInTheVisiblePanesHeaderAndOutlineButNeverOnItsTab` |
| S-31 | A cue's icons and outline breathe together; separate cues and panes keep their own time (native: from the raise) | `global.css` (`--cue-pulse`, shared by icon and `::after`) | `UITests.Signals/aPulsingIconAnimatesFromItsRaiseAndASteadyOneDoesnt`, `UITests.Signals/thePulseFollowsTheElectronKeyframes` |
| S-32 | Dragged pane dims to 40% with its cues; a dock preview over a cued pane covers its cue | `global.css` (`.pane-dragging`; `.dock-preview` z-index 10 over the z-index-less `::after`) | `UITests.Signals/aDraggedPanesOutlineDimsWithIt`, `UITests.Signals/theDockPreviewCoversASignalledPanesOutline` |
| S-33 | An inactive, dimmed pane's cue isn't dimmed (filter on the content only) | `global.css` (`.pane-dimmed > .pane-body > *:not(.tabs-view)`) | — (`Visual/` `signal-header` pixels: its signalled pane is dimmed) |
| S-34 | A cue at the window's bottom corner follows the corner radius, as the active outline does | `global.css` (`--pane-corner-radius-left/-right`) | — (harness has no window radius; shares the active outline's radii) |
| S-35 | Any number of panes carry cues at once, each with its own outline | `bellStore.ts` (`ringing: Set`), `controlStore.ts` (`controlled: Set`) | `PaneSignalsTests/windowFocusClearsTheActivePanesBellOnly`, `UITests.Signals/windowFocusDecidesWhetherABellIsLookedAt` |

### Settings (Settings ▸ Panes & Tabs, live)

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-36 | **Bell indicator** (`enableBellIndicator`, default on), after Dimming intensity: "Pulse a bell icon and bounce the Dock icon when a pane signals for attention." **Deviation:** one switch per kind in the Indicators section (last), stored sparse in `core.panes.disabledSignals`, id `settings-signal-<kind>-checkbox`; a disabled plugin's kinds leave the page. The terminal's detail reads "…when a terminal rings its bell." | `settings/PanesSettings.tsx`, `src/shared/settings.ts` | `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `UITests.Signals/aDisabledPluginsKindsLeaveTheSettingsPage`, `PaneSignalsTests/aDisabledPluginsKindsHaveNoSwitch`, `PaneSignalsTests/theSwitchesPersistAndABadValueFallsBackAlone`, `TerminalPluginTests/theBellIsASignalWithTheElectronBellsParameters` |
| S-37 | **Control indicator** (`enableControlIndicator`, default on), after it: "Pulse a robot icon and highlight a pane's own border while another pane is controlling it." | `settings/PanesSettings.tsx`, `src/shared/settings.ts` | `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `PaneSignalsTests/aStatusRaisedWhileSwitchedOffIsKeptHidden` |

### Accessibility and ids

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-38 | Each icon is an image labelled "Bell" / "Controlled by another pane"; clicks pass to the chrome under it. Electron ids `pane-bell-icon`, `tab-bell-icon`, `pane-control-icon` (no `tab-control-icon`). **Deviation:** ids `pane-signal-<kind>`, `tab-signal-<kind>` | `CueIcon.tsx` (`role="img"`, `aria-label`); `Pane.tsx`, `TabBar.tsx` | `UITests.Signals/anIconIsAnImageLabelledForAccessibility`, `UITests.Signals/aTabHoldingASignalledPaneShowsItsIconAndGrows`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab` |

## Look

From `global.css` and `icons.tsx` (px = pt).

| Id | Element | Box | Colors dark / light | States | Scenario |
|---|---|---|---|---|---|
| L-1 | Header icon | 16×16 in the header's flex row, 8px gaps: grip, bell, robot, title. Centered in the 24px bar (4px from its top). Title moves right 24px per icon | cue color | pulsing (L-7), dragging (40%) | `signal-header` |
| L-2 | Tab icon | 16×16 before the title; tab's left padding 10px → 2px (`.tab:has(> .bell-icon)`), 2px gap to the title; centered in the tab's 21px content box (2.5px below its top). Tab grows 10px, still max 220px (title truncates sooner) | cue color, on the tab's own surface | pulsing, hover, dragging | `signal-tabs` |
| L-3 | Bell glyph | 16-unit viewBox: body `M8 2.5c-2 0-3 1.6-3 4v1.3c0 .9-.3 1.7-.9 2.4l-.6.7h9l-.6-.7c-.6-.7-.9-1.5-.9-2.4V6.5c0-2.4-1-4-3-4z`, clapper `M6.5 12.3a1.5 1.5 0 0 0 3 0`; stroke 1.2, round caps and joins, no fill | `--bell-alert` #ff453a / #d70015 | | `signal-header` |
| L-4 | Robot glyph | antenna dot ⌀2 at (8, 1), filled; stem (8, 2)→(8, 3.5) stroke 1.2 round; head rect (2.5, 3.5) 11×9 r2 stroke 1.2; eyes ⌀2.2 at (5.7, 8) and (10.3, 8), filled; mouth (5.5, 10.8)→(10.5, 10.8) stroke 1.2 round | `--agent` #b48cff / #7b45d8 | | `signal-controlled` |
| L-5 | Outline | the active outline's box: the content area (below the chrome bar), 1px past its padding box left, right, bottom; 1px border in the cue color; bottom corners follow the window radius | cue color | pulsing, dragging | `signal-header` |
| L-6 | Glow | `inset 0 0 14px 0 color-mix(in srgb, cue 55%, transparent)`: inner shadow from the outline's inner edge | cue at 55% | pulsing | `signal-header` |
| L-7 | Pulse | opacity 0.3 from 0% to 30%, ease-in-out up to 1 at 56%, ease-in-out down to 0.3 at 69%, 0.3 to 100%; infinite; bell 3s, controlled 4.5s; icons and outline (with glow) alike | — | peak (1), trough (0.3) | `signal-trough`, `signal-rise` |
| L-8 | Both cues | bell then robot in the header; outline in the controlled color | | | `signal-both` |

## Electron quirks kept for parity

Generalized to every kind:

- Every raise of a Dock-bouncing kind bounces the Dock while its window isn't focused, repeats
  on a pane already carrying it included (S-20).
- Several kinds on one pane: every icon, one outline — the last kind's (S-29).
- A tab group being active doesn't count as looking at its leaves (S-4): "looked at" and clearing
  compare the active pane id exactly.
- A kind that doesn't mark tabs shows nothing while its pane is in a background tab (S-22).

## Can't be ported as-is

- **CSS animations** → a Core Animation keyframe animation (`SignalPulse`, same curve) on the
  icons' and outline's layers, `beginTime` = the raise, so one signal's views breathe together
  whenever they're built.
- **`title` tooltip** → AppKit tool tip rects over the icons (header and tab), for kinds with a
  `tooltip`.
- **`app.dock.bounce('informational')`** → `NSApp.requestUserAttention(.informationalRequest)`
  (only when windows are presented; tests read `attentionRequests`).
- **`document.hasFocus()` and window `focus`** → key window of the active app;
  `windowDidBecomeKey`, app `didBecomeActive`.

## Checking the look

Scenarios `Visual/scenarios/signal-*.json` (method: [LAYOUT.md](LAYOUT.md)). `signals`:
`{"<pane id>": ["bell" | "controlled"]}` (the stand-ins); `pulse`: freeze every pulse that many
seconds in (default: none = peak, opacity 1, as Electron's capture with animations cancelled).
Both dumps add `signalIcons` (per header and tab) and `cue` (the kind outlining a pane), only
where present.

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

## Known differences

- Signals follow their pane to another window (S-15); Electron's per-window store drops a bell.
- One switch per kind (`core.panes.disabledSignals`) instead of `enableBellIndicator` /
  `enableControlIndicator`; ids per kind (S-36, S-38).
- The pulse keeps time from the raise: a view rebuilt after a move keeps its phase (a remounted
  Electron element restarts).
- A user-closed owned pane leaves the ledger (S-28).
- Not checked by hand in a real window: the live pulse, the Dock bounce, tool tips (captures
  render frozen layers; tests can't show windows).
