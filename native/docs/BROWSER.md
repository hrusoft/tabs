# Browser

A web page in a pane: Back / Forward / Refresh and an address bar in the header, plus 20
`tabs-ctl` verbs to open, read and drive it from an agent's terminal pane, on core's control
plane. Port of Electron's `packages/plugin-browser` (a `<webview>` guest) on `WKWebView`;
plugin `Plugins/Browser` (id and content type `browser`), SDK only.

## Scope

- **Every verb and the control plane they need** (ledger, `batch`, `capabilities`/`describe`,
  `controlled` signal, placement setting, `tabs-ctl` + skill). `tabs-ctl` and `SKILL.md` are
  the one shared copy, `resources/skills/tabs`, bundled unchanged.
- **No `read-network` / `capture-bodies`**: `WKWebView` has no request-observation API
  (Electron: `session.webRequest` + CDP), and a proxy can't see inside https. Absent entirely:
  unknown commands, not in `capabilities`/`describe`, no network section in the guide. Nothing
  only they use (`networkLog`, `networkBodyCapture`, `guestDebugger`) is ported. Don't re-add.
- **Look**: the chrome (buttons, address bar, title segment, frame) is compared exactly; page
  text never (engine-specific). Fixture pages are text-free solid colors.
- **Public WebKit API only.** Web data lives in
  `WKWebsiteDataStore(forIdentifier: context.webDataStoreIdentifier)`; never `.default()`
  (shared with other plugins; `Scripts/lint-plugin-boundaries.py` refuses it). Cookies and
  storage persist across launches.
- **A moved pane keeps its page** (an AppKit view keeps its state). Electron's reload
  machinery (`browserRegistry`'s reattach + grace period, `guestReport`, `focusGuest`
  deferral, guest-id ledger, re-report on `did-attach`) is not needed; don't port it.
  `pageInstance` is stable for the page object's life.

## Sources

Paths under `Plugins/Browser/Sources/` unless rooted; Electron under `packages/plugin-browser/`.

