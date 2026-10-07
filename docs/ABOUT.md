# About window

Application menu ▸ About Tabs: identity, version, donation tiers, crypto addresses, credits, in
a standard window of its own. Code: `Sources/Tabs/About`.

## Scope

- The look is the system's (titled window, AppKit controls, semantic colors); no `Visual/`
  scenario or golden.
- Theme: follows the app's Theme setting like every window (inherits `NSApp.appearance`), in
  system semantic colors (G-1).
- Credits: the linked packages, each with its license; no versions. Core credits what `project.yml`
  links (nothing today); each plugin credits what its `plugin.yml` links, in its Info.plist
  (`TabsCredits`), so the credits ship with the plugin carrying the code (Terminal: SwiftTerm).
- Payment links and addresses are generated from `Config/AppConfig.plist`, never typed (see Money).
- Icon: the bundle's `AppIcon`, every size drawn from `Artwork/icon.svg`.
- Shell chrome like Settings and Plugins, not a plugin: no control verbs, setting or shortcut;
  saves nothing.

## Sources

| File | What |
|---|---|
| `Sources/Tabs/About/AboutWindow.swift` (`AboutWindowController`, `AboutPresenter`, `AboutBodyView`, `AboutMetrics`) | Window, singleton, page |
| `AboutWindow.swift` (`AboutModel`; `PressButton`, `TierButton`, `LinkButton`, `CopyButton`) | What a press does; OS calls (`NSWorkspace`, `NSPasteboard`, `Bundle.main`) |
| `Sources/Tabs/UI/MainMenu.swift` (About item, `CommandRouter.close(keyWindow:)`), `AppDelegate.showAbout` | Opening; ⌘W |
| `Sources/Tabs/About/AboutContent.swift` (`Attributions`, `Donations`, `AboutCopy`, `ExternalURL`) | Credits, tiers, copy, URL vetting |
| `Sources/Tabs/About/AppConfig.generated.swift` ← `Scripts/sync-app-config.py` | Payment links, addresses |
| `Sources/Tabs/Assets.xcassets/AppIcon.appiconset` | Icon |
| `Sources/Tabs/Testing/TestControlVerbs.swift` (`tabs.test.menu`, `tabs.test.about`, `tabs.test.click` with `window: "about"`) | Debug, hidden-mode e2e hooks |

Tests: `UITests.About` (`Tests/TabsAppTests/AboutWindowTests.swift`; recording opener and
pasteboard, hand-released clock), `AboutModelTests` (the same file: `AboutModel` alone, no window),
`AboutContentTests` (data rules, credits reconciliation, money drift), `AboutEndToEndTests` (built
app over the control socket).

## Cases

### Opening and closing

| Id | Case | Test |
|---|---|---|
| A-1 | Application menu ▸ "About Tabs" opens it: a window of its own, not a view in (or a new) workspace window | `UITests.About/presentingItTwiceGivesTheOneWindow`, `AboutEndToEndTests/theApplicationMenuOpensARealAboutWindowThatAResetCloses` |
| A-2 | Again while open → that window comes forward; never a second | `UITests.About/presentingItTwiceGivesTheOneWindow` |
| A-3 | Titled "About Tabs"; content 460×630 (the title bar is outside it); not resizable, zoomable or fullscreenable; no parent (can sit on another Space) | `UITests.About/theWindowIsAStandardFixedSizeWindow` |
| A-4 | System title bar and buttons | `UITests.About/theWindowIsAStandardFixedSizeWindow` |
| A-5 | ⌘W / File ▸ Close Pane with About key closes About; workspace untouched (router: a key non-workspace window gets `performClose`) | `UITests/closeWithAnotherWindowKeyClosesThatWindowNotAPane` (the router), `UITests.About/closingDropsTheWindowAndTheNextOneIsFresh` (the window closed, the singleton dropped) |
| A-6 | Closing (or a test reset) drops the singleton → next open is a fresh window, scrolled to the top. A stale window's close never clears a newer one | `UITests.About/closingDropsTheWindowAndTheNextOneIsFresh`, `UITests.About/aStaleWindowClosingLeavesANewerOneInPlace`, `AboutEndToEndTests/theApplicationMenuOpensARealAboutWindowThatAResetCloses` |
| A-7 | System window background | — |
| A-9 | Hidden mode (`TABS_E2E_HIDDEN=1`): built, never shown or focused | `UITests.About/presentingItTwiceGivesTheOneWindow`, `AboutEndToEndTests/theApplicationMenuOpensARealAboutWindowThatAResetCloses`, `EndToEndTests/hiddenModeShowsNoWindowNotEvenSettingsPluginsAboutOrCaffeinate` |

