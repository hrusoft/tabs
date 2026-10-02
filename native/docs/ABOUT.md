# About window

Application menu ▸ About Tabs: identity, version, donation tiers, crypto addresses, credits.
Port of Electron's About window as a standard native window.

## Scope

- Content, order, copy and behavior are Electron's; the look is the system's (titled window,
  native controls, semantic colors). No `Visual/golden` entry, no `VisualParityTests` row.
- Theme: follows the app's Theme setting like every window (inherits `NSApp.appearance`), not
  Electron's tokens (G-1).
- Credits: SwiftTerm only, the one linked package; license, no version column, no runtime rows.
- Payment links and addresses are generated from `app.config.ts`, never typed (see Money).
- Icon: the bundle's `AppIcon`, every size from the repo's `build/icon.icns` (built from
  `build/icon.svg`, same art as `resources/icon.png`).
- Shell chrome like Settings and Plugins, not a plugin: no control verbs, setting or shortcut;
  saves nothing.

## Sources

| Native | Electron | What |
|---|---|---|
| `Sources/Tabs/About/AboutWindow.swift` (`AboutWindowController`, `AboutPresenter`, `AboutBodyView`, `AboutMetrics`) | `src/renderer/src/about/AboutWindow.tsx`, `about.css`; `src/renderer/about.html`, `src/renderer/src/about-main.tsx`; `src/main/windows.ts` (`aboutWindow`, `auxiliaryWindow`, `openAboutWindow`) | Window, singleton, page |
| `AboutWindow.swift` (`AboutModel`; `PressButton`, `TierButton`, `LinkButton`, `CopyButton`) | `AboutWindow.tsx` (`CopyButton`, click handlers); `src/main/index.ts` (`windowOpenExternal`, `windowCopyText`, `windowGetAppInfoSync`) | What a press does; OS calls (`NSWorkspace`, `NSPasteboard`, `Bundle.main`) |
| `Sources/Tabs/UI/MainMenu.swift` (About item, `CommandRouter.close(keyWindow:)`), `AppDelegate.showAbout` | `src/main/menu.ts` (`appMenu`, Close Pane's `isAuxiliaryWindow` branch) | Opening; ⌘W |
| `Sources/Tabs/About/AboutContent.swift` (`Attributions`, `Donations`, `AboutCopy`, `ExternalURL`) | `src/shared/attributions.ts`, `src/shared/donations.ts`; `src/main/openExternal.ts`, `packages/plugin-sdk/shared/url.ts` (`isSafeExternalUrl`) | Credits, tiers, copy, URL vetting |
| `Sources/Tabs/About/AppConfig.generated.swift` ← `Scripts/sync-app-config.py` | `app.config.ts` | Payment links, addresses |
| `Sources/Tabs/Assets.xcassets/AppIcon.appiconset` | `resources/icon.png` | Icon |
| `Sources/Tabs/Testing/TestControlVerbs.swift` (`tabs.test.menu`, `tabs.test.about`, `tabs.test.click` with `window: "about"`) | `e2e/helpers/about.ts` | Debug, hidden-mode e2e hooks |

Tests: `UITests.About` (`Tests/TabsAppTests/AboutWindowTests.swift`; recording opener and
pasteboard, hand-released clock), `AboutContentTests` (data rules, credits reconciliation, money
drift), `AboutEndToEndTests` (built app over the control socket). Electron:
`src/renderer/src/about/__tests__/aboutWindow.test.tsx`, `src/shared/__tests__/attributions.test.ts`,
`e2e/about.spec.ts`.

## Cases

### Opening and closing

| Id | Case | Electron | Native test |
|---|---|---|---|
| A-1 | Application menu ▸ "About Tabs" opens it: a window of its own, not a view in (or a new) workspace window | `menu.ts` `appMenu` | `UITests.About/presentingItTwiceGivesTheOneWindow`, `AboutEndToEndTests/theApplicationMenuOpensARealAboutWindow` |
| A-2 | Again while open → that window comes forward; never a second | `windows.ts` `auxiliaryWindow.open` | `UITests.About/presentingItTwiceGivesTheOneWindow`, `AboutEndToEndTests/openingItTwiceFocusesTheOneWindowRatherThanMakingASecond` |
| A-3 | Titled "About Tabs"; content 460×630 (Electron's 460×660 less its drawn 30pt bar; the native title bar is outside); not resizable, zoomable or fullscreenable; no parent (can sit on another Space) | `windows.ts` `aboutWindow` | `UITests.About/theWindowIsAStandardFixedSizeWindow`, `AboutEndToEndTests/itIsAFixedSizeIndependentWindowThatIsNeverShownWhenHidden` |
| A-4 | **Deviation:** system title bar and buttons (Electron: hidden title bar, drawn "About" bar, traffic lights at (14, 9)) | `windows.ts` `hiddenTitleBar` | `UITests.About/theWindowIsAStandardFixedSizeWindow` |
| A-5 | ⌘W / File ▸ Close Pane with About key closes About; workspace untouched (router: a key non-workspace window gets `performClose`) | `menu.ts` `isAuxiliaryWindow` | `UITests.About/closePaneWithTheAboutWindowKeyClosesThatWindowNotAPane` |
| A-6 | Closing (or a test reset) drops the singleton → next open is a fresh window, scrolled to the top. A stale window's close never clears a newer one | `windows.ts` `closed` handler | `UITests.About/closingDropsTheWindowAndTheNextOneIsFresh`, `UITests.About/aStaleWindowClosingLeavesANewerOneInPlace`, `AboutEndToEndTests/aResetClosesItSoTheNextOneIsFresh` |
| A-7 | **Deviation:** system window background (Electron: theme `--bg` painted before content) | `windows.ts` `baseWindowOptions` (`backgroundColor`) | — |
| A-8 | **n/a:** About in the Help menu (Electron: off macOS only) | `menu.ts` | — |
| A-9 | Hidden mode (`TABS_E2E_HIDDEN=1`): built, never shown or focused | `windows.ts` `showWhenReady`, `e2eHidden` | `UITests.About/presentingItTwiceGivesTheOneWindow`, `AboutEndToEndTests/itIsAFixedSizeIndependentWindowThatIsNeverShownWhenHidden` |

### Identity

| Id | Case | Electron | Native test |
|---|---|---|---|
| B-1 | 72×72 app icon, decorative (not an accessibility element; the name follows) | `.about-icon` (`alt=""`) | `UITests.About/theIconIsDecorativeAndSeventyTwoPoints` |
| B-2 | Name "Tabs" (Electron: `<h1>`; native: static text) | `.about-name` | `UITests.About/showsTheAppsIdentityWithTheRunningVersion`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| B-3 | "Version <v>": the running bundle's `CFBundleShortVersionString`, never a literal; read once at creation; the block's only selectable line | `.about-version`, `useAppInfo` | `UITests.About/showsTheAppsIdentityWithTheRunningVersion`, `UITests.About/theRealModelReadsTheBundlesVersion`, `UITests.About/onlyTheVersionAndTheAddressesAreSelectable`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| B-4 | Tagline "A fancy terminal with tabs, splits, and nested layouts." | `.about-tagline` | `UITests.About/showsTheAppsIdentityWithTheRunningVersion`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| B-5 | "Copyright © 2026 Hrusoft. All rights reserved." | `.about-copyright` | ″ |

### Donation tiers

| Id | Case | Electron | Native test |
|---|---|---|---|
| C-1 | Title "Buy me a coffee"; "Like this app? You can buy me a coffee to fuel future development." | `DonationsSection` | `UITests.About/offersEachTierWithItsAmountNameAndFlavor`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| C-2 | Three full-width tier buttons, cheapest first: `$4 USD` Coffee, "One cup, one bug fixed. Roughly." · `$20 USD` A pack of roasted beans, "Enough to get through a whole feature." · `$200 USD` I'm rich, I'll buy you a nice grinder, "Burr, not blade. You have excellent taste." | `DONATION_TIERS`, `formatDonationAmount` | `UITests.About/offersEachTierWithItsAmountNameAndFlavor`, `AboutContentTests/offersTheThreeTiersCheapestFirst`, `AboutContentTests/formatsAnAmountWithItsCurrency`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| C-3 | A press anywhere on a tier → that tier's own payment link to the OS browser; never navigates the window. Links distinct and openable | tier `onClick` → `openExternal` | `UITests.About/pressingATierSendsItsOwnLinkToTheBrowser`, `UITests.About/aTierTakesThePressOnAnyOfItsParts`, `AboutContentTests/givesEveryTierADistinctIdAndItsOwnLink`, `AboutContentTests/keepsEveryTierLinkOpenable` |
| C-4 | Hover: 6% wash + accent border | `.about-tier:hover` | `UITests.About/tiersShowTheHoverWashAndAnAccentBorder` |
| C-5 | Amount column ≥ 86pt → every name starts at the same x | `.about-tier-amount` | `UITests.About/everyTiersNameStartsAtTheSameX` |
| C-6 | Amount in tabular (monospaced) digits; currency USD, what the links are priced in (unverifiable: the price lives in Stripe) | `DONATION_CURRENCY` | `AboutContentTests/formatsAnAmountWithItsCurrency` |

### Crypto

| Id | Case | Electron | Native test |
|---|---|---|---|
| D-1 | Title "Or in crypto"; "Same idea, no card involved. Copy an address and send whatever you like." | `CryptoSection` | `UITests.About/showsEveryAddressInFullWithItsLabelAndTicker` |
| D-2 | A row per chain (Bitcoin BTC, Ethereum ETH): label + dim ticker; full address in mono, wrapped at any character, never truncated, selectable; Copy beside | `CRYPTO_ADDRESSES` | `UITests.About/showsEveryAddressInFullWithItsLabelAndTicker`, `UITests.About/onlyTheVersionAndTheAddressesAreSelectable`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| D-3 | Copy puts that address, and only it, on the system pasteboard | `CopyButton` → `copyText` | `UITests.About/copyPutsTheAddressOnThePasteboardAndOnlyThat`, `AboutEndToEndTests/aCopyButtonPutsTheAddressOnTheRealSystemPasteboard` |
| D-4 | The pressed button reads "Copied" (accent) for 1.5 s, then "Copy"; others unaffected, each on its own timer. Electron also turns the border accent | `CopyButton` | `UITests.About/aPressedButtonSaysCopiedForAMomentAndOnlyThatOne`, `UITests.About/eachButtonKeepsItsOwnTimer`, `AboutEndToEndTests/aCopyButtonPutsTheAddressOnTheRealSystemPasteboard` |
| D-5 | Pressing again within the 1.5 s restarts it | `CopyButton` (`clearTimeout`) | `UITests.About/pressingAgainRestartsTheConfirmation` |
| D-6 | Closing with a confirmation pending leaves no timer (`AboutModel.stop` from `windowWillClose`) | `CopyButton` unmount cleanup | `UITests.About/closingTheWindowLeavesNoTimerBehind` |
| D-7 | Copy ≥ 58pt wide: "Copied" never shifts the address column | `.about-copy` | `UITests.About/theCopyButtonKeepsItsWidthWhenItSaysCopied` |
| D-8 | **Deviation:** native small push button with AppKit's pressed feedback; no hover wash or dim→text color | `.about-copy:hover` | — |
| D-9 | Every address has a distinct id and a non-empty value | `CRYPTO_ADDRESSES` | `AboutContentTests/givesEveryCryptoAddressADistinctIdAndANonEmptyValue` |

### Credits

| Id | Case | Electron | Native test |
|---|---|---|---|
| E-1 | Title "Built with"; "Tabs would not be possible without these projects." | `AttributionsSection` | `UITests.About/creditsEveryPackageWithItsLicense` |
| E-2 | **Deviation:** no runtime rows (Electron: Electron, Chromium, Node.js with their running versions); the native app has none | `RUNTIME_COMPONENTS` | — |
| E-3 | The linked packages, alphabetical, each with its license (SwiftTerm, MIT) | `ATTRIBUTIONS` | `UITests.About/creditsEveryPackageWithItsLicense`, `AboutContentTests/listsThePackagesAlphabetically`, `AboutEndToEndTests/showsTheBuiltAppsVersionAndEverythingItOffers` |
| E-4 | Name is a link-styled button (accent; underline on hover) → its URL to the OS browser. Nothing on the page is a real link | `CreditItem` | `UITests.About/pressingACreditOpensItsURLInTheBrowserNotInTheWindow`, `UITests.About/aCreditNameUnderlinesWhileHoveredAndIsAccentColored` |
| E-5 | Name left, license at the right edge, baseline-aligned, so licenses line up. Two columns (no version column) | `.about-credit` grid `1fr auto auto` | `UITests.About/theLicenseLinesUpAtTheRightEdge` |
| E-6 | The list is exactly what ships: reconciled both ways against the `packages:` keys of `project.yml` and every `Plugins/*/plugin.yml`; no duplicates; each has a license and an openable URL. A dependency declared any other way escapes the check | `src/shared/__tests__/attributions.test.ts` (vs `package.json`) | `AboutContentTests/creditsExactlyThePackagesTheBuildLinks`, `AboutContentTests/namesNoPackageTwice`, `AboutContentTests/givesEveryEntryALicenseAndAnOpenableURL` |

### Scrolling and layout

| Id | Case | Electron | Native test |
|---|---|---|---|
| F-1 | The window never grows; the body scrolls | `.about-body` (`overflow-y: auto`) | `UITests.About/sectionsComeInOrderAndTheWindowScrollsRatherThanGrowing` |
| F-2 | At rest the identity and all three tiers are above the fold; the credits need scrolling | `aboutWindow` size | `UITests.About/theIdentityAndAllThreeTiersAreAboveTheFold` |
| F-3 | Order: identity, donations, crypto, credits | `AboutWindow` | `UITests.About/sectionsComeInOrderAndTheWindowScrollsRatherThanGrowing` |
| F-4 | **Deviation:** the system title bar moves the window (Electron: `.window-titlebar` drag region) | `-webkit-app-region: drag` | — |
| F-5 | Only the version and the addresses are selectable | `body { user-select: none }`, `.about-version`, `.about-address-value` | `UITests.About/onlyTheVersionAndTheAddressesAreSelectable` |
| F-6 | Pointing hand over tiers, credit names and Copy buttons (cursor rects) | `cursor: pointer` | — (not observable in a never-shown window) |

### Theme

| Id | Case | Electron | Native test |
|---|---|---|---|
| G-1 | Follows the app's Theme setting (dark, light, system), live: inherits `NSApp.appearance`, pinned by `AppShell.applyPaneSettings`. **Deviation:** system semantic colors, not Electron's tokens | `installTheme()` | `UITests.About/rendersInBothAppearancesWithoutClipping`; mechanism: `UITests.Appearance/everyWindowFollowsTheSettingNotTheOS` (About not in it) |

### Persistence and control

| Id | Case | Electron | Native test |
|---|---|---|---|
| H-1 | Nothing saved (frame, scroll); each new window opens centered, at the top | `auxiliaryWindow` | `UITests.About/closingDropsTheWindowAndTheNextOneIsFresh` |
| H-2 | No control verbs, setting or shortcut (the `tabs.test.*` hooks are Debug-only) | — | — |

### Errors and edge cases

| Id | Case | Electron | Native test |
|---|---|---|---|
| X-1 | A URL that isn't http(s)/mailto is dropped silently, never opened (`ExternalURL.vetted`) | `openExternalUrl`, `isSafeExternalUrl` | `UITests.About/opensNothingThatIsNotAWebOrMailLink`, `AboutContentTests/opensOnlyWebAndMailLinks`, `AboutContentTests/refusesEverythingElse` |
| X-2 | The OS declining to open → logged to stderr (`AboutModel.openInBrowser`), never fatal | `openExternalUrl` `.catch` | — (needs a URL the OS can't open) |
| X-3 | Works with no workspace window open: `AboutPresenter` is independent of them | `auxiliaryWindow` | — |

## Money

- `app.config.ts` (repo root) is the one source of payment links and receiving addresses. Never
  edit it, nor let an agent; a wrong value renders fine and pays a stranger.
- `Scripts/sync-app-config.py` copies its `paymentLinks` and `cryptoAddresses` blocks into
  `Sources/Tabs/About/AppConfig.generated.swift` (committed): one constant per key plus an `all`
  map. Narrow parse: only `key: 'string'` lines; anything else, an empty block or a repeated key
  exits with an error.
- `--check` (run by `make lint`) exits 1 when the generated file is stale → rerun the script.
- `AboutContentTests/theGeneratedPaymentLinksAreAppConfigsOwn`,
  `AboutContentTests/theGeneratedAddressesAreAppConfigsOwn`: parse `app.config.ts` independently
  and compare. `AboutContentTests/everyTierAndAddressReadsItsOwnConfiguredValue`: each tier and
  address reads its own key; no configured key goes unshown.
- Tiers read `AppConfig.PaymentLinks.<id>` by name, so a renamed key is a compile error. The copy
  (names, flavor text, currency) is typed in `AboutContent.swift`, as in `donations.ts`.

## Look

Not held to Electron's pixels. Every margin, gap, font size and weight of `about.css` carries over
as points (`AboutMetrics`, the labels' fonts); colors are system semantic ones.

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
| L-17 | Copy button | small native push button, ≥ 58 wide | 11.5 | "Copy": stock; "Copied": accent | pressed: AppKit's |
| L-18 | Credits list | column, no gap | — | — | — |
| L-19 | Credit row | name left, license at the right edge (≥ 8 apart), baseline-aligned; 3 above and below | name 12; license 11 monospaced digits | name accent; license secondary label | name hover: underline |
| L-20 | Focus | every button takes AppKit's focus ring under full keyboard access | — | — | keyboard focus |

## Electron quirks kept for parity

- No real links: every URL is a button handing it to the OS (a link would navigate the window away
  from About).
- Addresses wrap at any character, never truncated: Copy is only trustworthy if the whole address
  shows.
- Amount column 86 wide, sized for "$200 CAD" though the currency is USD; a five-digit tier needs
  it retuned.
- Each Copy button has its own confirmation and timer: two can say "Copied" at once.

## Can't be ported as-is

- **Runtime credits** (`process.versions`): no Electron, Chromium or Node.js here (E-2).
- **The bridge** (`window.api.appWindow`): direct `NSWorkspace`, `NSPasteboard`, `Bundle.main`.
  The fake bridge's role is `AboutModel`'s injected `opener`, `pasteboard` and `sleep`.
- **Drawn chrome** (`hiddenTitleBar`, `trafficLightPosition`, `-webkit-app-region: drag`): the
  system title bar (A-4, F-4).
- **SwiftUI**: keep the page AppKit. A never-shown window's SwiftUI buttons can't be pressed nor
  its text found (`.claude/skills/port-to-native/reference/appkit-testing.md`), and every control
  here is one a test presses.
- **`NSButton` mouse tracking**: the three button classes act on mouse-up inside
  (`PressButton`) instead of AppKit's tracking loop, which a synthesized click never runs; a real
  click behaves the same.

## Checking the look

No Electron capture. `UITests.About/rendersInBothAppearancesWithoutClipping` renders the whole page
dark and light and fails if blank; with `TEST_RUNNER_TABS_SNAPSHOT_DIR` set (xcodebuild passes it
as `TABS_SNAPSHOT_DIR`) it writes `about-dark.png` and `about-light.png` there, to read by eye.

## Known differences

- System chrome, background, controls and colors: A-4, A-7, D-4 (no accent border), D-8, F-4, G-1.
- Credits: E-2, E-5.
- Close Pane tested at the UI tier only: a hidden window is never key (A-5).
- Untested (unobservable in a never-shown window): pointing hand (F-6), real hover tracking (tests
  call `setHovered`), focus rings (L-20), the logged open failure (X-2). Never exercised: Dock/Finder
  icon, dragging the window, a real tier click reaching the browser (tests assert the URL handed
  over), the scroller with a mouse.
