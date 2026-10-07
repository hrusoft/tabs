# Browser

A web page in a pane: Back / Forward / Refresh and an address bar in the header, plus 20
`tabs-ctl` verbs to open, read and drive it from an agent's terminal pane, on core's control
plane. One `WKWebView` per pane; plugin `Plugins/Browser` (id and content type `browser`), SDK
only.

## Scope

- **Every verb and the control plane they need** (ledger, `batch`, `capabilities`/`describe`,
  `controlled` signal, placement setting, `tabs-ctl` + skill). `SKILL.md` and its
  `scripts/tabs-ctl` stub live in `Sources/Tabs/Resources/skills/tabs`, bundled unchanged; the
  relay itself is `Sources/TabsCtl`, bundled as `Contents/Helpers/tabs-ctl`.
- **No `read-network` / `capture-bodies`**: `WKWebView` has no request-observation API, and a
  proxy can't see inside https. Absent entirely: unknown commands, not in
  `capabilities`/`describe`, no network section in the guide. Don't add them.
- **Look**: the visual scenarios check the chrome (buttons, address bar, title segment, frame);
  their fixture pages are text-free solid colors.
- **Public WebKit API only**, but for the pointer move and the loopback exemption's grant
  (Implementation notes). Web data lives in
  `WKWebsiteDataStore(forIdentifier: context.webDataStoreIdentifier)`; never `.default()`
  (shared with other plugins; `Scripts/lint-plugin-boundaries.py` refuses it). Cookies and
  storage persist across launches.
- **A moved pane keeps its page** (an AppKit view keeps its state): nothing reattaches or
  reloads. `pageInstance` is stable for the page object's life.

## Sources

Paths under `Plugins/Browser/Sources/` unless rooted.