### Identity

| Id | Case | Test |
|---|---|---|
| B-1 | 72×72 app icon, decorative (not an accessibility element; the name follows) | `UITests.About/theIconIsDecorativeAndSeventyTwoPoints` |
| B-2 | Name "Tabs" (static text) | `UITests.About/showsTheAppsIdentityWithTheRunningVersion` |
| B-3 | "Version <v>": the running bundle's `CFBundleShortVersionString`, never a literal; read once at creation; the block's only selectable line | `UITests.About/showsTheAppsIdentityWithTheRunningVersion`, `AboutModelTests/theRealModelReadsTheBundlesVersion`, `UITests.About/onlyTheVersionAndTheAddressesAreSelectable` |
| B-4 | Tagline "A fancy terminal with tabs, splits, and nested layouts." | `UITests.About/showsTheAppsIdentityWithTheRunningVersion` |
| B-5 | "Copyright © 2026 Hrusoft. All rights reserved." | ″ |

### Donation tiers

| Id | Case | Test |
|---|---|---|
| C-1 | Title "Buy me a coffee"; "Like this app? You can buy me a coffee to fuel future development." | `UITests.About/offersEachTierWithItsAmountNameAndFlavor` |
| C-2 | Three full-width tier buttons, cheapest first: `$4 USD` Coffee, "One cup, one bug fixed. Roughly." · `$20 USD` A pack of roasted beans, "Enough to get through a whole feature." · `$200 USD` I'm rich, I'll buy you a nice grinder, "Burr, not blade. You have excellent taste." | `UITests.About/offersEachTierWithItsAmountNameAndFlavor`, `AboutContentTests/offersTheThreeTiersCheapestFirst`, `AboutContentTests/formatsAnAmountWithItsCurrency` |
| C-3 | A press anywhere on a tier → that tier's own payment link to the OS browser; never navigates the window. Links distinct and openable | `UITests.About/pressingATierSendsItsOwnLinkToTheBrowser`, `UITests.About/aTierTakesThePressOnAnyOfItsParts`, `AboutContentTests/givesEveryTierADistinctIdAndItsOwnLink`, `AboutContentTests/keepsEveryTierLinkOpenable` |
| C-4 | Hover: 6% wash + accent border | `UITests.About/tiersShowTheHoverWashAndAnAccentBorder` |
| C-5 | Amount column ≥ 86pt → every name starts at the same x. Sized for "$200 CAD"; a five-digit tier needs it retuned | `UITests.About/everyTiersNameStartsAtTheSameX` |
| C-6 | Amount in tabular (monospaced) digits; currency USD, what the links are priced in (unverifiable: the price lives in Stripe) | `AboutContentTests/formatsAnAmountWithItsCurrency` |

### Crypto

| Id | Case | Test |
|---|---|---|
| D-1 | Title "Or in crypto"; "Same idea, no card involved. Copy an address and send whatever you like." | `UITests.About/showsEveryAddressInFullWithItsLabelAndTicker` |
| D-2 | A row per chain (Bitcoin BTC, Ethereum ETH): label + dim ticker; full address in mono, wrapped at any character, never truncated (Copy is only trustworthy if the whole address shows), selectable; Copy beside | `UITests.About/showsEveryAddressInFullWithItsLabelAndTicker`, `UITests.About/onlyTheVersionAndTheAddressesAreSelectable` |
| D-3 | Copy puts that address, and only it, on the system pasteboard | `UITests.About/copyPutsTheAddressOnThePasteboardAndOnlyThat`, `AboutEndToEndTests/aCopyButtonPutsTheAddressOnTheRealSystemPasteboard` |
| D-4 | The pressed button reads "Copied" (accent) for 1.5 s, then "Copy"; others unaffected, each on its own timer, so two can say "Copied" at once | `UITests.About/aPressedButtonSaysCopiedForAMomentAndOnlyThatOne`, `AboutModelTests/eachButtonKeepsItsOwnTimer`, `AboutEndToEndTests/aCopyButtonPutsTheAddressOnTheRealSystemPasteboard` |
| D-5 | Pressing again within the 1.5 s restarts it | `AboutModelTests/pressingAgainRestartsTheConfirmation` |
| D-6 | Closing with a confirmation pending leaves no timer (`AboutModel.stop` from `windowWillClose`) | `UITests.About/closingTheWindowLeavesNoTimerBehind` |
| D-7 | Copy ≥ 58pt wide: "Copied" never shifts the address column | `UITests.About/theCopyButtonKeepsItsWidthWhenItSaysCopied` |
| D-8 | Copy is a small push button with AppKit's pressed feedback; no hover wash | — |
| D-9 | Every address has a distinct id and a non-empty value | `AboutContentTests/givesEveryCryptoAddressADistinctIdAndANonEmptyValue` |