| Native | Electron | What |
|---|---|---|
| `Plugins/Browser/Info.plist` (`TabsPlugin`), `plugin.yml` | `shared/manifest.ts` | Identity: `browser`, "Browser", `canDisable`, `sortOrder` 6 |
| `BrowserPlugin.swift` | `renderer/browserContentDef.ts`, `main/index.ts`, `settings/index.ts` | Activation: content type ("New browser"; seed or copy of the origin browser's config), settings page, verbs; `BrowserServices` (live panes, `openExternal`, `AgentFiles`); launch sweep |
| `Model/AddressInput.swift` | `renderer/addressInput.ts` | `resolveAddressInput` |
| `Model/UrlPolicy.swift` | `main/urlPolicy.ts`, `packages/plugin-sdk/shared/url.ts` | `isAllowedUrl` (steer-to), `isAllowedResourceUrl` (read-from), `isSafeExternalUrl` (OS-open) |
| `Model/UrlComparison.swift` | `shared/urlComparison.ts` | `isTrivialUrlChange` (`redirected`) |
| `Model/BrowserSettings.swift` | `shared/settings.ts` | `NewPanePlacement`, `resolveNewPanePlacement`, total decoder |
| `Model/AriaRoles.swift` | `shared/ariaRoles.ts` | `roleFilterError` |
| `Model/Limits.swift` | `shared/externalControl.ts`, `shared/pageRefs.ts` | `BrowserLimits` (caps, waits, ref-registry globals), `clampWaitTimeout`/`clampWaitPoll`, stale-ref and not-mounted messages |
| `Model/FindElements.swift` | `renderer/findElements.ts` | `scoreElement`, `findElements` |
| `Model/Keystrokes.swift` | `renderer/keystrokes.ts` | Events per keystroke; `USKeyboard` (DOM key → macOS key code) |
| `Model/RingLog.swift` | `packages/plugin-sdk/shared/ringLog.ts` | Console ring, `compilePattern`, `patternFilterError` (plugin-private) |
| `Model/PageTypes.swift` | `shared/externalControl.ts` | Element targets, `KeyModifier`, `EditingCommand` |
| `Page/BrowserPage.swift` | `renderer/BrowserRenderer.tsx` (events), `browserRegistry.ts`, `browserControl.ts` | The `WKWebView` (`BrowserWebView`), delegates + KVO, committed URL, status, load failure, console, history, the starting-blank rule, script evaluation, viewport, snapshot |
| `Page/PageEvents.swift` | `<webview>` events | `did-*` equivalents for the waits |
| `Page/ConsoleCapture.swift` | `onConsoleMessage` | Document-start console wrapper + error listener; `InputAcknowledgement` |
| `Page/ErrorPage.swift`, `Page/LoadErrors.swift` | Chromium error page, `mainFrameLoadError` | `tabs-error:` error document; `NSError` → `ERR_*` |
| `Page/PageValues.swift` | `browserRegistry.ts` | `DocumentStatus`, `ConsoleEntry`, `PageScriptError`, `HTTPStatusText`, `fallbackTitle` |
| `Page/PageScripts.swift`, `Page/WaitScripts.swift` | `renderer/pageScripts.ts`, `waitScripts.ts` | Guest JS, kept verbatim (standard DOM): refs, roles/names, visibility, hit test, fill, scroll, waits |
| `Page/PageInput.swift` | `renderer/inputVerbs.ts`, `targeting.ts` (`clickAt`), `withHostFocusRestored` | Trusted `NSEvent` input, input acknowledgement, host-focus restore |
| `Page/PageWait.swift` | `renderer/pageWait.ts` | Navigation-surviving wait supervisor |
| `UI/BrowserPane.swift` | `renderer/BrowserRenderer.tsx` (focus), `BrowserHeaderTitle.tsx` (state) | `PaneController`: config, title, focus, `list-panes`/`pane-info` fields |
| `UI/BrowserToolbar.swift`, `UI/BrowserStyle.swift` | `renderer/BrowserHeaderTitle.tsx`, `browser.css` | Header title slot: three buttons, address bar + title segment; metrics, Chromium text/snap |
| `UI/BrowserGlyphs.swift` | `renderer/browserIcons.tsx` | Globe, back, forward, refresh |
| `UI/BrowserSettingsPage.swift` | `settings/BrowserSettingsPage.tsx` | The one picker |
| `Control/BrowserVerbs.swift` + `Navigation*`, `Read*`, `Input*`, `TargetingInput`, `ScriptVerbs`, `WaitVerbs`, `Resource*`, `VerbSupport` | `shared/controlSpec.ts`, `main/browserExternalControl.ts`, `renderer/{navigation,read,input,script,wait}Verbs.ts`, `verbSupport.ts`, `targeting.ts` | The 20 verbs: specs, budgets, handlers; capability (guide + limits) |
| `Control/ResourceFetch.swift` | `main/resourceFetch.ts` | `save-resource` routes: data, http(s), blob |
| `Control/AgentFiles.swift` | `main/agentFiles.ts` | File sink: `--out`, generated paths, sweep |
| `Control/guide.md` | `shared/guide.md` | Guide `describe` serves: copy without the network section, WebKit corrections |
| `BrowserTestVerbs.swift` (Debug) | `testing/fakeApi.ts`, `testing/visualCapture.ts` | `browser.test.*` verbs for UI/e2e/visual |
| **SDK** `ControlVerbContribution` (`command`, `wireType`, `batchable`, `timeoutFor`, `resultShape`, `.elementTarget`, `.ownedPane`), `ControlCapabilityContribution`, `ControlInvocation.pane(as:)`; `PaneController.controlSummary`/`controlDescription()`; `PaneRequest(activates:controlledBy:)`, `Workspace.revealPane`; `PluginContext.webDataStoreIdentifier` | `packages/plugin-sdk/shared/content/controlSpec.ts`, `main/controlVerbTable.ts`, `renderer/controlVerbTable.ts`; manifest `controlVerbs`/`guide`/`limits` | Plugin side of the control plane |
| **Core** `Sources/TabsCore/Control/`: `ControlPlane` (dispatch order, core verbs, `batch`, `capabilities`/`describe`), `ControlEnvelope` + `ControlFlags`, `ControlSchema`, `ControlServer`, `PaneOwnership` | `src/main/externalControl.ts`, `controlEnvelope.ts`, `controlVerbs.ts`, `controlDescribe.ts`, `controlSocket.ts` | Everything about a verb that names no page |
| **Core** `Panes/ControlledSignal.swift` | `core/store/controlStore.ts`, `.pane-controlled` | `controlled` signal: grant → raise, close → withdraw |
| **Core** `Skills/SkillInstaller.swift`, `Sources/Tabs/UI/AiSettingsPage.swift`; `project.yml` bundles `../resources/skills` | `src/main/skills.ts`, Settings AI tab, `electron-builder.yml` `extraResources` | Skill install per agent |
| **Core** `PaneRuntime.childEnvironment` | terminal env | `TABS_PANE_ID`, `TABS_CONTROL_SOCKET` |

## Cases

Tests: `Plugins/Browser/Tests` = unhosted, real core; `UITests.*` = the real shell, windows
never shown; `*EndToEndTests` = the running app driven by the real `tabs-ctl` (needs Node).
Pages come from a loopback `FixtureServer` (`Tests/Support`).

### Creating and restoring

| Id | Case | Electron | Native test |
|---|---|---|---|
| A-1 | Creation action "New browser" with the globe (empty pane's button, ⌘P palette, new tab/split "like" a browser); the palette lists the display name "Browser" | `browserContentDef` (`createAction`) | `BrowserPluginTests/theCreationActionIsNewBrowserSeededToAboutBlank`, `UITests.BrowserUITests/theCreationActionsOfferNewBrowser` |
| A-2 | Seed config `{url: "about:blank"}`; a pane made from a browser copies its config as-is; from any other type, the seed (no `deriveConfig`/`exposeCwd`: no directory) | `browserContentDef` | `BrowserPluginTests/aCopyOfABrowserStartsWhereTheOriginalIs`, `UITests.BrowserUITests/aNewTabOrSplitLikeABrowserStartsWhereItIs` |
| A-3 | New pane starts blank: address bar `about:blank`, no title segment | `browserContentDef`, `BrowserHeaderTitle` | `BrowserPluginTests/aNewPanesAddressBarReadsAboutBlank` |
| A-4 | Restored, duplicated or relaunched pane loads its saved `config.url` (the current page, not the seed); unknown config keys kept | `BrowserRenderer` (`webview.src = config.url`) | `BrowserPluginTests/aRestoredPaneLoadsItsSavedURL`, `BrowserEndToEndTests/thePageAPaneWasOnSurvivesARelaunch` |
| A-5 | `config.url` follows every committed document: navigation, in-page (pushState, hash), a failed load's error page (the failed URL) | `onDocumentCommitted`, `onDidNavigateInPage` | `BrowserPluginTests/theConfigFollowsEveryNavigation` |
| A-6 | Unreadable saved config (not an object; `url` not a string) → pane refused (core keeps it verbatim, unavailable, with the error); missing/null `url` → `about:blank` | — (native contract) | `BrowserPluginTests/aSavedConfigItCannotReadRefusesThePane`, `BrowserPluginTests/aMissingURLTakesTheDefault` |
| A-7 | Can be disabled: creation actions and settings page go, open panes keep running (core's gate, NEW-CONTENT.md D-3); `create-browser-pane` refused (J-1) | `enablement.ts` | `BrowserNavigationVerbTests/createBrowserPaneIsRefusedWhileTheBrowserContentTypeIsTurnedOff` |
| A-8 | No close warning; closing ends the page (`paneWillClose` → `BrowserPage.destroy`) | `closeBlockers.ts` | `BrowserPluginTests/hasNoCloseWarningAndClosingEndsThePage` |

### The header: navigation and address bar

| Id | Case | Electron | Native test |
|---|---|---|---|
| B-1 | Header title slot = nav chrome: Back, Forward, Refresh, then the address bar filling the rest; no title text, no Edit title; the body is the page only | `BrowserHeaderTitle` | `UITests.BrowserUITests/aNewBrowserIsABlankPageWithNavChromeInItsHeader` |
| B-2 | Back/Forward disabled with nowhere to go (fresh pane: both); follow history after every navigation, in-page included | `BrowserHeaderTitle` `sync` | `UITests.BrowserUITests/backAndForwardFollowNavigationHistoryAndStepIt` |
| B-3 | The pane's starting `about:blank` is never a Back target; a later, deliberate `about:blank` keeps its history. Native: the starting blank is never loaded (on WebKit an explicit `about:blank` load *is* a Back entry); `about:blank` typed on a never-loaded pane is a no-op | `atInitialBlank` + `clearHistory` | `BrowserNavigationTests/theStartingBlankIsNotABackTarget`, `BrowserNavigationTests/aDeliberateAboutBlankKeepsItsHistory` |
| B-4 | Back / Forward / Refresh step history / reload; nothing to step to → nothing | `goBack`, `goForward`, `reload` | `BrowserNavigationTests/historyStepsWithNothingToStepToDoNothing`, `UITests.BrowserUITests/refreshReloadsThePage` |
| B-5 | Tooltip and accessibility label per button ("Back", "Forward", "Refresh"), disabled too; ids `browser-back-button`, `browser-forward-button`, `browser-refresh-button`. **Deviation:** AppKit's tooltip, not Electron's bubble (core has no plugin-usable chrome tooltip) | `HeaderButton` | `UITests.BrowserUITests/theButtonsCarryATooltipNamingWhatTheyDoDisabledOrNot` |
| B-6 | Address bar shows the committed URL (else the seed), follows navigations, except while focused: a background navigation never replaces typed text; unsent text stays until the next navigation | `sync` (`document.activeElement`) | `BrowserPaneTests/theBarFollowsThePageButNeverTypedText`, `UITests.BrowserUITests/aBackgroundNavigationNeverReplacesTextBeingTyped` |
| B-7 | Return → `resolveAddressInput(text)`, then the field resigns focus; blank → nothing | `onKeyDown` Enter | `UITests.BrowserUITests/typingAURLAndPressingReturnNavigates`, `UITests.BrowserUITests/aBlankFieldDoesNothingOnReturn` |
| B-8 | Input rules: trimmed; blank → nil; bare domain checked first (`localhost[:port][/…]`, or a dot before the first slash and no whitespace) → `https://…`, so `localhost:3000` isn't a scheme; schemed URL unchanged; else `https://www.google.com/search?q=<encodeURIComponent>` | `resolveAddressInput` | `AddressInputTests` |
| B-9 | Title segment: the live title, only when non-empty; `max-width: 30%`, ellipsized, full title as tooltip (id `browser-title-segment`); `--bg-elevated` vs the input's `--bg` | `.browser-title-segment` | `UITests.BrowserUITests/aLongPageTitleIsCappedAtThirtyPercentOfTheBarAndKeepsItsFullTextForHover` |
| B-10 | Bar border `--accent` while the field has focus | `.browser-address-bar:focus-within` | `UITests.BrowserUITests/theBarsBorderTurnsAccentWhileTheFieldHasFocus` |
| B-11 | A press on a button or the field activates the pane without a pane drag (buttons fire on mouse-up inside, never disabled); a press on the title segment drags the pane like the rest of the bar | `BrowserHeaderTitle` | `UITests.BrowserUITests/aPressOnANavButtonActivatesThePaneWithoutStartingADrag`, `UITests.BrowserUITests/aPressOnTheTitleSegmentDragsThePaneLikeTheRestOfTheBar` |
| B-12 | Activating from the header doesn't move the keyboard onto the page (`BrowserPane.focusIsInChrome`) | `focusGuest` guard (`focusIsInPaneChrome`) | `UITests.BrowserUITests/activatingFromTheHeaderDoesNotMoveTheKeyboardOntoThePage` |

### The page

| Id | Case | Electron | Native test |
|---|---|---|---|
| C-1 | Page title → the pane's live title (title segment; a manual rename wins). No document title → Chromium's URL stand-in (`fallbackTitle`: `http://` dropped, a `file:` name, else the URL; none for `about:blank`, pane title "Browser"); an error page's title is the failed host | `onTitleUpdated` → `setLiveTitle` | `BrowserNavigationTests/theTitleFollowsThePageWithChromiumsStandInForAPageWithoutOne`, `BrowserNavigationTests/theFallbackTitleIsChromiumsForEachKindOfURL` |
| C-2 | A committed main-frame document clears the console, on commit (before its scripts run); an in-page navigation doesn't | `onDocumentCommitted` | `BrowserNavigationTests/aNewDocumentClearsTheConsoleBeforeItsOwnScriptsRun` |
| C-3 | Console capture: `console.log/info/debug/warn/error` (levels `info`/`info`/`verbose`/`warning`/`error`) with `%s %d %i %f %o %O %c %%` applied, uncaught errors and unhandled rejections, frames included; 200-entry ring, stable seq; survives moves; a page can't silence it; each entry carries the source URL and line of the call (of the throw, for an uncaught error), when the page has them | `onConsoleMessage`, `createConsoleLog` | `BrowserConsoleTests` |
| C-4 | Failure of the load in flight (main frame; not aborted/−3, i.e. not `NSURLErrorCancelled` or WebKit 102) recorded as an `ERR_*` name from the moment the page exists, so one before anything listens is known; cleared when the next load starts; a superseded navigation is no failure | `onDidFailLoad`, `mainFrameLoadError` | `BrowserFailureTests/aFailureThatLandsBeforeAnythingListensIsKnown`, `BrowserFailureTests/theNextLoadForgetsTheRecordedFailure` |
| C-5 | A failed main-frame load is a commit: the error page is a real history entry at the failed URL; `config.url` = failed URL; previous status and console dropped | `onDidFailLoad` → `onDocumentCommitted` | `BrowserFailureTests/theErrorPageIsARealHistoryEntry` |
| C-6 | HTTP status + text of the last committed main-frame document (≥ 100); none for non-HTTP (`about:blank`) or an error page; an in-page navigation carries it forward; a history step keeps its entry's | `onDidFrameNavigate` | `BrowserNavigationTests/recordsTheStatusOfTheCommittedDocument`, `BrowserNavigationTests/anInPageNavigationCarriesTheStatusForwardAndAHistoryStepKeepsTheEntrys` |
| C-7 | `pane-info` fields: `url`, `title`, `isLoading`, `canGoBack`, `canGoForward`, `pageInstance`, `showingErrorPage` + `loadError` only on an error page, `viewport` (the page's own `innerWidth × innerHeight`; a page too busy to answer in 500 ms → the view's size) or `hidden: true` for a pane not on screen: never an invented viewport | `describeForControl` | `BrowserControlPaneTests/paneInfoReportsTheLivePageAndFlagsAnErrorPage`, `BrowserControlPaneTests/paneInfoRefusesToInventAViewportForAPaneThatIsNotShown` |
| C-8 | `list-panes` summary: `{paneId, type, title, url}`; `url` from the config (works unmounted) | `listSummaryForControl` | `BrowserControlPaneTests/listPanesReportsTheUrlThePaneWouldBeSavedWith` |
| C-9 | The page's own history (`canGoBack`/`canGoForward`) drives the buttons and the verbs | `webview.canGoBack` | `BrowserNavigationTests/canGoBackAndForwardAreThePagesOwnHistory` |

### Input, focus and activation

| Id | Case | Electron | Native test |
|---|---|---|---|
| D-1 | A press in an inactive pane's page activates it: any mouse-down (right-click, scrollbar drag included), never a scroll. Native: core's click monitor (`WorkspaceInput`) | `guestActivation.ts` | `UITests.BrowserUITests/aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage`, `UITests.BrowserUITests/aRightClickActivatesThePaneAndShowsNoContextMenu` |
| D-2 | The activating click still lands in the page (typing then reaches the clicked field; `acceptsFirstMouse`) | `guestActivation.ts` | `UITests.BrowserUITests/aClickInsideAnInactivePanesPageActivatesItAndStillLandsInThePage` |
| D-3 | App-injected input never activates the pane. **n/a:** injected `NSEvent`s go straight to the web view, past the app's monitors (Electron needs the `suppressGuestActivation` counter and its 50 ms tail) | `suppressGuestActivation` | `UITests.BrowserInputUITests/aPersonsClickInAnInactivePanesPageActivatesItWhereTheAgentsDoesNot` |
| D-4 | Activation gives the page the keyboard, unless focus is in the pane's own header; deferred until the pane is in a window. Native: core moves the first responder, no separate blur | `focusGuest`, handle `blur` | `UITests.BrowserUITests/activatingAPaneGivesItsPageTheKeyboard` |
| D-5 | Pane-navigation chords (⌘+arrow, as bound) in a focused page move pane focus and never reach the page. Native: core's keyDown monitor (`WorkspaceInput`) | `guestNavKeys.ts` | `UITests.BrowserUITests/aNavChordPressedInAFocusedPageEscapesItWithoutReachingThePage` |
| D-6 | Every app shortcut (`PaneContext.isAppShortcut`) reaches the app from a focused page (`BrowserWebView.performKeyEquivalent`); other keys stay the page's | — (native contract) | `UITests.BrowserUITests/everyAppShortcutIsLeftToTheAppByAFocusedPage` |
| D-7 | A verb's input never leaves host focus moved, a page's `el.focus()` included; a window where nothing had the keyboard is left so. Native: `PageInput.withHostFocusRestored`, which also restores the field caret WebKit resets | `withHostFocusRestored` | `BrowserInputTests/drivingThePageNeverStealsKeyboardFocusFromWhereItWas`, `UITests.BrowserInputUITests/drivingAPaneNeverStealsKeyboardFocusFromTheTerminal` |
| D-8 | The command palette takes the keyboard from a focused page (NEW-CONTENT.md P-5/P-6; a text view stands in for a live page) | `CommandPalette` focus effect | `UITests.PaletteTests/itTakesTheKeyboardFromAPaneThatHadIt` |
| D-9 | Copy, paste, select all, undo follow the responder chain (Edit menu); undo/redo are the pane's own `UndoManager` (a window's is shared by its tabs, and a pane can move) | menu roles | `BrowserInputTests/undoAndRedoAreThePanesOwn`, `UITests.BrowserUITests/theEditMenusActionsReachTheFocusedPage` |
| D-10 | No context menu of the page's own (as Electron's `<webview>`); a right-click activates the pane | `<webview>` default | `BrowserPolicyTests/thePageHasNoContextMenu` |

### The pane in the layout

| Id | Case | Electron | Native test |
|---|---|---|---|
| E-1 | Moving the pane (tab to another group, split, float, unpin, another window) keeps its page: history, scroll, form state, console, refs. **Deviation:** Electron reloads at the same URL (Scope) | `browserRegistry.ts` | `UITests.BrowserUITests/aMovedPaneKeepsItsPage` |
| E-2 | Splitting or closing a sibling never remounts an existing browser pane | `SplitRenderer` (unkeyed) | `BrowserPlacementEndToEndTests/creatingAndClosingSplitPlacedPanesLeavesAnExistingBrowserPaneUntouched` |
| E-3 | A pane drag over a browser pane previews and drops there; the page never eats a drag begun elsewhere | `.pointer-gesture .browser-webview` | `UITests.BrowserUITests/aPressOnTheTitleSegmentDragsThePaneLikeTheRestOfTheBar` (docks onto a browser pane) |
| E-4 | Verbs follow the pane across windows: an agent keeps driving and listing it | `windowHoldingPane` | `BrowserControlPaneTests/anAgentKeepsDrivingAndListingItsPaneAfterTheUserDragsThatPaneIntoAnotherWindow` |
| E-5 | A hidden pane (background tab) keeps its page running; revealed, never activated, to be captured | `revealPane` | `BrowserControlPaneTests/aBackgroundedPaneKeepsItsPageRunningAndAnswersTheReadVerbs` |
| E-6 | `pageInstance` changes only when the page is re-created (relaunch). **Deviation:** a move doesn't change it | `pageInstanceOf` | `BrowserNavigationTests/pageInstanceIsStableForAsLongAsThePageLives` |

### Popups and URL policy

| Id | Case | Electron | Native test |
|---|---|---|---|
| F-1 | `target=_blank` / `window.open` in a user's pane → the OS's browser (`http`, `https`, `mailto` only; `file:`/custom schemes dropped); no app window opens. A main-frame `mailto:` link opens the mail client; the page stays | `setWindowOpenHandler`, `isSafeExternalUrl` | `BrowserPolicyTests/popupsGoToTheOSBrowserForAUsersPane`, `BrowserPolicyTests/aMailLinkOpensTheMailClientAndTheStaysWhereItIs` |
| F-2 | Agent-owned pane: popups (and `mailto:`) denied, no external open | `setWindowOpenHandler` (`isOwnedPane`) | `BrowserPolicyTests/aControlledPanesPopupsAreDenied` |
| F-3 | Owned from the instant the pane exists (before `create-browser-pane` answers): the guards apply to its first load | `BrowserMethod.paneCreated` | `BrowserPolicyTests/theGuardsApplyToAPanesVeryFirstLoad` |
| F-4 | Agent-owned pane: a page-initiated main-frame navigation (`location.href`, a link) outside `http`/`https`/`about:blank` is cancelled (`decidePolicyFor`); a user's pane is unconstrained | `will-navigate` guard, `isAllowedUrl` | `BrowserPolicyTests/aPageCannotSteerAControlledPaneOutsideTheSchemeAllowlist`, `BrowserPolicyTests/aUsersPaneMayGoAnywhereTheEngineCanLoad` |
| F-5 | Verbs refuse a disallowed URL up front (`url not allowed: <url>`), before touching the pane tree | `withAllowedUrl` | `BrowserNavigationVerbTests/aDisallowedURLSchemeIsRejectedWithoutTouchingThePaneTree` |
| F-6 | `isAllowedUrl`: `about:blank`, or `http:`/`https:` with a host; unparseable refused | `urlPolicy.ts` | `UrlPolicyTests/allowsAboutBlankAndTheWebSchemesForNavigation`, `UrlPolicyTests/refusesEverythingElseForNavigation` |
| F-7 | `isAllowedResourceUrl`: `http`, `https`, `blob`, `data`; `file:` and all else refused, re-checked on the URL about to be read (an element's `src` included); an http(s) redirect off http(s) refused | `urlPolicy.ts`, `resourceFetch.ts` | `UrlPolicyTests/refusesFileAndEveryOtherSchemeForReading`, `BrowserResourceVerbTests/aFileURLTakenFromAnElementIsRefusedToo` |
| F-8 | No preload, no host bridge: the page sees only the console handler (`tabsConsole`); error capture and input acknowledgement run in a private content world | `will-attach-webview` | `BrowserPolicyTests/thePageSeesNoHostBridgeButTheConsoleHandler` |

### Settings

| Id | Case | Electron | Native test |
|---|---|---|---|
| G-1 | Settings ▸ Browser: one picker "New pane placement": New tab / Horizontal split / Vertical split / Unpinned window, default New tab; description "Where a browser pane created by an agent (via the tabs skill's createBrowserPane) appears relative to the pane that created it." (id `settings-browser-controlled-pane-placement-select`). The picker's write path isn't drivable in a never-shown window; decoding is tested (G-3) | `BrowserSettingsPage` | `UITests.BrowserUITests/theSettingsPageRenders` |
| G-2 | Only `create-browser-pane` reads it; a browser opened by hand never does | `handleCreateBrowserPane` | `BrowserNavigationVerbTests/aBrowserOpenedByHandNeverReadsThePlacementSetting` |
| G-3 | Stored `controlledPanePlacement` normalized: anything but `tab`/`split-horizontal`/`split-vertical`/`unpinned` reads as `tab`; merged over the defaults, never throws | `resolveNewPanePlacement`, `mergeBrowserSettings` | `BrowserSettingsTests` |
| G-4 | Page id `browser`, title "Browser", globe icon | `browserSettingsPageDef` | `BrowserPluginTests/contributesASettingsPage` |

### The control plane (core)

| Id | Case | Electron | Native test |
|---|---|---|---|
| H-1 | A request is `{command, args, paneId, cwd}`; `paneId` is the **caller's** pane (`TABS_PANE_ID`), never a wire claim; a caller that isn't a live pane host (or sends no `paneId`) → `not running inside a Tabs pane`, before anything else. **Not yet:** any attached pane of any type passes (`ControlPlane.dispatch`: `panes.contentType(of:) != nil`): an exited terminal's, a browser's, a git tree's; Electron: live pty hosts only (`registerPaneHost`); TERMINAL.md T-6 | `dispatchTypedRequest`, `hasPaneHost` | `ControlPlaneTests/aCallerWithNoLivePaneIsRefusedBeforeAnythingElse`, `ControlPlaneEndToEndTests/aSkillOutsideTabsOrInAPaneThatIsNotOneIsRefusedBeforeItCanDoAnything` |
| H-2 | Ownership: a pane a caller created is the caller pane's for the app run (never persisted or expired, survives the user navigating it); a verb naming `targetPaneId` acts only on an owned pane, else `not the owner of this pane`; checked once in core for every verb | `ownerOf`, `grantOwnership` | `ControlPlaneTests/anAgentCreatesAPaneOwnsItAndDrivesItButNoOther`, `ControlPlaneTests/ownershipOutlivesTheUserNavigatingThePaneByHand` |
| H-3 | A pane closed (owner's `close-pane` or the user) answers its owner `target pane no longer exists — it was closed; listOwnedPanes shows the panes still open`; everyone else the uniform `not the owner of this pane` (no liveness leak); 100 tombstones, oldest out | `closedBy`, `PANE_GONE_ERROR` | `ControlPlaneTests/aPaneItsOwnerClosedIsGoneToThatOwnerAndUniformlyRefusedToEveryoneElse`, `PaneOwnershipTests/aHundredClosedPanesAreRememberedAndTheOldestGoFirst` |
| H-4 | Owned the instant the pane exists. Native: `PaneRequest.controlledBy`, allowed only for the caller of the plugin's own running verb, never outside one | `MainPluginContext.grantOwnership` | `ControlPlaneTests/aPaneIsOwnedFromTheInstantItsPluginBuildsIt`, `ControlPlaneTests/aPluginMayNameOnlyTheCallerOfItsOwnRunningVerbAsAControllerAndNeverOutsideOne` |
| H-5 | Owned panes carry core's `controlled` signal: robot icon, pulsing `--agent` outline (4.5 s), tooltip "Controlled by another pane", until withdrawn, never on the pane's tab; Settings ▸ Panes & Tabs "Control indicator" | `controlStore.ts` | `ControlPlaneTests/anOwnedPaneCarriesTheControlledSignalAndItNeverReachesItsTab`, `UITests.ControlledPanes/anOwnedPaneShowsTheRobotAndItsOutlineButNeverOnATab` |
| H-6 | The ledger resets between tests (`tabs.test.reset`) | `resetExternalControlForTests` | `ControlPlaneTests/theLedgerResets` |
| H-7 | Flags → wire request: unknown flag refused naming the valid ones; `--pane` → `targetPaneId`; enum, number (`minimum`), boolean (bare = `true`; an inverting flag sends its declared value), csv (split on commas), json (parse error reported), path (bare = `true`, "generate one"; a value resolved against the caller's `cwd`); a bare flag needing a value refused, never sent as `1`/`"true"`; a missing required flag named. A bool `--flag=false` still sends `true` (as Electron) | `buildRequestFromEnvelope` | `ControlEnvelopeTests` |
| H-8 | Element target from flags: `--ref`, or `--x` + `--y`, or `--role`/`--name`/`--selector` (+ `--nth`, semantic only): exactly one form; both axes, numeric; `--nth` a non-negative integer; one composed `target` (`ControlFlagComposition.elementTarget`), no stray top-level fields | `composeElementTarget` | `ControlEnvelopeTests`, `BrowserInputVerbTests/everyElementTargetFormFromTheFlagsReachesTheHandler` |
| H-9 | The wire request is validated against the verb's JSON Schema (`additionalProperties: false`; `paneId` stripped first), the same check for a `batch` step and a flag-built request | `validateJsonSchema` | `ControlSchemaTests`, `ControlPlaneTests/aWireRequestIsValidatedAgainstTheVerbsOwnSchema` |
| H-10 | Budgets: quick 5 s, read 15 s, 30 s (`execute-js`, `save-resource`); derived from the wait outlived: load 15 s + 5 s headroom (`reload`, history steps), `create-browser-pane` 5 s mount + 15 s load + headroom, `navigate` 2 × 15 s + headroom, `wait-for` clamped timeout + headroom per request (`timeoutFor`), `assert` 1 s + headroom, `batch` none. Deadline = budget + headroom; then `<type> timed out after <budget>ms` and the handler is cancelled | `verbBudgetFor`, `withVerbDeadline` | `ControlBudgetTests`, `BrowserNavigationVerbTests/theVerbsBudgetsAreTheElectronAppsTiers` |
| H-11 | Core verbs: `ping`; `activate-pane` (reveal, never activate); `close-pane` (ownership released only once really gone; a declined close → `the pane was not closed`); `list-panes` (panes this caller created, every window); `pane-info` (identity + the type's live fields; gone → pane-gone error; a type that can't be inspected says so). **n/a:** Electron's "a window is reloading … try again" (no renderer reload) | `CORE_CONTROL_VERBS`, `content/externalControl.ts` | `CoreControlVerbTests` |
| H-12 | `batch --requests <json array> [--continue-on-error]`: in order, each step as the batch's caller (`paneId` overwritten); stops at the first failure (`stoppedAt`, later steps `{skipped: true}`), `--continue-on-error` runs all; ≤ 50; no nesting; an unbatchable verb refused by name (`createBrowserPane cannot be used inside a batch`); no deadline of its own; `ok: true` whenever it ran | `handleBatch` | `ControlBatchTests`, `BrowserNavigationVerbTests/createBrowserPaneCannotBeUsedInsideABatch` |
| H-13 | `capabilities`: `core`, then each plugin capability with `enabled` and one line per command (a disabled plugin's listed disabled; its verbs still answer); `describe --capability <id>`: limits, guide, every command's flags, wire schema, result shape; unknown capability refused naming `capabilities` | `controlDescribe.ts` | `CoreControlVerbTests`, `BrowserInputVerbTests/describeStatesTheInputVerbsFlags` |
| H-14 | Socket per boot (`control-<pid>.sock` in the data directory); one request per line, answered in order, one line each; a request split mid-character decodes intact; an unknown command refused cleanly; two instances on one data directory keep apart; `tabs-ctl` drains a response bigger than the pipe buffer | `controlSocket.ts`, `externalControl.ts`, `tabs-ctl` | `ControlServerTests`, `ControlPlaneEndToEndTests/tabsCtlGetsItsAnswerWithoutWaitingForTheServerToClose`, `BrowserControlEndToEndTests/aPageTextBiggerThanThePipeBufferComesBackWhole` |
| H-15 | A malformed envelope is refused with a validation message before dispatch | `externalControl.ts` | `ControlPlaneTests/aMalformedEnvelopeIsRefusedWithAValidationMessageBeforeAnythingIsDispatched` |
| H-16 | Ring log (console; Electron's network verbs share it): seq from 1, oldest evicted, seq stable across eviction, entries strictly after `sinceSeq`, no rewind on clear, removal by seq, `compilePattern` (regex; a bad one refused, never matched literally). Plugin-private | `ringLog.ts` | `RingLogTests` |

### `tabs-ctl` and the skill

| Id | Case | Electron | Native test |
|---|---|---|---|
| I-1 | `tabs-ctl` + `SKILL.md` = `resources/skills/tabs`, bundled unchanged as `Contents/Resources/skills/tabs` (`Scripts/verify-app.sh` check 10). The script relays argv as `{command, args, paneId, cwd}` via `TABS_PANE_ID`/`TABS_CONTROL_SOCKET`; exits non-zero on `ok: false`, a failed batch step, or non-empty `errors`; settles on the first response newline (Known differences) | `tabs-ctl` | `UITests.AiSettings/theBundledTabsCtlRefusesToRunOutsideATabsPane`, `ControlPlaneEndToEndTests/aBatchStopsAtTheFirstFailureAndTheExitCodeSaysSo` |
| I-2 | Command names are Electron's (`create-browser-pane`, `read-page`, …): a verb declares `command` + `wireType`; the qualified name (`browser.navigate`) works too; a bare command two verbs share is refused naming both | `ControlVerbSpec.command` | `ControlPlaneTests/aVerbAnswersToItsCommandAndToItsQualifiedName`, `ControlVerbRulesTests` |
| I-3 | Settings ▸ AI lists Claude Code (`~/.claude/skills/tabs`) and Codex (`~/.agents/skills/tabs`); Install symlinks the bundled skill, Uninstall removes it; never clobbers or removes what Tabs didn't create; installed = a link to *this* bundle's skill | `skills.ts` | `SkillInstallerTests`, `UITests.AiSettings/installThenUninstallThroughTheRealControlsChangeTheStatus` |
| I-4 | The skill and the guide never promise a verb the app lacks. **Deviation:** the guide has no network section, but `SKILL.md`'s shared frontmatter still says "capture console and network activity" | — | `BrowserGuideTests` |

### The browser verbs

Names are CLI commands, wire types in parentheses. Every one but `create-browser-pane` takes
`--pane` (`targetPaneId`), owned by the caller; H-2, H-3, H-9, H-10 apply to all.

| Id | Case | Electron | Native test |
|---|---|---|---|
| J-1 | `create-browser-pane --url` (`createBrowserPane`): refused for a disallowed URL (F-5) and while the type is off (Electron's message naming "Settings → General → Content types"; native's switch is the Plugins window); placed by G-1 relative to the caller (a floating caller: inside its window; `unpinned`: a floating window near it); opened with `activates: false` (the caller keeps the keyboard) and `controlledBy: caller` (owned before its first load); waits ≤ 5 s for the page, ≤ 15 s to settle → `{paneId, loaded, loadError?, url, title, titleFromUrl?, status?, statusText?, redirected?}`; a failure that landed before anything listened comes from the page's record; not batchable | `handleCreateBrowserPane`, `placeControlledPane` | `BrowserNavigationVerbTests/createBrowserPaneAnswersWithThePageItLoaded`, `BrowserNavigationVerbTests/aFloatingCallersNewPaneOpensInsideItsWindowOrInAnotherFloatingOne`, `UITests.BrowserControlUITests/aCreatedPaneIsShownBesideTheCallerWhichKeepsTheKeyboard`, `BrowserPlacementEndToEndTests` |
| J-2 | `navigate --url [--retry-on-redirect]`: load, wait ≤ 15 s → `{loaded, url, title, titleFromUrl?, status?, statusText?, redirected?, retried?, firstUrl?}`; `redirected` = `!isTrivialUrlChange(requested, final)`, only once settled; failure = `failed to load <url>: ERR_…`; `--retry-on-redirect` re-issues once when the first attempt settled elsewhere (never while still loading) and reports `retried`, `firstUrl`; a failing retry adds `(on the retry — the first attempt landed on <url>)`. **Deviation:** WebKit raises no event for a superseded load, so `navigate` waits out its replacement and answers `loaded: true` (`redirected` says where it went). A navigation the page starts within 150 ms of its load ending (script during parse or the load event, a zero-delay meta refresh) is followed the same way, here and in J-1: WebKit starts it after the load finishes where Chromium supersedes the load | `handleNavigate`, `attemptNavigation`, `waitForLoadSettle` | `BrowserNavigationVerbTests/navigationVerbsReportWhereThePaneActuallyEndedUp`, `BrowserNavigationVerbTests/aScriptRedirectWhileThePageLoadsIsReportedAsARedirect`, `BrowserNavigationVerbTests/retryOnRedirectReassertsTheRequestedURLOnceAfterABounce`, `UrlComparisonTests` |
| J-3 | `reload` / `go-back` / `go-forward`: wait to settle → `{loaded, loadError?, url, title, …}`, no `redirected`; nothing to step to → `cannot go back — no earlier page in this pane's history` (`forward` / `later`). **Deviation:** a history step onto a failed entry reports the entry's recorded failure (WebKit serves the stored error page without the network) | `handleReload`, `handleHistoryStep` | `BrowserNavigationVerbTests/reloadAndHistoryVerbsSettleOnThePageTheyLandOn` |
| J-4 | Every navigation answer reads the page at answer time: `url`, `title`, last document's status, `titleFromUrl: true` when `document.title` is empty (1 s read; unreadable → no flag), after reload and history steps too | `pageState` | `BrowserNavigationVerbTests/titleFromUrlIsCorrectOnReloadAndHistoryStepsNotOnlyNavigate` |
| J-5 | Landing on a failed page, whichever verb: `navigate` fails `failed to load <url>: ERR_…`, the others answer `loaded: false` + `loadError`; status, console and `config.url` reflect the failure | `navigationVerbs.ts` | `BrowserNavigationVerbTests/landingOnAFailedPageReportsTheFailureWhicheverVerbGotThere` |
| J-6 | `screenshot [--no-activate] [--selector css \| --ref ref]`: both forms refused before anything is revealed; a hidden pane is revealed (never activated) → `activated: true` (3 s to become paintable, empty captures retried within it); `--no-activate` fails naming the remedy; PNG to a file → `{path, width, height}` (device px) + `viewport`, `scaleFactor` (from the page, exact at a fractional width); a clip adds `clipped` (CSS px, clamped to the viewport, rounded outward) and `element`; an element outside the viewport refused. **Deviation:** WebKit rounds a fractional pane width down, Chromium up (asserted against the page) | `handleScreenshot`, `resolveCaptureClip` | `BrowserSnapshotTests`, `UITests.BrowserControlUITests/screenshotRevealsABackgroundedPaneItselfAndSaysSoWithActivatedTrue`, `UITests.BrowserControlUITests/aClipIsClampedToTheViewportAndAnElementOutsideItIsRefused` |
| J-7 | `get-page-text [--max-length]`: `innerText` cut at the limit (default 50 000, hard 200 000; UTF-16 units), `truncated` always honest, + readiness (J-11) | `handleGetPageText` | `BrowserReadVerbTests/thePageTextLimitsAreTheDefaultAndTheHardCap` |
| J-8 | `read-page [--selector] [--role] [--offset]`: interactive elements + headings (and images for `--role img`/`presentation`: `<img>` is `img`, `presentation` with `alt=""`), ≤ 200 per call, each `{ref, role, name, tag, rect, value, checked}`; `total`, `offset`, `truncated` (more after this page); validated up front (blank refused, unknown role refused with the vocabulary, `offset` a non-negative integer; a selector the page refuses is surfaced); sliced before refs are minted; names as the browser computes them (label text minus the control, a select's chosen option, `aria-labelledby`…), `checked` incl. `"mixed"` | `readPageScript` | `BrowserScriptTests/readPageListsWhatThePageShowsWithRolesAndNamesAsTheBrowserComputesThem`, `BrowserReadVerbTests/readPageNarrowsByRoleAndSelectorAndPagesByOffset` |
| J-9 | `find --description [--max-results]` (default 10): `scoreElement` ranking; refs minted only for the matches returned (two page calls); a match that left the page in between is dropped | `handleFind`, `findElements.ts` | `BrowserReadVerbTests/findMintsRefsOnlyForTheMatchesItReturns`, `FindElementsTests` |
| J-10 | Refs `e<n>-<document tag>` in a per-document registry (1 000 kept); a ref from another document is stale and says so (`… so call readPage again`); a semantic target matches by a strictness ladder (exact, case-insensitive exact, substring), visible elements only; ambiguity fails listing candidates (`nth` picks); role is a hard filter with a near-miss diagnosis | `pageScripts.ts` | `BrowserScriptTests/semanticTargetsMatchByTheStrictnessLadder`, `BrowserInputVerbTests/aStaleElementRefReportsWhyRatherThanClickingSomethingElse`, `BrowserInputVerbTests/anAmbiguousSemanticTargetFailsListingItsCandidatesAndNthPicksAmongThem` |
| J-11 | Readiness on every read: `isLoading`, `readyState`, `settled` (no DOM mutation for 500 ms since first observed: a page's first read is never settled), `frames`, `shadowRoots` (open, top level) | `READINESS_JS`, `DOCUMENT_SHAPE_JS` | `BrowserReadVerbTests/readVerbsReportReadinessAndSettledFlipsOnlyWithTheDOMActuallyQuiet`, `BrowserReadVerbTests/readVerbsReportFrameAndShadowCounts` |
| J-12 | `click`: a ref/semantic target is resolved, scrolled into view (instant) and hit-tested in one page script; a point no longer holding it gets one retry after 100 ms, then fails naming both elements; a coordinate is pressed as given, only described; a move (`_simulateMouseMove:`, reaching the page only in the key window, J-13), then trusted `mouseDown`, `mouseUp` → `{x, y, element}` | `handleClick`, `resolveClickTarget` | `BrowserInputTests/aClickArrivesAsTrustedMouseEventsAndFocusesTheField`, `BrowserInputVerbTests/aClickWhoseTargetIsCoveredFailsNamingBothElementsInsteadOfPressingTheCover` |
| J-13 | `hover`: `click`'s resolution and hit test, then a trusted move only; the hover persists; answers once the page saw the `mousemove`. **Deviation:** in a window that isn't key WebKit delivers no move, so hover fails there (after resolving its target) naming the cause and the remedy (Chromium hovers a background window) | `handleHover` | `BrowserInputVerbTests/hoverOpensAHoverOnlyMenuWithoutCommittingTheClick`, `BrowserInputVerbTests/hoverInAWindowThatIsNotKeyFailsSayingWhy`, `BrowserInputVerbTests/hoverResolvesTargetsAsClickDoesAndNeverPresses`, `BrowserInputTests/aMoveHoversThePageInTheKeyWindowAndIsRefusedInAnyOther` |
| J-14 | `type --text [--submit]`: printable text only (a control character refused up front naming it and its UTF-16 index, before anything is focused); ref/semantic target focused directly, a coordinate clicked; printable ASCII = full keydown/keypress/keyup inserting once (capitals shifted), other characters as inserted text alone, in order with the keys around them (an insert waits for the keys before it); `--submit` presses Enter (a plain form submits once, a textarea gains one line break); appends | `handleType`, `keystrokes.ts` | `BrowserInputTests/typingDeliversEachCharacterAsKeydownKeypressInputAndKeyupInsertingOnce`, `BrowserInputTests/textMixingKeysAndCharactersWithNoKeyLandsInOrder`, `BrowserInputVerbTests/typeRefusesTextItsKeystrokesCannotCarryBeforeTouchingThePage`, `KeystrokesTests` |
| J-15 | `key [--key] [--modifiers csv] [--command]`: exactly one of key/command; meta or control held → no character; arrows keep `key`/`code` under every modifier; a meta/control chord on a, c, v, x, z, y answers with a `note` (the browser's editing commands ignore synthesized chords); `--command select-all\|undo\|redo\|delete` runs `execCommand` in the page (no clipboard commands) → `{command, element}`; a refused command errors | `handleKey`, `editingCommandScript` | `BrowserInputTests/arrowKeysKeepTheirKeyAndCodeUnderEveryModifier`, `BrowserInputVerbTests/aModifierChordCannotReachTheEditingCommandsAndCommandCan` |
| J-16 | `scroll --direction [--amount]`: the document, instant even on a smooth page; default step `innerHeight`/`innerWidth` × 0.8 → `{position}` (settled), a hidden pane too; nested containers out of scope; `--direction` defaults to down as a flag, required on the wire | `scrollScript` | `BrowserInputVerbTests/scrollReportsWhereItLandedOnASmoothPage`, `UITests.BrowserInputUITests/scrollReportsWhereItLandedOnAHiddenPane` |
| J-17 | `form-input --fields <json [{target, value}]>`: fields in order, each focused then filled in-page (select by value or visible label with `input`/`change`; input/textarea via the native setter; contenteditable via editing commands; multiline verbatim) → `{filled, fields: [{index, length}], errors: [{index, error}]}`; a field not holding what was sent (a single-line `<input>` given newlines), a non-fillable element, an unmatched option (options listed) → an error entry, the rest continue | `handleFormInput`, `fillFocusedScript` | `BrowserInputVerbTests/formInputSetsMultilineValuesVerbatimReadsThemBackAndRefusesFieldsThatWillNotHoldThem`, `BrowserScriptTests/fillWritesEachElementKindWholeAndReadsItBack` |
| J-18 | `read-console [--pattern] [--since-seq]`: captured messages after `sinceSeq` whose text matches; a bad pattern refused; reads the pane's buffer, no page script | `handleReadConsoleMessages` | `BrowserScriptVerbTests/anAgentCanReadTheConsoleIncludingAMessageThatArrivesLate` |
| J-19 | `execute-js --code [--out]`: one expression, awaited, in the page world whatever its CSP; a throw is data (`script threw: <Name: message>` then the stack's frames, less the bare `@` ones WebKit gives injected code); a non-expression → the IIFE hint; the value is what `JSON.stringify` (captured before the code runs) makes of it: `undefined` → `null`, a DOM node → `{}`, a cycle refused; cut at 50 000 UTF-16 units (never splitting a surrogate pair) with `truncated`; `--out` writes it whole (a string raw as `.txt`, else pretty JSON `.json`) → `{path, bytes, format}` | `handleExecuteJavaScript`, `executeScript` | `BrowserScriptVerbTests/aResultIsWhatJSONMakesOfIt`, `BrowserScriptVerbTests/aThrowsStackKeepsThePagesFramesAndDropsTheEmptyOnes`, `BrowserScriptVerbTests/executeJsOutWritesTheFullResultToAFileInsteadOfTruncating` |
| J-20 | `wait-for`: exactly one of `--text`, `--selector` (visible), `--url-contains`, `--idle`; `--gone` inverts text/selector; runs in the page (MutationObserver + fallback poll), one injection per document; host-side deadline (`--timeout` default 10 s, cap 300 s; `--poll` default 250 ms, floor 50) survives navigation by re-arming in the new document; a refused injection is retried; `--url-contains` never injects; a selector match → `ref`, `tag`, `rect`; answers `elapsedMs`; a closed pane aborts with the pane-gone error; a timeout names the condition. `--timeout 0` never checks (as Electron) | `handleWaitFor`, `waitForPageCondition` | `BrowserWaitTests`, `BrowserWaitVerbTests/aTimeoutOfZeroNeverChecks` |
| J-21 | `assert`: `wait-for`'s single-shot twin (text / selector / url-contains, `--gone`; no idle) on a 1 s check; failure fails the verb (`assertion failed: page text does not contain "…"`) so a batch stops there; no `elapsedMs` | `handleAssert` | `BrowserWaitVerbTests/assertChecksAConditionRightNowPassWithAUsableRefFailNamingThePremise` |
| J-22 | `save-resource [--url \| --ref \| --selector] [--out]`: exactly one source (an element's `currentSrc`/`src`/`href`/`data`); `data:` decoded in-app; `http(s)` fetched host-side (not bound by CSP/CORS) with the page's cookies and User-Agent, streamed under the 50 MB cap, 25 s total, status ≥ 400 refused, response cookies written back, redirects off http(s) refused; `blob:` fetched in a private content world; file extension from content type → magic bytes → URL → `bin` → `{path, bytes, contentType}`. **Deviation:** one blob route (Electron: CDP resource tree, then a page fetch); only a revoked blob fails | `handleSaveResource`, `fetchResource` | `BrowserResourceFetchTests`, `BrowserResourceVerbTests` |
| J-23 | `read-network`, `capture-bodies`. **Deviation:** not ported (Scope): unknown commands, absent from `capabilities`/`describe` | `networkLog.ts`, `networkBodyCapture.ts` | `BrowserScriptVerbTests/captureVerbsAreAbsent` |
| J-24 | Every verb refuses a pane its caller doesn't own (H-2), a closed one (H-3), one of another type (`target is not a browser pane`), and one without a page (`browser pane is not currently mounted`): a pane in a never-shown tab; for click/hover/type/key, a page with no window (scroll and form-input work by script) | `browserPaneError`, `PANE_NOT_MOUNTED_ERROR` | `BrowserInputVerbTests/inputVerbsRefuseAPaneThatIsNotMounted`, `BrowserNavigationVerbTests/aPaneThatIsNotABrowserIsRefusedByName` |
| J-25 | A page that can't run script answers `the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none`, never the engine's plumbing | `GUEST_SCRIPT_UNAVAILABLE` | `BrowserReadVerbTests/aPageThatCannotRunScriptIsOneSentenceNotTheEnginesPlumbing` |
| J-26 | Files: `--out` = a caller-named path (core resolves it against the caller's `cwd`), created exclusively (`O_EXCL`), never overwritten (`refusing to overwrite an existing file: <path>`) or swept; else `<uuid>.<ext>` under the plugin's cache dir (`agent-screenshots`, `agent-resources`, `agent-output`), 10-minute TTL, swept at activation (background) and at most once a minute per subdirectory on write; a write failure is a message, never a throw | `agentFiles.ts` | `BrowserAgentFilesTests` |
| J-27 | Bytes never ride the socket: screenshots, saved resources and `--out` results are files; answers carry paths | `SCREENSHOT_BYTES_KEY`, `EXECUTE_OUTPUT_KEY` | `BrowserControlEndToEndTests/anAgentCanReadBackAPaneItOwnsInfoTextAndARealPNGOnDisk` |

## Look

From `browser.css`, `global.css` (`.pane-header`, `.pane-header-button`) and the icons; px =
pt. The header (padding, gap 8, 24 tall, depth shade, hover-revealed controls) is core's; the
browser owns its title slot (`PaneHeaderTitleView`), laid out from
`PaneHeaderSlot.fractionalOffset`.

| Id | Element | Box | Text | Colors | States | Scenario |
|---|---|---|---|---|---|---|
| L-1 | Nav button (Back, Forward, Refresh) | padding 2 × 5 → 23 × 17, radius 3; icon 13 × 13 (viewBox 16; stroke 1.4 back/forward, 1.2 refresh; round caps) | — | `currentColor` = `--text-dim`; hover wash `rgb(--hover-rgb / 0.12)` | hover; disabled at opacity 0.35, no wash, default cursor | `browser-default`, `browser-hover-back`, `browser-hover-refresh`, `browser-hover-disabled`, `browser-history` |
| L-2 | Address bar | `flex: 1`, `min-width: 0`, height 20, 1px border, radius 3, `overflow: hidden` | — | `--border`; `--accent` while the input has focus | focus-within | `browser-default`, `browser-address-focus` |
| L-3 | Title segment | `flex: 0 1 auto`, `max-width: 30%`, padding 2 × 6, `border-right` 1px `--border`; absent without a title | 12 / 16, one line, ellipsis | `--text-dim` on `--bg-elevated` | snug, capped, none | `browser-short-title`, `browser-long-title`, `browser-no-title` |
| L-4 | Address input | `flex: 1`, height 100%, padding 2 × 6, no border/outline | 12, inherited color | `--bg` | text, focus | `browser-default`, `browser-address-focus` |
| L-5 | The page | fills the body (100% × 100%) | — | fixture page: solid color; unpainted page white (`underPageBackgroundColor`) | loaded, blank | `browser-default`, `browser-blank` |
| L-6 | Controlled pane | core's signal outline + robot (PANE-SIGNALS.md) | — | `--agent` | pulsing | `browser-controlled` (as `signal-controlled`) |
| L-7 | Both themes | every element above | — | dark and light tokens | — | `browser-light`, `browser-empty-toolbar-light` |
| L-8 | Creation icon | 16 × 16 globe: `circle r 6` stroke 1, equator + meridian stroke 0.9 | — | `currentColor` (template image) | hover | `browser-empty-toolbar`, `browser-empty-toolbar-hover` |

Tests: `BrowserPaneTests/laysOutAsTheHeadersFlexRowDoes` (L-1…L-4),
`BrowserPaneTests/aButtonWashesOnHoverAndDimsWhenDisabled`, `BrowserPaneTests/theGlyphsDrawInsideTheirBoxes`
(L-1, L-8), `BrowserPaneTests/theBarsCornersAreRounded` (L-2),
`BrowserPaneTests/theInputsTextSitsWhereChromiumPutsAnInputsLine` (L-4),
`BrowserPaneTests/paintsTheBarInTheThemesColorsInBothThemes` (L-3, L-4, L-7),
`VisualParityTests/theGeometryIsTheElectronApps`.

- Painted edges snap as Chromium's (`snap`: whole point, round half up); text sits on a
  whole-point baseline in a line box of rounded ascent + rounded descent (`BrowserText`).
- The unfocused address is drawn by the bar where Chromium puts an input's line; the
  `NSTextField` shows (alpha 1) only while editing.

## Electron quirks kept for parity

- A non-URL address is a **Google** search; the engine isn't a setting.
- A pane opened by hand never reads the placement setting.
- Right-click and scrollbar drag in the page activate the pane (D-1).
- A deliberate `about:blank` stays a history entry; only the initial one is dropped (B-3).
- Ownership is permanent for the run, even after the user navigates the pane by hand.
- `titleFromUrl` is read from `document.title` at answer time, not from title events.
- `find` is a heuristic; `read-page`'s names approximate the accessible-name algorithm.
- `wait-for --timeout 0` never checks (the deadline is tested before the first injection).
- `save-resource`'s 25 s timeout is a total, not a stall timeout.
- A DOM node from `execute-js` answers `{}`; only a cycle is refused (the message still names
  both).
- A bool `--flag=false` sends `true` (H-7).

## Can't be ported as-is

- **`<webview>` guest → `WKWebView`.** The separate-process facts (no host DOM events,
  `getWebContentsId` unreadable while guestless, reload on reparent, pointer capture and
  `.pointer-gesture`, `did-attach`) have no counterpart; the cases they protect are E-1…E-6 and
  D-1…D-4.
- **`sendInputEvent` → `NSEvent`s sent to the web view.** Measured in a never-shown window:
  clicks and keys arrive trusted (`isTrusted`). A move is no responder message (`WKWebView`
  hears moves through its tracking areas): it goes in through `_simulateMouseMove:` (WebKit's
  SPI for its tests) and arrives trusted, hovering, **in the key window only**: WebKit turns a
  button-less move in a page whose window isn't key into a scrollbar update
  (`WebFrame::handleMouseEvent`), and nothing turns that off, so `hover` fails there (J-13).
  Tests make a never-shown window key as WebKit's own do (`KeyableWindow`). Don't fake a move
  with `mouseEntered`: that hung the process. Keys need the web view as first
  responder (`withHostFocusRestored` gives it back). Input is queued: `PageInput.settle` waits
  ≤ 0.5 s on the page's `InputAcknowledgement` counters so a read right after sees the effect.
- **`executeJavaScript` / `capturePage` → `callAsyncJavaScript` / `takeSnapshot`**: both work
  in a hidden window. The script's error is reported, so `evalInGuest`'s "discard the error"
  workaround isn't needed; the caller-facing messages are kept.
- **A pending script never settles across a navigation** (WebKit as Chromium): `PageWait`
  races every injection against `PageEvents`, re-injecting into the new document
  (`BrowserPolicyTests/anEvaluationAwaitingAPromiseNeverSettlesWhenThePageNavigatesAway`).
- **Console events → injected capture.** The `console.*` wrapper must run in the page's own
  world (each world has its own `console`); the error listener runs in a private world (error
  events reach every world, and the page can't remove it).
- **Chromium's error page → a `tabs-error:` document** served by a scheme handler, loaded as a
  navigation so it is a real history entry. `loadHTMLString(…, baseURL: failedURL)` replaces
  the current entry (measured), losing the previous page's Back target.
- **`save-resource`'s blob route** (CDP `Page.getResourceContent`) → a `fetch` in a private
  `WKContentWorld`, which the page's CSP doesn't bind (measured against `connect-src 'self'`).
- **The http(s) route** (`net.request` on the guest's session) → an ephemeral `URLSession`
  carrying the page store's cookies.
- **Network capture**: J-23.
- **The guide's Chromium statements** (error pages, accessible names, editing chords) are
  re-measured on WebKit and corrected in the guide's copy (Known differences).

## Checking the look

`make visual` (`ONLY=` scenario names) renders both apps and compares; the 20 scenarios are
`Visual/scenarios/browser-*.json`. A `browser` block per browser leaf sets
`{page, canGoBack?, canGoForward?, focusAddress?}`; the empty-toolbar ones add
`creationActions: ["browser"]`. Schema and staging: `Visual/README.md` ("Browsers").

- Electron: the real `BrowserHeaderTitle` around a solid-color `.browser-webview` stand-in
  (`packages/plugin-browser/testing/visualCapture.ts`); a `<webview>` doesn't render in the
  harness.
- Native (`VisualCapture.stageBrowser`, `browser.test.chrome`): the real `WKWebView` on a
  fixture page of the same color. Its pixels are out of process, so the capture puts a
  `takeSnapshot` image in the layer and applies the inactive-pane dim by hand; hover is a
  synthesized `mouseEntered` to the header view.
- Geometry under `browser.<leaf>.`: `page`, `back`, `forward`, `refresh`, `backDisabled`,
  `forwardDisabled`, `addressBar`, `titleSegment`, `titleText`, `titleBaseline`,
  `titleString`, `titleTruncated`, `addressInput`, `addressText`, `addressBaseline`,
  `addressValue`, `focused`. Gate: `VisualParityTests/theGeometryIsTheElectronApps`
  (0.5 pt).
- Residuals: the hover wash is one 8-bit level off (theme-color rounding); pixel differences
  are glyph antialiasing. Unverified: window-server hover in a shown window; the inactive dim
  on a live on-screen `WKWebView`.

## Known differences

Each measured (WebKit against the Electron premise) or decided.

- **`read-network` and `capture-bodies` are absent** (Scope, J-23); `SKILL.md`'s frontmatter
  (shared with Electron) still mentions network activity.
- **A moved pane keeps its page**; `pageInstance` doesn't change on a move (E-1, E-6).
- **Nav-button tooltips** are AppKit's (B-5).
- **A `console.*` entry's source URL and line** come from the wrapper's own stack (it runs in
  the page's world, so the caller's frame is in it); an uncaught error's from its event (C-3).
- **Titles**: the document's, else Chromium's URL stand-in; an error page's is the failed
  host; the HTTP status text comes from a standard table (`HTTPStatusText`; WebKit exposes
  none).
- **Load failures**: the error page is a `tabs-error:` document, so history, `url` and
  `config.url` follow as on Chromium's; `ERR_*` names mapped from `NSError` (unmapped:
  `ERR_FAILED`). Refresh on an error page loads the failed URL as a new entry; a history step
  onto a failed entry reports its recorded failure without retrying (J-3).
- **A superseded navigation** raises no event: `navigate` waits out the replacement, answers
  `loaded: true` (J-2).
- **A script redirect while the page loads** lets the load finish first on WebKit (Chromium
  supersedes it): `navigate`/`create-browser-pane` watch 150 ms past the load's end for a
  navigation the page starts, and follow it (`waitForLoadSettle`). That also catches a timer
  redirect within those 150 ms, which Electron's answer misses; a later one is after the answer
  on both.
- **The starting `about:blank` is never loaded**, so it can't be a Back entry; `about:blank`
  typed on a never-loaded pane is a no-op (B-3).
- **Viewport**: WebKit rounds a fractional pane width down, Chromium up (J-6).
- **`hover`** fails in a window that isn't key (J-13, Can't be ported as-is).
- **Editing chords**: the premise holds on WebKit: a synthesized ⌘A reaches the page as a
  `keydown` but not the editing layer; the responder chain's `selectAll:` and `execCommand`
  do. The `note` stays (J-15).
- **Undo** undoes a run of typing as one step (Chromium: a character at a time).
- **A pane in a never-shown tab** has no page (its body is built on first show): verbs answer
  "not currently mounted" (Electron mounts every tab). Agent-created panes are always shown
  first (J-24).
- **`save-resource`**: one blob route, which also reads a blob minted but never loaded behind
  a strict CSP (unreachable in Electron); the http(s) route sends the page's User-Agent,
  writes response cookies back, refuses redirects off http(s). Scripts run on an error page,
  and a PDF is an `<embed>` on WebKit.
- **`tabs-ctl`** settles on the response's first newline (the native server keeps
  connections open) and decodes with `setEncoding`; the shared script behaves the same for
  Electron.
- **App Transport Security**: the app's `Info.plist` sets `NSAllowsArbitraryLoads`; without
  it plain `http://` to anything but localhost fails (-1022), page loads and `save-resource`
  alike.
- **Not yet: downloads and JavaScript `alert`/`confirm`/`prompt`**: no download delegate, no
  `WKUIDelegate` panel methods. Untested on both sides.
- **Control plane**: any attached pane may call, not only a live pty host (H-1, not yet); a
  request without a `paneId` answers `not running inside a Tabs pane`
  (Electron: `expected a {command, args, paneId} envelope`); `activates: false` keeps
  Electron's behaviour (the pane becomes the window's active pane, only the keyboard is
  withheld, once); a tombstone is recorded on any close, the user's included; a relative
  `path` in a `batch` step resolves against the request's `cwd`.
- **`create-browser-pane`**: any refused placement answers the "turned off" message (core's
  `openPane` answers nil for both); that message names Electron's Settings location, not the
  Plugins window.
- **Skill install**: the bundle is found at `Resources/skills/tabs` only (no repo-directory
  dev path); Uninstall removes any symlink at the destination, and a dangling link (the app
  moved) can't be reinstalled over. Both inherited from Electron's `skills.ts`.