| File | What |
|---|---|
| `Plugins/Browser/Info.plist` (`TabsPlugin`), `plugin.yml` | Identity: `browser`, "Browser", `canDisable`, `sortOrder` 6 |
| `BrowserPlugin.swift` | Activation: content type ("New browser"; seed or copy of the origin browser's config), settings page, verbs; `BrowserServices` (live panes, `openExternal`, `AgentFiles`, the web data store, `save-resource`'s byte cap); launch sweep |
| `Model/AddressInput.swift` | `resolveAddressInput` |
| `Model/UrlPolicy.swift` | `isAllowedUrl` (steer-to), `isAllowedResourceUrl` (read-from), `isSafeExternalUrl` (OS-open) |
| `Model/UrlComparison.swift` | `isTrivialUrlChange` (`redirected`) |
| `Model/LoopbackUpgrade.swift` | `wantsLoopbackExemption`, `isLoopbackHost`, `upgradesInsecureRequests` (C-10) |
| `Model/BrowserSettings.swift` | `NewPanePlacement`, `resolveNewPanePlacement`, total decoder |
| `Model/AriaRoles.swift` | `roleFilterError` |
| `Model/Limits.swift` | `BrowserLimits` (caps, waits, ref-registry globals), `clampWaitTimeout`/`clampWaitPoll`, stale-ref and not-mounted messages |
| `Model/FindElements.swift` | `scoreElement`, `findElements` |
| `Model/Keystrokes.swift` | Events per keystroke; `USKeyboard` (DOM key → macOS key code) |
| `Model/RingLog.swift` | Console ring, `compilePattern`, `patternFilterError` (plugin-private) |
| `Model/PageTypes.swift` | Element targets, `KeyModifier`, `EditingCommand` |
| `Page/BrowserPage.swift` | The `WKWebView` (`BrowserWebView`), delegates + KVO, committed URL, status, load failure, console, history, the starting-blank rule, script evaluation, viewport, snapshot |
| `Page/LoopbackExemption.swift` | The content rule list that keeps an upgraded loopback request on http (C-10): rules, grant, compiled once per plugin into its cache |
| `Page/PageEvents.swift` | Page events (start, stop, navigate, in-page navigate, fail, title, destroyed) for the header and the waits |
| `Page/ConsoleCapture.swift` | Document-start console wrapper + error listener; `InputAcknowledgement` |
| `Page/ErrorPage.swift`, `Page/LoadErrors.swift` | `tabs-error:` error document; `NSError` → `ERR_*` (Chromium's net error names, the vocabulary every answer uses) |
| `Page/PageValues.swift` | `DocumentStatus`, `ConsoleEntry`, `PageScriptError`, `HTTPStatusText`, `fallbackTitle` |
| `Page/PageScripts.swift`, `Page/WaitScripts.swift` | Page scripts (standard DOM): refs, roles/names, visibility, hit test, fill, scroll, waits |
| `Page/PageInput.swift` | Trusted `NSEvent` input, input acknowledgement, host-focus restore |
| `Page/PageWait.swift` | Navigation-surviving wait supervisor |
| `UI/BrowserPane.swift` | `PaneController`: config, title, focus, `list-panes`/`pane-info` fields |
| `UI/BrowserToolbar.swift`, `UI/BrowserStyle.swift` | Header title slot: three buttons, address bar + title segment; metrics, text layout (`BrowserText`), edge snapping (`snap`) |
| `UI/BrowserGlyphs.swift` | Globe, back, forward, refresh |
| `UI/BrowserSettingsPage.swift` | The one picker |
| `Control/BrowserVerbs.swift` + `Navigation*`, `Read*`, `Input*`, `TargetingInput`, `ScriptVerbs`, `WaitVerbs`, `Resource*`, `VerbSupport` | The 20 verbs: specs, budgets, handlers; capability (guide + limits) |
| `Control/ResourceFetch.swift` | `save-resource` routes: data, http(s), blob |
| `Control/AgentFiles.swift` | File sink: `--out`, generated paths, sweep |
| `Control/guide.md` | The guide `describe` serves: no network section, WebKit's behavior (Notes) |
| `BrowserTestVerbs.swift` (Debug) | `browser.test.*` verbs for UI/e2e/visual |
| **SDK** `ControlVerbContribution` (`command`, `wireType`, `batchable`, `timeoutFor`, `resultShape`, `.elementTarget`, `.ownedPane`), `ControlCapabilityContribution`, `ControlInvocation.pane(as:)`; `PaneController.controlSummary`/`controlDescription()`; `PaneRequest(activates:controlledBy:)`, `Workspace.revealPane`; `PluginContext.webDataStoreIdentifier` | Plugin side of the control plane |
| **Core** `Sources/TabsCore/Control/`: `ControlPlane` (dispatch order, core verbs, `batch`, `capabilities`/`describe`), `ControlEnvelope` + `ControlFlags`, `ControlSchema`, `ControlServer`, `PaneOwnership` | Everything about a verb that names no page |
| **Core** `Panes/ControlledSignal.swift` | `controlled` signal: grant → raise, close → withdraw |
| **Core** `Skills/SkillInstaller.swift`, `Sources/Tabs/UI/AiSettingsPage.swift`; `project.yml` bundles `Sources/Tabs/Resources/skills` | Skill install per agent |
| **Core** `PaneRuntime.childEnvironment` | `TABS_PANE_ID`, `TABS_CONTROL_SOCKET` |

## Cases

Tests: `Plugins/Browser/Tests` = unhosted, real core; `UITests.*` = the real shell, windows
never shown; `*EndToEndTests` = the running app driven by its own bundled `tabs-ctl`, only for
what the other tiers can't show: the relay's own reads (an answer on the line, one past a pipe
buffer) and exit code, and the built bundle wired into the launched app.
Pages come from a loopback `FixtureServer` (`Tests/Support`). A test waits on what it can see
(a wait arming in the page, a gated response, a decided navigation), not on a sleep.

### Creating and restoring

| Id | Case | Test |
|---|---|---|
| A-1 | Creation action "New browser" with the globe (empty pane's button, ⌘P palette, new tab/split "like" a browser); the palette lists the display name "Browser" | `BrowserPluginTests/theCreationActionIsNewBrowserSeededToAboutBlank`, `UITests.BrowserUITests/theCreationActionsOfferNewBrowser` |
| A-2 | Seed config `{url: "about:blank"}`; a pane made from a browser copies its current config as-is; from any other type, the seed (a browser has no directory: it neither inherits nor offers one) | `BrowserPluginTests/aCopyOfABrowserStartsWhereTheOriginalIs`, `UITests.BrowserUITests/aNewTabOrSplitLikeABrowserStartsWhereItIs` |
| A-3 | New pane starts blank: address bar `about:blank`, no title segment | `BrowserPluginTests/aNewPanesAddressBarReadsAboutBlank` |
| A-4 | Restored, duplicated or relaunched pane loads its saved `config.url` (the current page, not the seed); unknown config keys kept | `BrowserPluginTests/aRestoredPaneLoadsItsSavedURL` |
| A-5 | `config.url` follows every committed document: navigation, in-page (pushState, hash), a failed load's error page (the failed URL) | `BrowserPluginTests/theConfigFollowsEveryNavigation` |
| A-6 | Unreadable saved config (not an object; `url` not a string) → pane refused (core keeps it verbatim, unavailable, with the error); missing/null `url` → `about:blank` | `BrowserPluginTests/aSavedConfigItCannotReadRefusesThePane`, `BrowserPluginTests/aMissingURLTakesTheDefault` |
| A-7 | Can be disabled: creation actions and settings page go, open panes keep running (core's gate, NEW-CONTENT.md D-3); `create-browser-pane` refused (J-1) | `BrowserNavigationVerbTests/createBrowserPaneIsRefusedWhileTheBrowserContentTypeIsTurnedOff` |
| A-8 | No close warning; closing ends the page (`paneWillClose` → `BrowserPage.destroy`) | `BrowserPluginTests/hasNoCloseWarningAndClosingEndsThePage` |

### The header: navigation and address bar

| Id | Case | Test |
|---|---|---|
| B-1 | Header title slot = nav chrome: Back, Forward, Refresh, then the address bar filling the rest; no title text, no Edit title; the body is the page only | `UITests.BrowserUITests/aNewBrowserIsABlankPageWithNavChromeInItsHeader` |
| B-2 | Back/Forward disabled with nowhere to go (fresh pane: both); follow history after every navigation, in-page included | `BrowserPaneTests/theButtonsFollowThePagesHistory` |
| B-3 | The pane's starting `about:blank` is never a Back target; a later, deliberate `about:blank` keeps its history. The starting blank is never loaded (on WebKit an explicit `about:blank` load *is* a Back entry); `about:blank` typed on a never-loaded pane is a no-op | `BrowserNavigationTests/theStartingBlankIsNotABackTarget`, `BrowserNavigationTests/aDeliberateAboutBlankKeepsItsHistory` |
| B-4 | Back / Forward / Refresh step history / reload; nothing to step to → nothing | `BrowserNavigationTests/historyStepsWithNothingToStepToDoNothing`, `UITests.BrowserUITests/refreshReloadsThePage` |
| B-5 | Tooltip and accessibility label per button ("Back", "Forward", "Refresh"), disabled too; ids `browser-back-button`, `browser-forward-button`, `browser-refresh-button`. The tooltip is AppKit's, like the chrome's | `BrowserPaneTests/theButtonsCarryATooltipNamingWhatTheyDoDisabledOrNot` |
| B-6 | Address bar shows the committed URL (else the seed), follows navigations, except while focused: a background navigation never replaces typed text; unsent text stays until the next navigation | `BrowserPaneTests/theBarFollowsThePageButNeverTypedText` |
| B-7 | Return → `resolveAddressInput(text)`, then the field resigns focus; blank → nothing | `UITests.BrowserUITests/typingAURLAndPressingReturnNavigates`, `BrowserPaneTests/returnInTheAddressBarNavigatesToWhatItResolvesTo` |
| B-8 | Input rules: trimmed; blank → nil; bare domain checked first (`localhost[:port][/…]`, or a dot before the first slash and no whitespace) → `https://…`, so `localhost:3000` isn't a scheme; schemed URL unchanged; else `https://www.google.com/search?q=<encodeURIComponent>` (the engine isn't a setting) | `AddressInputTests` |
| B-9 | Title segment: the live title, only when non-empty; at most 30% of the bar, ellipsized, full title as tooltip (id `browser-title-segment`); `bgElevated` vs the input's `bg` | `BrowserPaneTests/theTitleSegmentIsSnugUntilItHitsThirtyPercent`, `BrowserPaneTests/paintsTheBarInTheThemesColorsInBothThemes` |
| B-10 | Bar border `accent` while the field has focus | `UITests.BrowserUITests/theBarsBorderTurnsAccentWhileTheFieldHasFocus` |
| B-11 | A press on a button or the field activates the pane without a pane drag (buttons fire on mouse-up inside, never disabled); a press on the title segment drags the pane like the rest of the bar | `UITests.BrowserUITests/aPressOnANavButtonActivatesThePaneWithoutStartingADrag`, `UITests.BrowserUITests/activatingFromTheHeaderDoesNotMoveTheKeyboardOntoThePage`, `UITests.BrowserUITests/aPressOnTheTitleSegmentDragsThePaneLikeTheRestOfTheBar`, `BrowserPaneTests/aButtonPressesOnMouseUpInsideAndNeverWhenDisabledOrReleasedOutside` |
| B-12 | Activating from the header doesn't move the keyboard onto the page (`BrowserPane.focusIsInChrome`) | `UITests.BrowserUITests/activatingFromTheHeaderDoesNotMoveTheKeyboardOntoThePage` |

### The page

| Id | Case | Test |
|---|---|---|
| C-1 | Page title → the pane's live title (title segment; a manual rename wins). No document title → a URL stand-in (`fallbackTitle`: `http://` dropped, a `file:` name, else the URL; none for `about:blank`, pane title "Browser"); an error page's title is the failed host | `BrowserNavigationTests/theTitleFollowsThePageWithAURLStandInForAPageWithoutOne`, `BrowserNavigationTests/theFallbackTitleIsDerivedFromEachKindOfURL`, `BrowserPaneTests/theBarFollowsThePageButNeverTypedText` |
| C-2 | A committed main-frame document clears the console, on commit (before its scripts run); an in-page navigation doesn't | `BrowserNavigationTests/aNewDocumentClearsTheConsoleBeforeItsOwnScriptsRun` |
| C-3 | Console capture: `console.log/info/debug/warn/error` (levels `info`/`info`/`verbose`/`warning`/`error`) with `%s %d %i %f %o %O %c %%` applied, uncaught errors and unhandled rejections, frames included; 200-entry ring, stable seq; survives moves; a page can't silence it; each entry carries the source URL and line of the call (of the throw, for an uncaught error), when the page has them | `BrowserConsoleTests` |
| C-4 | Failure of the load in flight (main frame; not a superseded or policy-cancelled load: `NSURLErrorCancelled`, WebKit 102) recorded as an `ERR_*` name from the moment the page exists, so one before anything listens is known; cleared when the next load starts; a superseded navigation is no failure | `BrowserFailureTests/aFailureThatLandsBeforeAnythingListensIsKnown`, `BrowserFailureTests/theNextLoadForgetsTheRecordedFailure` |
| C-5 | A failed main-frame load is a commit: the error page is a real history entry at the failed URL; `config.url` = failed URL; previous status and console dropped | `BrowserFailureTests/theErrorPageIsARealHistoryEntry` |
| C-6 | HTTP status + text of the last committed main-frame document (≥ 100); none for non-HTTP (`about:blank`) or an error page; an in-page navigation carries it forward; a history step keeps its entry's | `BrowserNavigationTests/recordsTheStatusOfTheCommittedDocument`, `BrowserNavigationTests/anInPageNavigationCarriesTheStatusForwardAndAHistoryStepKeepsTheEntrys` |
| C-7 | `pane-info` fields: `url`, `title`, `isLoading`, `canGoBack`, `canGoForward`, `pageInstance`, `showingErrorPage` + `loadError` only on an error page, `viewport` (the page's own `innerWidth × innerHeight`; a page too busy to answer in 500 ms → the view's size) or `hidden: true` for a pane not on screen: never an invented viewport | `BrowserControlPaneTests/paneInfoReportsTheLivePageAndFlagsAnErrorPage`, `BrowserControlPaneTests/paneInfoRefusesToInventAViewportForAPaneThatIsNotShown` |
| C-8 | `list-panes` summary: `{paneId, type, title, url}`; `url` from the config (works unmounted) | `BrowserControlPaneTests/listPanesReportsTheUrlThePaneWouldBeSavedWith` |
| C-9 | The page's own history (`canGoBack`/`canGoForward`) drives the buttons and the verbs | `BrowserNavigationTests/canGoBackAndForwardAreThePagesOwnHistory` |
| C-10 | `upgrade-insecure-requests` never upgrades a loopback URL (`localhost`, `*.localhost`, `127.0.0.0/8`, `[::1]`): a dev server on `http://localhost` that sends it loads its scripts, styles, fetches and same-origin links over http. WebKit upgrades them (the page hangs half-loaded, a link fails with `ERR_SSL_PROTOCOL_ERROR`); `LoopbackExemption` redirects them back, only while the document is an `http` loopback one whose `Content-Security-Policy` header has the directive, as its history entry had it on a step back. An https loopback URL the app loads stays https. Limits: Notes | `BrowserLoopbackExemptionTests` |

### Input, focus and activation

| Id | Case | Test |
|---|---|---|
| D-1 | A press in an inactive pane's page activates it: any mouse-down (right-click, scrollbar drag included), never a scroll; core's click monitor (`WorkspaceInput`) | `UITests.BrowserUITests/aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage`, `UITests.BrowserUITests/aRightClickActivatesThePaneAndShowsNoContextMenu` |
| D-2 | The activating click still lands in the page (typing then reaches the clicked field; `acceptsFirstMouse`) | `UITests.BrowserUITests/aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage` |
| D-3 | App-injected input never activates the pane: injected `NSEvent`s go straight to the web view, past the app's monitors | `UITests.BrowserInputUITests/drivingAPaneNeverStealsKeyboardFocusFromTheTerminal` (an agent's input), `UITests.BrowserUITests/aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage` (a person's press, by contrast) |
| D-4 | Activation gives the page the keyboard, unless focus is in the pane's own header; deferred until the pane is in a window. Core moves the first responder (no separate blur) | `UITests.BrowserUITests/activatingAPaneGivesItsPageTheKeyboard` |
| D-5 | Pane-navigation chords (⌘+arrow, as bound) in a focused page move pane focus and never reach the page; core's keyDown monitor (`WorkspaceInput`) | `UITests.BrowserUITests/aNavChordPressedInAFocusedPageEscapesItWithoutReachingThePage` |
| D-6 | Every app shortcut (`PaneContext.isAppShortcut`) reaches the app from a focused page (`BrowserWebView.performKeyEquivalent`); other keys stay the page's | `UITests.BrowserUITests/everyAppShortcutIsLeftToTheAppByAFocusedPage` |
| D-7 | A verb's input never leaves host focus moved, a page's `el.focus()` included; a window where nothing had the keyboard is left so (`PageInput.withHostFocusRestored`, which also restores the field caret WebKit resets) | `BrowserInputTests/drivingThePageNeverStealsKeyboardFocusFromWhereItWas`, `UITests.BrowserInputUITests/drivingAPaneNeverStealsKeyboardFocusFromTheTerminal` |
| D-8 | The command palette takes the keyboard from a focused page (NEW-CONTENT.md P-5/P-6; a text view stands in for a live page) | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` |
| D-9 | Copy, paste, select all, undo follow the responder chain (Edit menu); undo/redo are the pane's own `UndoManager` (a window's is shared by its tabs, and a pane can move) | `BrowserInputTests/undoAndRedoAreThePanesOwn`, `UITests.BrowserUITests/theEditMenusActionsReachTheFocusedPage` |
| D-10 | The page shows no context menu; a right-click activates the pane | `BrowserPolicyTests/thePageHasNoContextMenu` |

### The pane in the layout

| Id | Case | Test |
|---|---|---|
| E-1 | Moving the pane (tab to another group, split, float, unpin, another window) keeps its page: history, scroll, form state, console, refs (Scope) | `UITests.BrowserUITests/aMovedPaneKeepsItsPage` |
| E-2 | Splitting or closing a sibling never remounts an existing browser pane | `UITests.BrowserUITests/aMovedPaneKeepsItsPage` |
| E-3 | A pane drag over a browser pane previews and drops there; the page never eats a drag begun elsewhere | `UITests.BrowserUITests/aPressOnTheTitleSegmentDragsThePaneLikeTheRestOfTheBar` (docks onto a browser pane) |
| E-4 | Verbs follow the pane across windows: an agent keeps driving and listing it | `BrowserControlPaneTests/anAgentKeepsDrivingAndListingItsPaneAfterTheUserDragsThatPaneIntoAnotherWindow` |
| E-5 | A hidden pane (background tab) keeps its page running; revealed, never activated, to be captured | `BrowserControlPaneTests/aBackgroundedPaneKeepsItsPageRunningAndAnswersTheReadVerbs` |
| E-6 | `pageInstance` changes only when the page is re-created (relaunch); a move doesn't change it | `BrowserNavigationTests/pageInstanceIsStableForAsLongAsThePageLives` |

### Popups and URL policy

| Id | Case | Test |
|---|---|---|
| F-1 | `target=_blank` / `window.open` in a user's pane → the OS's browser (`http`, `https`, `mailto` only; `file:`/custom schemes dropped); no app window opens. A main-frame `mailto:` link opens the mail client; the page stays | `BrowserPolicyTests/popupsGoToTheOSBrowserForAUsersPane`, `BrowserPolicyTests/aMailLinkOpensTheMailClientAndTheStaysWhereItIs` |
| F-2 | Agent-owned pane: popups (and `mailto:`) denied, no external open | `BrowserPolicyTests/aControlledPanesPopupsAreDenied` |
| F-3 | Owned from the instant the pane exists (before `create-browser-pane` answers): the guards apply to its first load | `BrowserPolicyTests/theGuardsApplyToAPanesVeryFirstLoad` |
| F-4 | Agent-owned pane: a page-initiated main-frame navigation (`location.href`, a link) outside `http`/`https`/`about:blank` is cancelled (`decidePolicyFor`); a user's pane is unconstrained | `BrowserPolicyTests/aPageCannotSteerAControlledPaneOutsideTheSchemeAllowlist`, `BrowserPolicyTests/aUsersPaneMayGoAnywhereTheEngineCanLoad` |
| F-5 | Verbs refuse a disallowed URL up front (`url not allowed: <url>`), before touching the pane tree | `BrowserNavigationVerbTests/aDisallowedURLSchemeIsRejectedWithoutTouchingThePaneTree` |
| F-6 | `isAllowedUrl`: `about:blank`, or `http:`/`https:` with a host; unparseable refused | `UrlPolicyTests/allowsAboutBlankAndTheWebSchemesForNavigation`, `UrlPolicyTests/refusesEverythingElseForNavigation` |
| F-7 | `isAllowedResourceUrl`: `http`, `https`, `blob`, `data`; `file:` and all else refused, re-checked on the URL about to be read (an element's `src` included); an http(s) redirect off http(s) refused | `UrlPolicyTests/refusesFileAndEveryOtherSchemeForReading`, `BrowserResourceVerbTests/aFileURLTakenFromAnElementIsRefusedToo` |
| F-8 | No host bridge: the page sees only the console handler (`tabsConsole`); error capture and input acknowledgement run in a private content world | `BrowserPolicyTests/thePageSeesNoHostBridgeButTheConsoleHandler` |

### Settings

| Id | Case | Test |
|---|---|---|
| G-1 | Settings ▸ Browser: one picker "New pane placement": New tab / Horizontal split / Vertical split / Unpinned window, default New tab; description "Where a browser pane created by an agent (via the tabs skill's createBrowserPane) appears relative to the pane that created it." (id `settings-browser-controlled-pane-placement-select`). The picker's write path isn't drivable in a never-shown window; decoding is tested (G-3), and a stored setting is read at launch | `BrowserPluginTests/theSettingsPageRenders`, `SettingsWindowTests/everyPageFitsItsWindowAndALongerOneScrolls`, `BrowserNavigationVerbTests/createBrowserPaneSplitsHorizontallyWhenPlacementIsSetToSplitHorizontal`, `SettingsTests/storedValuesMergeOverDefaults` |
| G-2 | Only `create-browser-pane` reads it; a browser opened by hand never does | `BrowserNavigationVerbTests/aBrowserOpenedByHandNeverReadsThePlacementSetting` |
| G-3 | Stored `controlledPanePlacement` normalized: anything but `tab`/`split-horizontal`/`split-vertical`/`unpinned` reads as `tab`; merged over the defaults, never throws | `BrowserSettingsTests` |
| G-4 | Page id `browser`, title "Browser", globe icon | `BrowserPluginTests/contributesASettingsPage` |

### The control plane (core)

| Id | Case | Test |
|---|---|---|
| H-1 | A request is `{command, args, paneId, cwd}`; `paneId` is the **caller's** pane (`TABS_PANE_ID`), never a wire claim; a caller that isn't an attached pane (or sends no `paneId`) → `not running inside a Tabs pane`, before anything else. Any attached pane of any type passes (`ControlPlane.dispatch`: `panes.contentType(of:) != nil`): an exited terminal's, a browser's, a git tree's; TERMINAL.md T-6 | `ControlPlaneTests/aCallerWithNoLivePaneIsRefusedBeforeAnythingElse`, `UITests.AiSettings/theBundledTabsCtlRefusesToRunOutsideATabsPane` |
| H-2 | Ownership: a pane a caller created is the caller pane's for the app run (never persisted or expired, survives the user navigating it); a verb naming `targetPaneId` acts only on an owned pane, else `not the owner of this pane`; checked once in core for every verb | `ControlPlaneTests/anAgentCreatesAPaneOwnsItAndDrivesItButNoOther`, `ControlPlaneTests/ownershipOutlivesTheUserNavigatingThePaneByHand` |
| H-3 | A pane closed (owner's `close-pane` or the user) answers its owner `target pane no longer exists — it was closed; listOwnedPanes shows the panes still open`; everyone else the uniform `not the owner of this pane` (no liveness leak); 100 tombstones, oldest out | `ControlPlaneTests/aPaneItsOwnerClosedIsGoneToThatOwnerAndUniformlyRefusedToEveryoneElse`, `PaneOwnershipTests/aHundredClosedPanesAreRememberedAndTheOldestGoFirst` |
| H-4 | Owned the instant the pane exists (`PaneRequest.controlledBy`), allowed only for the caller of the plugin's own running verb, never outside one | `ControlPlaneTests/aPaneIsOwnedFromTheInstantItsPluginBuildsIt`, `ControlPlaneTests/aPluginMayNameOnlyTheCallerOfItsOwnRunningVerbAsAControllerAndNeverOutsideOne` |
| H-5 | Owned panes carry core's `controlled` signal: robot icon, pulsing `agent` outline (4.5 s), tooltip "Controlled by another pane", until withdrawn, never on the pane's tab; Settings ▸ Panes & Tabs "Control indicator" | `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab` |
| H-6 | The ledger resets between tests (`tabs.test.reset`) | `ControlPlaneTests/theLedgerResets` |
| H-7 | Flags → wire request: unknown flag refused naming the valid ones; `--pane` → `targetPaneId`; enum, number (`minimum`), boolean (bare = `true`; an inverting flag sends its declared value), csv (split on commas), json (parse error reported), path (bare = `true`, "generate one"; a value resolved against the caller's `cwd`); a bare flag needing a value refused, never sent as `1`/`"true"`; a missing required flag named. A bool `--flag=false` still sends `true` | `ControlEnvelopeTests` |
| H-8 | Element target from flags: `--ref`, or `--x` + `--y`, or `--role`/`--name`/`--selector` (+ `--nth`, semantic only): exactly one form; both axes, numeric; `--nth` a non-negative integer; one composed `target` (`ControlFlagComposition.elementTarget`), no stray top-level fields | `ControlEnvelopeTests`, `BrowserInputVerbTests/everyElementTargetFormFromTheFlagsReachesTheHandler` |
| H-9 | The wire request is validated against the verb's JSON Schema (`additionalProperties: false`; `paneId` stripped first), the same check for a `batch` step and a flag-built request | `ControlSchemaTests`, `ControlPlaneTests/aWireRequestIsValidatedAgainstTheVerbsOwnSchema` |
| H-10 | Budgets: quick 5 s, read 15 s, 30 s (`execute-js`, `save-resource`); derived from the wait outlived: load 15 s + 5 s headroom (`reload`, history steps), `create-browser-pane` 5 s mount + 15 s load + headroom, `navigate` 2 × 15 s + headroom, `wait-for` clamped timeout + headroom per request (`timeoutFor`), `assert` 1 s + headroom, `batch` none. Deadline = budget + headroom; then `<type> timed out after <budget>ms` and the handler is cancelled | `ControlBudgetTests`, `BrowserNavigationVerbTests/theVerbsBudgetsAreTheseTiers` |
| H-11 | Core verbs: `ping`; `activate-pane` (reveal, never activate); `close-pane` (ownership released only once really gone; a declined close → `the pane was not closed`); `list-panes` (panes this caller created, every window); `pane-info` (identity + the type's live fields; gone → pane-gone error; a type that can't be inspected says so) | `CoreControlVerbTests` |
| H-12 | `batch --requests <json array> [--continue-on-error]`: in order, each step as the batch's caller (`paneId` overwritten); stops at the first failure (`stoppedAt`, later steps `{skipped: true}`), `--continue-on-error` runs all; ≤ 50; no nesting; an unbatchable verb refused by name (`createBrowserPane cannot be used inside a batch`); no deadline of its own; `ok: true` whenever it ran | `ControlBatchTests`, `BrowserNavigationVerbTests/createBrowserPaneCannotBeUsedInsideABatch` |
| H-13 | `capabilities`: `core`, then each plugin capability with `enabled` and one line per command (a disabled plugin's listed disabled; its verbs still answer); `describe --capability <id>`: limits, guide, every command's flags, wire schema, result shape; unknown capability refused naming `capabilities` | `CoreControlVerbTests`, `BrowserInputVerbTests/describeStatesTheInputVerbsFlags`, `BrowserReadVerbTests/everyDeclaredVerbIsRegisteredAndListedByCapabilities` |
| H-14 | Socket per boot (`control-<pid>.sock` in the data directory); one request per line, answered in order, one line each; a request split mid-character decodes intact; an unknown command refused cleanly; two instances on one data directory keep apart; `tabs-ctl` drains a response bigger than the pipe buffer | `ControlServerTests`, `ControlPlaneEndToEndTests/tabsCtlGetsItsAnswerOnTheLineIntactAndExitsNonZeroForAFailedStep`, `BrowserControlEndToEndTests/aPageTextBiggerThanThePipeBufferComesBackWhole` |
| H-15 | A malformed envelope is refused with a validation message before dispatch | `ControlPlaneTests/aMalformedEnvelopeIsRefusedWithAValidationMessageBeforeAnythingIsDispatched` |
| H-16 | Ring log (console): seq from 1, oldest evicted, seq stable across eviction, entries strictly after `sinceSeq`, no rewind on clear, removal by seq, `compilePattern` (regex; a bad one refused, never matched literally). Plugin-private | `RingLogTests` |

### `tabs-ctl` and the skill

| Id | Case | Test |
|---|---|---|
| I-1 | `SKILL.md` + `scripts/tabs-ctl` = `Sources/Tabs/Resources/skills/tabs`, bundled unchanged as `Contents/Resources/skills/tabs` (`Scripts/verify-app.sh` check 10); the stub runs `Contents/Helpers/tabs-ctl` (`Sources/TabsCtl`, check 11), found through its real path, so a symlinked skill directory works. The relay sends argv as `{command, args, paneId, cwd}` via `TABS_PANE_ID`/`TABS_CONTROL_SOCKET`; exits non-zero on `ok: false`, a failed batch step, or non-empty `errors`; settles on the first response newline (Notes); every outcome is one line of JSON | `RelayTests`, `UITests.AiSettings/theBundledTabsCtlRefusesToRunOutsideATabsPane`, `ControlPlaneEndToEndTests/tabsCtlGetsItsAnswerOnTheLineIntactAndExitsNonZeroForAFailedStep` |
| I-2 | Command names are kebab-case (`create-browser-pane`, `read-page`, …): a verb declares `command` + `wireType`; the qualified name (`browser.navigate`) works too; a bare command two verbs share is refused naming both | `ControlPlaneTests/aVerbAnswersToItsCommandAndToItsQualifiedName`, `ControlVerbRulesTests` |
| I-3 | Settings ▸ AI lists Claude Code (`~/.claude/skills/tabs`) and Codex (`~/.agents/skills/tabs`); Install symlinks the bundled skill, Uninstall removes it; never clobbers or removes what Tabs didn't create; installed = a link to *this* bundle's skill | `SkillInstallerTests`, `UITests.AiSettings/installThenUninstallThroughTheRealControlsChangeTheStatus` |
| I-4 | The guide never promises a verb the app lacks: no network section, every command it runs exists, its usage lines name the flags the verbs declare | `BrowserGuideTests`, `UITests.BrowserScriptUITests/theShippedBundleServesTheGuide` (the shipped bundle's) |

### The browser verbs

Names are CLI commands, wire types in parentheses. Every one but `create-browser-pane` takes
`--pane` (`targetPaneId`), owned by the caller; H-2, H-3, H-9, H-10 apply to all.

| Id | Case | Test |
|---|---|---|
| J-1 | `create-browser-pane --url` (`createBrowserPane`): refused for a disallowed URL (F-5) and while the type is off (`the Browser plugin is turned off in Tabs ▸ Plugins…; …`, Notes); placed by G-1 relative to the caller (a floating caller: inside its window; `unpinned`: a floating window near it); opened with `activates: false` (the caller keeps the keyboard) and `controlledBy: caller` (owned before its first load); waits ≤ 5 s for the page, ≤ 15 s to settle → `{paneId, loaded, loadError?, url, title, titleFromUrl?, status?, statusText?, redirected?}`; a failure that landed before anything listened comes from the page's record; not batchable | `BrowserNavigationVerbTests/createBrowserPaneAnswersWithThePageItLoaded`, `BrowserNavigationVerbTests/aFloatingCallersNewPaneOpensInsideItsWindowOrInAnotherFloatingOne`, `BrowserNavigationVerbTests/createBrowserPaneOpensANewTabByDefault`, `BrowserNavigationVerbTests/createBrowserPaneSplitsHorizontallyWhenPlacementIsSetToSplitHorizontal`, `BrowserNavigationVerbTests/createBrowserPaneSplitsVerticallyWhenPlacementIsSetToSplitVertical`, `BrowserNavigationVerbTests/createBrowserPaneOpensItsOwnUnpinnedWindowWhenPlacementIsSetToUnpinned`, `UITests.BrowserControlUITests/aCreatedPaneIsShownBesideTheCallerWhichKeepsTheKeyboard` |
| J-2 | `navigate --url [--retry-on-redirect]`: load, wait ≤ 15 s → `{loaded, url, title, titleFromUrl?, status?, statusText?, redirected?, retried?, firstUrl?}`; `redirected` = `!isTrivialUrlChange(requested, final)`, only once settled; failure = `failed to load <url>: ERR_…`; `--retry-on-redirect` re-issues once when the first attempt settled elsewhere (never while still loading) and reports `retried`, `firstUrl`; a failing retry adds `(on the retry — the first attempt landed on <url>)`. WebKit raises no event for a superseded load, so `navigate` waits out its replacement and answers `loaded: true` (`redirected` says where it went). A navigation the page starts within 150 ms of its load ending (script during parse or the load event, a zero-delay meta refresh) is followed the same way, here and in J-1: WebKit starts it after the load finishes (Notes) | `BrowserNavigationVerbTests/navigationVerbsReportWhereThePaneActuallyEndedUp`, `BrowserNavigationVerbTests/aScriptRedirectWhileThePageLoadsIsReportedAsARedirect`, `BrowserNavigationVerbTests/retryOnRedirectReassertsTheRequestedURLOnceAfterABounce`, `UrlComparisonTests` |
| J-3 | `reload` / `go-back` / `go-forward`: wait to settle → `{loaded, loadError?, url, title, …}`, no `redirected`; nothing to step to → `cannot go back — no earlier page in this pane's history` (`forward` / `later`). A history step onto a failed entry reports the entry's recorded failure (WebKit serves the stored error page without the network) | `BrowserNavigationVerbTests/reloadAndHistoryVerbsSettleOnThePageTheyLandOn` |
| J-4 | Every navigation answer reads the page at answer time: `url`, `title`, last document's status, `titleFromUrl: true` when `document.title` is empty (1 s read; unreadable → no flag), after reload and history steps too; never from title events | `BrowserNavigationVerbTests/titleFromUrlIsCorrectOnReloadAndHistoryStepsNotOnlyNavigate` |
| J-5 | Landing on a failed page, whichever verb: `navigate` fails `failed to load <url>: ERR_…`, the others answer `loaded: false` + `loadError`; status, console and `config.url` reflect the failure | `BrowserNavigationVerbTests/landingOnAFailedPageReportsTheFailureWhicheverVerbGotThere` |
| J-6 | `screenshot [--no-activate] [--selector css \| --ref ref]`: both forms refused before anything is revealed; a hidden pane is revealed (never activated) → `activated: true` (3 s to become paintable, empty captures retried within it); `--no-activate` fails naming the remedy; PNG to a file → `{path, width, height}` (device px) + `viewport`, `scaleFactor` (from the page, exact at a fractional width); a clip adds `clipped` (CSS px of the page, clamped to the viewport, rounded outward) and `element`; an element outside the viewport refused. At a fractional pane width WebKit rounds the viewport down (read from the page) | `BrowserSnapshotTests`, `BrowserSnapshotTests/screenshotClipsToOneElementInCSSPixelsClampedToTheViewport`, `BrowserReadVerbTests/screenshotRefusesBothFormsAtOnceBeforeItRevealsAnything`, `BrowserReadVerbTests/screenshotNoActivateFailsOnAPaneThatIsNotShown`, `UITests.BrowserControlUITests/screenshotRevealsABackgroundedPaneItselfAndSaysSoWithActivatedTrue` |
| J-7 | `get-page-text [--max-length]`: `innerText` cut at the limit (default 50 000, hard 200 000; UTF-16 units), `truncated` always honest, + readiness (J-11) | `BrowserReadVerbTests/thePageTextLimitsAreTheDefaultAndTheHardCap` |
| J-8 | `read-page [--selector] [--role] [--offset]`: interactive elements + headings (and images for `--role img`/`presentation`: `<img>` is `img`, `presentation` with `alt=""`), ≤ 200 per call, each `{ref, role, name, tag, rect, value, checked}`; `total`, `offset`, `truncated` (more after this page); validated up front (blank refused, unknown role refused with the vocabulary, `offset` a non-negative integer; a selector the page refuses is surfaced); sliced before refs are minted; names approximate the accessible-name algorithm (label text minus the control, a select's chosen option, `aria-labelledby`…), `checked` incl. `"mixed"` | `BrowserScriptTests/readPageListsWhatThePageShowsWithRolesAndNamesAsTheBrowserComputesThem`, `BrowserReadVerbTests/readPageNarrowsByRoleAndSelectorAndPagesByOffset` |
| J-9 | `find --description [--max-results]` (default 10): `scoreElement` ranking (a heuristic); refs minted only for the matches returned (two page calls); a match that left the page in between is dropped | `BrowserReadVerbTests/findMintsRefsOnlyForTheMatchesItReturns`, `FindElementsTests` |
| J-10 | Refs `e<n>-<document tag>` in a per-document registry (1 000 kept); a ref from another document is stale and says so (`… so call readPage again`); a semantic target matches by a strictness ladder (exact, case-insensitive exact, substring), visible elements only; ambiguity fails listing candidates (`nth` picks); role is a hard filter with a near-miss diagnosis | `BrowserScriptTests/semanticTargetsMatchByTheStrictnessLadder`, `BrowserInputVerbTests/aStaleElementRefReportsWhyRatherThanClickingSomethingElse`, `BrowserInputVerbTests/anAmbiguousSemanticTargetFailsListingItsCandidatesAndNthPicksAmongThem` |
| J-11 | Readiness on every read: `isLoading`, `readyState`, `settled` (no DOM mutation for 500 ms since first observed: a page's first read is never settled), `frames`, `shadowRoots` (open, top level) | `BrowserReadVerbTests/readVerbsReportReadinessAndSettledFlipsOnlyWithTheDOMActuallyQuiet`, `BrowserReadVerbTests/readVerbsReportFrameAndShadowCounts` |
| J-12 | `click`: a ref/semantic target is resolved, scrolled into view (instant) and hit-tested in one page script; a point no longer holding it gets one retry after 100 ms, then fails naming both elements; a coordinate is pressed as given, only described; a move (`_simulateMouseMove:`, reaching the page only in the key window, J-13), then trusted `mouseDown`, `mouseUp` → `{x, y, element}` | `BrowserInputTests/aClickArrivesAsTrustedMouseEventsAndFocusesTheField`, `BrowserInputVerbTests/aClickWhoseTargetIsCoveredFailsNamingBothElementsInsteadOfPressingTheCover` |
| J-13 | `hover`: `click`'s resolution and hit test, then a trusted move only; the hover persists; answers once the page saw the `mousemove`. In a window that isn't key WebKit delivers no move, so hover fails there (after resolving its target) naming the cause and the remedy | `BrowserInputVerbTests/hoverOpensAHoverOnlyMenuWithoutCommittingTheClick`, `BrowserInputVerbTests/hoverInAWindowThatIsNotKeyFailsSayingWhy`, `BrowserInputVerbTests/hoverResolvesTargetsAsClickDoesAndNeverPresses`, `BrowserInputTests/aMoveHoversThePageInTheKeyWindowAndIsRefusedInAnyOther` |
| J-14 | `type --text [--submit]`: printable text only (a control character refused up front naming it and its UTF-16 index, before anything is focused); ref/semantic target focused directly, a coordinate clicked; printable ASCII = full keydown/keypress/keyup inserting once (capitals shifted), other characters as inserted text alone, in order with the keys around them (an insert waits for the keys before it); `--submit` presses Enter (a plain form submits once, a textarea gains one line break); appends | `BrowserInputTests/typingDeliversEachCharacterAsKeydownKeypressInputAndKeyupInsertingOnce`, `BrowserInputTests/textMixingKeysAndCharactersWithNoKeyLandsInOrder`, `BrowserInputTests/aPageSlowToTakeEachKeyHasThemAllWhenTypingAnswers`, `BrowserInputVerbTests/typeRefusesTextItsKeystrokesCannotCarryBeforeTouchingThePage`, `BrowserInputVerbTests/typeAfterFormInputAppendsToTheFilledValue`, `BrowserInputTests/drivingThePageNeverStealsKeyboardFocusFromWhereItWas` (appends), `KeystrokesTests` |
| J-15 | `key [--key] [--modifiers csv] [--command]`: exactly one of key/command; meta or control held → no character; arrows keep `key`/`code` under every modifier; a meta/control chord on a, c, v, x, z, y answers with a `note` (the browser's editing commands ignore synthesized chords, Notes); `--command select-all\|undo\|redo\|delete` runs `execCommand` in the page (no clipboard commands) → `{command, element}`; a refused command errors | `BrowserInputTests/arrowKeysKeepTheirKeyAndCodeUnderEveryModifier`, `BrowserInputVerbTests/aModifierChordCannotReachTheEditingCommandsAndCommandCan` |
| J-16 | `scroll --direction [--amount]`: the document, instant even on a smooth page; default step `innerHeight`/`innerWidth` × 0.8 → `{position}` (settled), a hidden pane too; nested containers out of scope; `--direction` defaults to down as a flag, required on the wire | `BrowserInputVerbTests/scrollReportsWhereItLandedOnASmoothPage` |
| J-17 | `form-input --fields <json [{target, value}]>`: fields in order, each focused then filled in-page (select by value or visible label with `input`/`change`; input/textarea through the prototype's `value` setter; contenteditable via editing commands; multiline verbatim) → `{filled, fields: [{index, length}], errors: [{index, error}]}`; a field not holding what was sent (a single-line `<input>` given newlines), a non-fillable element, an unmatched option (options listed) → an error entry, the rest continue | `BrowserInputVerbTests/formInputSetsMultilineValuesVerbatimReadsThemBackAndRefusesFieldsThatWillNotHoldThem`, `BrowserScriptTests/fillWritesEachElementKindWholeAndReadsItBack` |
| J-18 | `read-console [--pattern] [--since-seq]`: captured messages after `sinceSeq` whose text matches; a bad pattern refused; reads the pane's buffer, no page script | `BrowserScriptVerbTests/anAgentCanReadTheConsoleIncludingAMessageThatArrivesLate` |
| J-19 | `execute-js --code [--out]`: one expression, awaited, in the page world whatever its CSP; a throw is data (`script threw: <Name: message>` then the stack's frames, less the bare `@` ones WebKit gives injected code); a non-expression → the IIFE hint; the value is what `JSON.stringify` (captured before the code runs) makes of it: `undefined` → `null`, a DOM node → `{}`, a cycle refused (the message names both: `… cannot be serialized (a DOM node, or a cycle)`); cut at 50 000 UTF-16 units (never splitting a surrogate pair) with `truncated`; `--out` writes it whole (a string raw as `.txt`, else pretty JSON `.json`) → `{path, bytes, format}` | `BrowserScriptVerbTests/aResultIsWhatJSONMakesOfIt`, `BrowserScriptVerbTests/aThrowsStackKeepsThePagesFramesAndDropsTheEmptyOnes`, `BrowserScriptVerbTests/executeJsOutWritesTheFullResultToAFileInsteadOfTruncating` |
| J-20 | `wait-for`: exactly one of `--text`, `--selector` (visible), `--url-contains`, `--idle`; `--gone` inverts text/selector; runs in the page (MutationObserver + fallback poll), one injection per document; host-side deadline (`--timeout` default 10 s, cap 300 s; `--poll` default 250 ms, floor 50) survives navigation by re-arming in the new document; a refused injection is retried; `--url-contains` never injects; a selector match → `ref`, `tag`, `rect`; answers `elapsedMs`; a closed pane aborts with the pane-gone error; a timeout names the condition. `--timeout 0` never checks (the deadline is tested before the first injection) | `BrowserWaitTests`, `BrowserWaitVerbTests/aTimeoutOfZeroNeverChecks` |
| J-21 | `assert`: `wait-for`'s single-shot twin (text / selector / url-contains, `--gone`; no idle) on a 1 s check; failure fails the verb (`assertion failed: page text does not contain "…"`) so a batch stops there; no `elapsedMs` | `BrowserWaitVerbTests/assertChecksAConditionRightNowPassWithAUsableRefFailNamingThePremise` |
| J-22 | `save-resource [--url \| --ref \| --selector] [--out]`: exactly one source (an element's `currentSrc`/`src`/`href`/`data`); `data:` decoded in-app; `http(s)` fetched host-side (not bound by CSP/CORS) with the page's cookies and User-Agent, streamed under the 50 MB cap, 25 s total (not a stall timeout), status ≥ 400 refused, response cookies written back, redirects off http(s) refused; `blob:` fetched in a private content world, the one blob route (only a revoked blob fails); file extension from content type → magic bytes → URL → `bin` → `{path, bytes, contentType}` | `BrowserResourceFetchTests`, `BrowserResourceVerbTests` |
| J-23 | `read-network`, `capture-bodies`: absent (Scope): unknown commands, not in `capabilities`/`describe` | `BrowserScriptVerbTests/captureVerbsAreAbsent` |
| J-24 | Every verb refuses a pane its caller doesn't own (H-2), a closed one (H-3), one of another type (`target is not a browser pane`), and one without a page (`browser pane is not currently mounted`): a pane in a never-shown tab; for click/hover/type/key, a page with no window (scroll and form-input work by script) | `BrowserInputVerbTests/inputVerbsRefuseAPaneThatIsNotMounted`, `BrowserNavigationVerbTests/aPaneThatIsNotABrowserIsRefusedByName`, `BrowserNavigationVerbTests/anAgentCanCreateAndControlABrowserPaneItOwnsButNoOther`, `BrowserReadVerbTests/readBackVerbsRefuseAPaneThisCallerDoesNotOwn`, `BrowserInputVerbTests/inputVerbsRefuseAPaneThisCallerDoesNotOwn`, `BrowserScriptVerbTests/scriptingVerbsRefuseAPaneThisCallerDoesNotOwn`, `BrowserResourceVerbTests/readBackVerbsRefuseAPaneThisCallerDoesNotOwn` |
| J-25 | A page that can't run script answers `the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none`, never the engine's plumbing | `BrowserReadVerbTests/aPageThatCannotRunScriptIsOneSentenceNotTheEnginesPlumbing` |
| J-26 | Files: `--out` = a caller-named path (core resolves it against the caller's `cwd`), created exclusively (`O_EXCL`), never overwritten (`refusing to overwrite an existing file: <path>`) or swept; else `<uuid>.<ext>` under the plugin's cache dir (`agent-screenshots`, `agent-resources`, `agent-output`), 10-minute TTL, swept at activation (background) and at most once a minute per subdirectory on write; a write failure is a message, never a throw | `BrowserAgentFilesTests` |
| J-27 | Bytes never ride the socket: screenshots, saved resources and `--out` results are files; answers carry paths | `UITests.BrowserControlUITests/anAgentCanReadBackAPaneItOwnsInfoTextAndARealPNGOnDisk`, `BrowserScriptVerbTests/executeJsOutWritesTheFullResultToAFileInsteadOfTruncating` |

## Look

Sizes in pt; colors are core's `PaneTheme` tokens. The header (padding, gap 8, 24 tall, depth
shade, hover-revealed controls) is core's; the browser owns its title slot
(`PaneHeaderTitleView`), laid out from `PaneHeaderSlot.fractionalOffset`.

| Id | Element | Box | Text | Colors | States | Scenario |
|---|---|---|---|---|---|---|
| L-1 | Nav button (Back, Forward, Refresh) | padding 2 × 5 → 23 × 17, radius 3; icon 13 × 13 (16-unit box; stroke 1.4 back/forward, 1.2 refresh; round caps) | — | icon `textDim`; hover wash `hover` at 0.12 | hover; disabled at opacity 0.35, no wash, arrow cursor (pointing hand while enabled) | `browser-default`, `browser-hover-back`, `browser-hover-refresh`, `browser-hover-disabled`, `browser-history` |
| L-2 | Address bar | fills the rest of the slot (may shrink to 0), height 20, 1pt border, radius 3, clips its content | — | `border`; `accent` while the input has focus | focused | `browser-default`, `browser-address-focus` |
| L-3 | Title segment | sized to its text, at most 30% of the bar, padding 2 × 6, 1pt `border` at its right; absent without a title | 12, line height 16, one line, ellipsis | `textDim` on `bgElevated` | snug, capped, none | `browser-short-title`, `browser-long-title`, `browser-no-title` |
| L-4 | Address input | the rest of the bar, full height, padding 2 × 6, no border or focus ring | 12, `textDim` (the header's) | `bg` | text, focus | `browser-default`, `browser-address-focus` |
| L-5 | The page | fills the body | — | fixture page: solid color; unpainted page white (`underPageBackgroundColor`) | loaded, blank | `browser-default`, `browser-blank` |
| L-6 | Controlled pane | core's signal outline + robot (PANE-SIGNALS.md) | — | `agent` | pulsing | `browser-controlled` (as `signal-controlled`) |
| L-7 | Both themes | every element above | — | dark and light tokens | — | `browser-light`, `browser-empty-toolbar-light` |
| L-8 | Creation icon | 16 × 16 globe: circle r 6 stroke 1, equator + meridian stroke 0.9 | — | template image | hover | `browser-empty-toolbar`, `browser-empty-toolbar-hover` |

Tests: `BrowserPaneTests/laysOutTheButtonsAndTheBarInOneRow` (L-1…L-4),
`BrowserPaneTests/aButtonWashesOnHoverAndDimsWhenDisabled`, `BrowserPaneTests/theGlyphsDrawInsideTheirBoxes`
(L-1, L-8), `BrowserPaneTests/theBarsCornersAreRounded` (L-2),
`BrowserPaneTests/theInputsTextLineIsCenteredInItsContentBox` (L-4),
`BrowserPaneTests/paintsTheBarInTheThemesColorsInBothThemes` (L-3, L-4, L-7),
`GeometryGoldenTests/theGeometryMatchesTheGolden`.

- Painted edges snap to a whole point, round half up (`snap`); text sits on a whole-point
  baseline in a line box of rounded ascent + rounded descent (`BrowserText`).
- The bar draws the unfocused address itself; the `NSTextField` shows (alpha 1) only while
  editing.

## Implementation notes

- **The page is an in-process `WKWebView`** in the pane's body: a move keeps it (E-1…E-6), and
  core's event monitors see presses and chords in it (D-1, D-5).
- **Input is `NSEvent`s sent to the web view.** Measured in a never-shown window: clicks and
  keys arrive trusted (`isTrusted`). A move is no responder message (`WKWebView` hears moves
  through its tracking areas): it goes in through `_simulateMouseMove:` (WebKit's SPI for its
  tests) and arrives trusted, hovering, **in the key window only**: WebKit turns a button-less
  move in a page whose window isn't key into a scrollbar update (`WebFrame::handleMouseEvent`),
  and nothing turns that off, so `hover` fails there (J-13). Tests make a never-shown window key
  as WebKit's own do (`KeyableWindow`). Don't fake a move with `mouseEntered`: that hung the
  process. Keys need the web view as first responder (`withHostFocusRestored` gives it back).
  Input is queued (WebKit hands the page each key only once it acknowledged the one before):
  `PageInput.settle` waits on the page's `InputAcknowledgement` counters for as long as they keep
  moving, giving up once nothing new is acknowledged for 0.5 s, so a read right after sees the
  effect; a fixed half second answered a long `type` with most of it still queued
  (`BrowserInputTests/aPageSlowToTakeEachKeyHasThemAllWhenTypingAnswers`). A read of the
  counters gets 2 s: a page busy in a script of its own can't say
  (`…/aCountsReadGivesUpOnABusyPageAtItsTimeout`).
- **Scripts and snapshots** are `callAsyncJavaScript` and `takeSnapshot`; both work in a hidden
  window, and a script's error comes back to the caller.
- **A pending script is never settled with a value across a navigation**: usually it isn't
  answered at all; on a busy machine WebKit sometimes answers it with an error. `PageWait` races
  every injection against `PageEvents`, re-injecting into the new document
  (`BrowserPolicyTests/anEvaluationAwaitingAPromiseNeverSettlesWhenThePageNavigatesAway`); every
  other script call goes through `BrowserPage.call` (`evaluate`, the input counters, a blob
  fetch), which answers unavailable at the navigation, or when its task is cancelled, instead of
  never (`BrowserNavigationTests/aScriptCallANavigationOrphansAnswersUnavailable`,
  `…/aCancelledScriptCallAnswersUnavailable`). A read of the input counters that went around it
  hung an Enter that submits a form for good.
- **Console capture is injected.** The `console.*` wrapper runs in the page's own world (each
  world has its own `console`); the error listener runs in a private world (error events reach
  every world, and the page can't remove it). A `console.*` entry's source URL and line come
  from the wrapper's own stack (the caller's frame is in it); an uncaught error's from its event
  (C-3).
- **The error page is a `tabs-error:` document** served by a scheme handler, loaded as a
  navigation so it is a real history entry. `loadHTMLString(…, baseURL: failedURL)` replaces
  the current entry (measured), losing the previous page's Back target.
- **`save-resource`'s blob route** is a `fetch` in a private `WKContentWorld`, which the page's
  CSP doesn't bind (measured against `connect-src 'self'`). **The http(s) route** is an
  ephemeral `URLSession` carrying the page store's cookies.
- **Network capture**: none (J-23).
- **`upgrade-insecure-requests` on loopback** (C-10) is undone by a content rule list redirecting
  `https` loopback requests to `http`. WebKit upgrades loopback on purpose
  (`ShouldUpgradeLocalhostAndIPAddress::Yes`) with no setting against it, and a response header
  can't be edited (a rule list's `modify-headers` never applies to responses). A list's
  `redirect` runs only for URLs `_activeContentRuleListActionPatterns` grants: SPI, set on the
  configuration's `defaultWebpagePreferences`, without which the rules are no-ops and the upgrade
  stands (all measured).

## Checking the look

The 20 scenarios `Plugins/Browser/Visual/scenarios/browser-*.json` cover the chrome:
`browser-default`, `browser-blank`, `browser-history`, `browser-history-both`,
`browser-hover-back`, `browser-hover-refresh`, `browser-hover-disabled`,
`browser-address-focus`, `browser-short-title`, `browser-long-title`, `browser-no-title`,
`browser-narrow`, `browser-split`, `browser-nested`, `browser-floating`, `browser-controlled`,
`browser-light`, and the creation action in `browser-empty-toolbar`,
`browser-empty-toolbar-hover`, `browser-empty-toolbar-light` (`creationActions: ["browser"]`).
The scenario format and the capture's plugin hooks: `Visual/README.md`.

A browser leaf's config is `{url: "about:blank"}`; its `content` entry:

`{"page": "#2b3a55", "address"?: string, "title"?: string, "canGoBack"?: bool, "canGoForward"?: bool, "focusAddress"?: bool}`

- `page`: the stand-in page's solid CSS color. Page text is never compared.
- `address`: what the address bar shows (default `about:blank`); `title`: the page's title, in the
  title segment (absent without one).
- `canGoBack`/`canGoForward` (default false): history flags → Back/Forward enabled.
- `focusAddress`: address field focused without the pointer (first responder, a hidden caret at the
  start).
- Hover: `pointer`; controlled cue: `signals`.

Staging (`browser.test.stage`): the real `WKWebView`, nothing fetched.

- Pages are fixture files in the plugin's scratch directory, loaded for real so Back/Forward are
  real history: `#3a3a3a` "Previous"/"Next" fixtures around the page, Forward via
  `history.back()`. Not `loadHTMLString` (WebKit replaces the entry), not an unclicked
  `pushState` (adds none).
- The bar then shows `address`, and no title where `title` is absent (a title-less page gets a
  URL-derived one). The staging fails unless the chrome shows exactly this: button states, address,
  title, focus.
- Pixels (`browser.test.snapshot`): `WKWebView` draws out of process, so the page's `takeSnapshot`
  (2x) stands in for the view's layer while the tree renders; the cue glow and frame composite
  over it.
- Nav-button hover: a synthesized `mouseEntered` to the header view under the pointer (a
  never-shown window has no tracking).

Geometry (`browser.test.visual`, in the header title view's coordinates, offset to the window):
`content.<leaf id>`. The header is `panes.<leaf>.header`; a controlled pane's cue icon is in
`panes.<leaf>.signalIcons`.

```jsonc
"content": {
  "<leaf id>": {
    "page": R,                        // the WKWebView's frame = the pane body
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

- `Plugins/Browser/Visual/golden/<name>.geometry.json` are recorded from the app (`make
  visual-golden` re-records them after an intended change);
  `GeometryGoldenTests/theGeometryMatchesTheGolden` holds every scenario to its golden within
  0.5 pt, and `GeometryGoldenTests/everyScenarioHasAGolden` requires one per scenario.
- Pixels: `make visual-baseline` captures the scenarios with the build before a change; `make
  visual` (`ONLY=` scenario names) captures them with the current build and compares pixels and
  geometry (`build/visual/compare/index.html`).

## Notes

Each measured on WebKit or decided.

- **No `read-network` / `capture-bodies`** (Scope, J-23): `WKWebView` has no request observation.
- **The guide** (`Control/guide.md`) states WebKit's behavior where it matters (error pages,
  accessible names, editing chords), measured, and has no network section.
- **Titles**: the document's, else a URL stand-in; an error page's is the failed host. The
  HTTP status text comes from a standard table (`HTTPStatusText`): WebKit exposes none.
- **Load failures**: the error page is a `tabs-error:` document, so history, `url` and
  `config.url` follow it like any page; `ERR_*` names are mapped from `NSError` (unmapped:
  `ERR_FAILED`). Refresh on an error page loads the failed URL as a new entry; a history step
  onto a failed entry reports its recorded failure without retrying (J-3).
- **A superseded navigation** raises no event: `navigate` waits out the replacement and answers
  `loaded: true`; `redirected` says the pane went elsewhere (J-2). A load asked for is loading
  from the asking (`BrowserPage.requested`, `isLoading`): WebKit can drop its loading flag as it
  cancels the load superseded, before the new one starts. A load that only moves the fragment
  of the document on screen starts no navigation at all (measured): it ends as the loading flag
  drops (`BrowserNavigationTests/aLoadOfANewFragmentEnds`).
- **A script redirect while the page loads** lets the load finish first: `navigate` and
  `create-browser-pane` watch 150 ms past the load's end for a navigation the page starts, and
  follow it (`waitForLoadSettle`). That also catches a timer redirect within those 150 ms; a
  later one comes after the answer. A failure anywhere in the settle is the answer, one that
  fails at once (a refused connection) too: with the main actor busy it can come before the
  settle's next wait listens, and its error page then loads like any page.
- **The starting `about:blank` is never loaded**, so it can't be a Back entry; `about:blank`
  typed on a never-loaded pane is a no-op (B-3). A verb waiting on it (`create-browser-pane
  --url about:blank`, `reload`, `navigate --url about:blank` on a fresh pane) answers at once:
  nothing is loading, and there is no document to start a load (`BrowserPage.isOnStartingBlank`).
  Any other wait for a load ending looks at the loading flag a beat late, not at once: a
  same-document history step never raises it, and an answer at once would come before its URL
  moved.
- **Viewport**: WebKit rounds a fractional pane width down (J-6).
- **`upgrade-insecure-requests` on loopback** (C-10): a redirect undoes WebKit's upgrade, so on
  an exempted page a request the page itself makes for `https://localhost` goes over http too.
  Still upgraded (measured): a `ws:` WebSocket (no rule redirects its handshake), and every URL
  of a page whose directive comes in a `<meta>` tag (only headers reach the response decision).
- **`hover`** fails in a window that isn't key (J-13, Implementation notes).
- **Editing chords**: a synthesized ⌘A reaches the page as a `keydown` but not the editing
  layer; the responder chain's `selectAll:` and `execCommand` do. Hence `key`'s `note` and
  `--command` (J-15).
- **Undo** undoes a run of typing as one step.
- **A pane in a never-shown tab** has no page (its body is built on first show): verbs answer
  "not currently mounted". Agent-created panes are always shown first (J-24).
- **`save-resource`**: one blob route, which also reads a blob minted but never loaded behind a
  strict CSP; the http(s) route sends the page's User-Agent, writes response cookies back,
  refuses redirects off http(s). Scripts run on an error page, and a PDF is an `<embed>`.
- **`tabs-ctl`** settles on the response's first newline (the server keeps connections open),
  decodes the whole line at once (a multi-byte character can span reads), and writes all of it
  before exiting, however small the pipe's buffer.
- **App Transport Security**: the app's `Info.plist` sets `NSAllowsArbitraryLoads`; without it
  plain `http://` to anything but localhost fails (-1022), page loads and `save-resource`
  alike.
- **No downloads and no JavaScript `alert`/`confirm`/`prompt`**: no download delegate, no
  `WKUIDelegate` panel methods. Untested.
- **Control plane**: any attached pane may call, of any type, an exited terminal's too (H-1); a
  request without a `paneId` answers `not running inside a Tabs pane`; with `activates: false`
  the pane still becomes the window's active pane, only the keyboard is withheld, once; a
  tombstone is recorded on any close, the user's included; a relative `path` in a `batch` step
  resolves against the request's `cwd`.
- **`create-browser-pane`**: any refused placement answers the "turned off" message (core's
  `openPane` answers nil for both).
- **Skill install**: the bundle is found at `Resources/skills/tabs` only (no repo-directory
  dev path); Uninstall removes any symlink at the destination, and a dangling link (the app
  moved) can't be reinstalled over.