### Credits

| Id | Case | Test |
|---|---|---|
| E-1 | Title "Built with"; "Tabs would not be possible without these projects." | `UITests.About/creditsEveryPackageWithItsLicense` |
| E-3 | The linked packages (core's and every bundled plugin's, enabled or not), each once, alphabetical, each with its license; no section when nothing is linked | `UITests.About/creditsEveryPackageWithItsLicense`, `UITests.About/aBuildThatLinksNothingHasNoCreditsSection`, `AboutContentTests/theAppCreditsCoreAndEveryBundledPlugin`, `AboutContentTests/listsThePackagesAlphabetically` |
| E-4 | Name is a link-styled button (accent; underline on hover) → its URL to the OS browser. Nothing on the page is a real link | `UITests.About/pressingACreditOpensItsURLInTheBrowserNotInTheWindow`, `UITests.About/aCreditNameUnderlinesWhileHoveredAndIsAccentColored` |
| E-5 | Name left, license at the right edge, baseline-aligned, so licenses line up. Two columns: name, license | `UITests.About/theLicenseLinesUpAtTheRightEdge` |
| E-6 | The list is exactly what ships: core's (`Attributions.core`) reconciled both ways against `project.yml`'s `packages:` keys, each plugin's (`TabsCredits` in `Plugins/<Name>/Info.plist`) against its own `plugin.yml`'s; no duplicates; each has a license and an openable URL. A dependency declared any other way escapes the check | `AboutContentTests/coreCreditsExactlyThePackagesItLinks`, `AboutContentTests/everyPluginCreditsExactlyThePackagesItLinks`, `AboutContentTests/theSpecParseFindsThePackagesAndNothingElse`, `AboutContentTests/namesNoPackageTwice`, `AboutContentTests/givesEveryEntryALicenseAndAnOpenableURL` |

### Scrolling and layout

| Id | Case | Test |
|---|---|---|
| F-1 | The window never grows; the body scrolls | `UITests.About/sectionsComeInOrderAndTheWindowScrollsRatherThanGrowing` |
| F-2 | At rest the identity and all three tiers are above the fold; the credits need scrolling | `UITests.About/theIdentityAndAllThreeTiersAreAboveTheFold` |
| F-3 | Order: identity, donations, crypto, credits | `UITests.About/sectionsComeInOrderAndTheWindowScrollsRatherThanGrowing` |
| F-4 | The system title bar moves the window | — |
| F-5 | Only the version and the addresses are selectable | `UITests.About/onlyTheVersionAndTheAddressesAreSelectable` |
| F-6 | Pointing hand over tiers, credit names and Copy buttons (cursor rects) | — (not observable in a never-shown window) |

### Theme

| Id | Case | Test |
|---|---|---|
| G-1 | Follows the app's Theme setting (dark, light, system), live, in system semantic colors: inherits `NSApp.appearance`, pinned by `AppShell.applyPaneSettings` | `UITests.About/rendersInBothAppearancesWithoutClipping`; mechanism: `UITests.Appearance/everyWindowFollowsTheSettingNotTheOS` (About not in it) |

### Persistence and control

| Id | Case | Test |
|---|---|---|
| H-1 | Nothing saved (frame, scroll); each new window opens centered, at the top | `UITests.About/closingDropsTheWindowAndTheNextOneIsFresh` |
| H-2 | No control verbs, setting or shortcut (the `tabs.test.*` hooks are Debug-only) | — |

### Errors and edge cases

| Id | Case | Test |
|---|---|---|
| X-1 | A URL that isn't http(s)/mailto is dropped silently, never opened (`ExternalURL.vetted`) | `AboutModelTests/opensNothingThatIsNotAWebOrMailLink`, `AboutContentTests/opensOnlyWebAndMailLinks`, `AboutContentTests/refusesEverythingElse` |
| X-2 | The OS declining to open → logged to stderr (`AboutModel.openInBrowser`), never fatal | — (needs a URL the OS can't open) |
| X-3 | Works with no workspace window open: `AboutPresenter` is independent of them | — |

## Money

- `Config/AppConfig.plist` is the one source of payment links and receiving addresses. Never
  edit it in passing, nor let an agent (`.claude/settings.json` denies agents Edit and Write on
  it); a wrong value renders fine and pays a stranger. Its header comment says how to replace a
  value.
- `Scripts/sync-app-config.py` copies its `donations.paymentLinks` and
  `donations.cryptoAddresses` dicts into `Sources/Tabs/About/AppConfig.generated.swift`
  (committed): one constant per key plus an `all` map. Strict read: exactly those two non-empty
  dicts of identifier keys and one-line string values; anything else exits with an error.
- `--check` (run by `make lint`) exits 1 when the generated file is stale → rerun the script.
- `AboutContentTests/theGeneratedPaymentLinksAreAppConfigsOwn`,
  `AboutContentTests/theGeneratedAddressesAreAppConfigsOwn`: read the plist independently
  (`PropertyListSerialization`) and compare. `AboutContentTests/everyTierAndAddressReadsItsOwnConfiguredValue`: each tier and
  address reads its own key; no configured key goes unshown.
- Tiers read `AppConfig.PaymentLinks.<id>` by name, so a renamed key is a compile error. The copy
  (names, flavor text, currency) is typed in `AboutContent.swift`.

## Look

Lengths in pt (`AboutMetrics`, the labels' fonts); colors are system semantic ones.

| Id | Element | Box | Text | Colors | States |
|---|---|---|---|---|---|
| L-1 | Window | titled, closable, miniaturizable; body 460×630 | — | system window background | — |
| L-2 | Title bar | the system's; "About Tabs" | system | system | — |
| L-3 | Body | vertical scroll view, overlay scroller (column always 460 wide); padding 24 28 28 | — | — | scrolled |
| L-4 | Identity | centered column; icon→name 12, name→version 2, version→tagline 10, tagline→copyright 12 | centered | — | — |
| L-5 | Icon | 72×72 | — | — | — |
| L-6 | Name | — | 22 semibold | label | — |
| L-7 | Version | — | 12, selectable | secondary label | — |
| L-8 | Tagline | — | 12.5 | secondary label | — |
| L-9 | Copyright | — | 11.5 | secondary label | — |
| L-10 | Section | 26 above, 1pt rule, 20 below it | — | separator | — |
| L-11 | Section title | 4 below | 13 semibold | label | — |
| L-12 | Section description | 12 below; 18pt lines; wraps at 404 | 12 | secondary label | — |
| L-13 | Tier list | column, gap 8 | — | — | — |
| L-14 | Tier | full width; padding 10 12; 1pt border, radius 8; amount (≥ 86 wide), 12, then name over flavor | amount 15 semibold monospaced digits; name 12.5 medium; flavor 11.5 | amount accent; flavor secondary label; border separator | hover: 6% label-color wash, accent border; focus: system ring |
| L-15 | Address list | column, gap 10 | — | — | — |
| L-16 | Address row | label + ticker over the address (gap 4), Copy 10 to the right, vertically centered | label 12 medium, ticker 12; address 11 monospaced, wraps at any character | ticker, address: secondary label | — |
| L-17 | Copy button | small push button, ≥ 58 wide | 11.5 | "Copy": stock; "Copied": accent | pressed: AppKit's |
| L-18 | Credits list | column, no gap | — | — | — |
| L-19 | Credit row | name left, license at the right edge (≥ 8 apart), baseline-aligned; 3 above and below | name 12; license 11 monospaced digits | name accent; license secondary label | name hover: underline |
| L-20 | Focus | every button takes AppKit's focus ring under full keyboard access | — | — | keyboard focus |

## Implementation notes

- **OS calls**: through `AboutModel`'s injected `opener` (`NSWorkspace`), `pasteboard`
  (`NSPasteboard`) and `sleep`; the tests inject a recording opener and pasteboard and a
  hand-released clock. The version comes from `Bundle.main`.
- **AppKit, not SwiftUI**: a never-shown window's SwiftUI buttons can't be pressed nor its text
  found, and every control here is one a test presses.
- **`NSButton` mouse tracking**: the three button classes act on mouse-up inside
  (`PressButton`) instead of AppKit's tracking loop, which a synthesized click never runs; a real
  click behaves the same.

## Checking the look

No `Visual/` scenario. `UITests.About/rendersInBothAppearancesWithoutClipping` renders the whole
page dark and light and fails if blank; with `TEST_RUNNER_TABS_SNAPSHOT_DIR` set (xcodebuild
passes it as `TABS_SNAPSHOT_DIR`) it writes `about-dark.png` and `about-light.png` there, to read
by eye.

## Notes

- Close Pane tested at the UI tier only: a hidden window is never key (A-5).
- Untested (unobservable in a never-shown window): pointing hand (F-6), real hover tracking (tests
  call `setHovered`), focus rings (L-20), the logged open failure (X-2). Never exercised: Dock/Finder
  icon, dragging the window, a real tier click reaching the browser (tests assert the URL handed
  over), the scroller with a mouse.
