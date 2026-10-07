# Terminal

Interactive login shells in panes, drawn by SwiftTerm: plugin `Plugins/Terminal` (id and
content type `terminal`), SDK only.

## Scope

- The look follows the settings; no visual scenario captures terminal content.
- SwiftTerm unpatched, behind the `TerminalSurface` seam (libghostty could replace it); its
  gaps are listed under Notes.
- Header controls are core-drawn `PaneController.headerActions`; the close/quit dialog is
  core's, for every plugin.
- GPU rendering = Metal, new panes only, off by default.
- Restored background terminals start their shells at launch.
- No Option-as-Meta setting.
- Test hooks: Debug-only verb `terminal.test.state`.

## Sources

Under `Plugins/Terminal/Sources/` unless marked core or shell.

| File | What |
|---|---|
| `../Info.plist` | Identity: `terminal`, "Terminal", can be disabled |
| `TerminalPlugin.swift` | Content type, bell kind `terminal.bell`, command `terminal.clearBuffer`, settings page; links (`TerminalLinks`); `deactivate` ends every shell |
| `TerminalSettings.swift` | Settings, Clear Dark defaults. Stored values merge over defaults at every depth (SDK) |
| `Shell.swift` | Pure: shell, start directory, environment, locale |
| `ShellProcess.swift` | One shell on one pty (below) |
| `ProcessProbe.swift` | Live cwd (`PROC_PIDVNODEPATHINFO`), foreground group (`pbi_pgid` vs `e_tpgid`), name (`proc_name`). Sync syscalls, no timeout; failure → nil |
| `TerminalPane.swift` | Pane controller: shell + surface, sizing, settings, titles, bell, clear, close warning, live directory |
| `TerminalSurface.swift` | `TerminalSurface` seam; `SwiftTermSurface`, `TerminalContainerView` (padding), `TabsTerminalView` (paste, right-click) |
| `TerminalGlyphs.swift` | Template images drawn from SVG paths: terminal, clear scrollback, bell |
| `TerminalSettingsPage.swift` | SwiftUI page. Colors via one shared `NSColorPanel` (`ColorPanelEditor`): many live `NSColorWell`s break unrelated views |
| `TerminalTestVerbs.swift` | Debug `terminal.test.state`: `pid`, `columns`/`rows`, `ptyColumns`/`ptyRows`, `screen`, `buffer`, `alternateScreen`, `exited`, `cwd`, `focused` |
| core `PaneController.headerActions`, shell `PaneActionButton` | Clear scrollback button |
| core `CloseConfirmation`, `closeWarning`, `LayoutEngine.shouldClose`/`shouldQuit` | Close/quit confirmation |
| core `PaneSignals` | Bell |
| core `PaneContext.setTitle`, `titleIsManual` | OSC titles |
| core `PaneCreation.origin`, `PaneCapability.workingDirectory` | cwd inheritance, both ways |
| core `PaneContext.childEnvironment` | App env minus `TABS_DATA_DIR`/`TABS_LISTEN_SOCKET`/`TABS_E2E_HIDDEN`/`TABS_E2E_PLUGINS`, plus `TABS_CONTROL_SOCKET`, `TABS_PANE_ID` |
| shell main-menu key equivalents, `WorkspaceInput` | App shortcuts beat the shell (T-126) |

## Shell process (`ShellProcess`)

- `forkpty`'s steps (`openpty`, `fork`, `login_tty`; `fork` through `dlsym`, as Swift doesn't
  offer it): new session, pty as controlling terminal; `IUTF8` on. Not `posix_spawn` +
  `setsid`: no controlling terminal (zsh reopens its tty `O_NOCTTY` → no job control, no ⌃C).
- The app keeps the pty's replica open until the exit is reaped (`forkpty` closes it). Else the
  shell's exit can be the terminal's last close, which keeps unread output only 0.6 s (zsh's
  exit does, sh's doesn't): a reader late under load lost the last output. With it, the exit
  waits for the reader, then revokes the terminal.
- Fork → exec: syscalls only (argv, envp, cwd built before): signals 1–31 `SIG_DFL`, mask
  cleared, fds ≥ 3 closed, `chdir`, `execve`. Never `setenv`/`chdir` in the app.
- `access(X_OK)` before forking: a failed exec can't report.
- Reads on a private queue, ≤ 256 KB per main-actor hand-off, in order, last output before the
  exit. Paused while > 1 MB (`highWater`) waits to be drawn, resumed at 256 KB.
- Writes never block: `O_NONBLOCK`; `EAGAIN` → retry after 10 ms, doubling to 250 ms.
- `terminate()`: synchronous (runs at quit), idempotent; SIGHUP only while unreaped (pid can't
  be reused); closes the pty (resumes a suspended read source first, or its cancel handler never
  runs).
- Exit: dispatch process source, plus one check at start (it may exit before the watch). The
  event comes once, and can come before the zombie: a watch begun mid-exit is reported as an exit
  at once, and XNU posts it before marking the zombie. So `waitpid(WNOHANG)` is retried, 1 ms
  doubling to 100 ms, never blocking (the exit may be waiting for the reader).

## Cases

Pane, UI and end-to-end tests run real `$SHELL -l` login shells on the tests' own startup
files: `ZDOTDIR` is a temp directory per test process (`TestShell`, in `Tests/Support` and
`Tests/EndToEndSupport`) whose `.zprofile` exports `TABS_TEST_ZPROFILE=1` and whose `.zshrc`
sets `TABS_TEST_ZSHRC=1` and unsets `HISTFILE` (no history written). One canary runs your own
dotfiles: `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard`. Only zsh reads
`ZDOTDIR`: with another `$SHELL` every test runs your dotfiles, and
`TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane` fails. Tests wait for computed markers
(`echo X-$((1+1))` → `X-2`), never a prompt. `—`: nothing drives it (mostly input a
never-shown window can't get).

### The shell

| Id | Case | Test |
|---|---|---|
| T-1 | New terminal (empty pane's button, or a new tab/split like a terminal) → interactive login shell `$SHELL -l`, startup files run | `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |
| T-2 | Shell: `$SHELL` if non-empty, else `/bin/zsh` if it exists, else `/bin/bash` (even if missing; never throws). A shell that can't start → dim `[could not start <shell>: <error>]`, pane kept as exited | `ResolveShellTests` (5), `TerminalProcessTests/aMissingExecutableThrows` |
| T-3 | Start directory from config `cwd`: absent, `""`, `~` → home; `~/x` → home/x; absolute kept; no longer a directory → home | `ResolveCwdTests` (5), `TerminalProcessTests/theEnvironmentAndDirectoryAreApplied`, `TerminalPaneTests/aDeletedSavedDirectoryStartsAtHome` |
| T-4 | New pane without origin seeded `{cwd: "~"}` | `TerminalPluginTests/aNewPaneIsSeededToStartAtHome` |
| T-5 | Env: `childEnvironment` + `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Tabs`, `TERM_PROGRAM_VERSION` (bundle version), over inherited values. `LANG=<lang>_<region>.UTF-8` (if in `/usr/share/locale`, else `en_US.UTF-8`) only when `LANG`/`LC_ALL`/`LC_CTYPE` are all empty: a Finder-launched app has none, and in the C locale zsh's line editor shows non-ASCII as escapes | `EnvironmentTests` (3), `TerminalProcessTests/theEnvironmentAndDirectoryAreApplied`, `TerminalSharedAppEndToEndTests/theShellIsToldWhatTerminalItIsIn` |
| T-6 | `TABS_CONTROL_SOCKET` (per-boot socket), `TABS_PANE_ID` (this pane); launch settings stripped. Core's caller check (`ControlPlane.dispatch`) accepts any open pane, an exited shell's too (BROWSER.md H-1) | `EnvironmentTests/statesTheTerminalsIdentityOverInheritedValues`, `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `TerminalSharedAppEndToEndTests/theShellIsToldWhatTerminalItIsIn` |
| T-7 | Controlling terminal + job control (`fg`, ⌃Z, ⌃C reach the foreground job); every signal default and unblocked, whatever the app ignores (`nohup`) | `TerminalProcessTests/thePtyIsTheControllingTerminal`, `…/anIgnoredSignalIsntInherited`, `UITests.TerminalUITests/theShellControlsItsTerminalAndCtrlCInterrupts` |
| T-8 | pty starts at the pane's size (one turn after creation, once laid out); a hidden pane's catches up when shown (T-37) | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored` |
| T-9 | Shell exits (`exit`, ⌃D) → dim `[process exited]` on its own line; pane and output stay; typing goes nowhere; no close warning; offers no directory | `TerminalProcessTests/outputArrivesInOrderAndBeforeTheExit`, `…/anExitIsReportedWhenWatchingBeginsLate`, `…/theLastOutputWaitsForALateReader`, `TerminalPaneTests/anExitedShellKeepsItsPane` |
| T-10 | pty never outlives its pane: close → SIGHUP, pty closed, reaped; `deinit` terminates as a safety net | `TerminalProcessTests/terminatingEndsAndReapsTheShell`, `TerminalPaneTests/closingThePaneEndsItsShell`, `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-11 | Each pane's shell pid readable by tests: `terminal.test.state` | `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |

### Output, input and the emulator

| Id | Case | Test |
|---|---|---|
| T-20 | Typed keys reach the shell; output drawn; 256-color (xterm palette) and 24-bit escapes render (color depth untested) | `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |
| T-21 | Output arriving while the pane is a hidden tab is kept | `TerminalPaneTests/outputWhileHiddenIsKept`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-22 | Full-screen programs (vim, less, htop): alternate screen, screen back on exit (SwiftTerm) | — |
| T-23 | Mouse selection: drag, double-click word, triple-click line; ⌘C copies (Edit ▸ Copy) (SwiftTerm) | — |
| T-24 | ⌘V pastes (Edit ▸ Paste): `\r\n`/`\n` → `\r`, bracketed when the program asked (`TabsTerminalView.paste`); a paste larger than the pty buffer arrives whole | `TerminalProcessTests/aLargeWriteArrivesWhole` |
| T-25 | Right-click selects the word under it (a synthesized double-click), unless a program has the mouse | — |
| T-26 | Option types the layout's characters (é, ∑), not Meta (`optionAsMetaKey = false`). Option+←/→/⌫ send nothing; ⌥⌘O toggles Option-as-Meta for that pane (SwiftTerm `keyDown`; no app chord takes it) | — |
| T-27 | ⌃ keys reach the shell (⌃C, ⌃R, ⌃A…); no default app shortcut is a bare ⌃ letter. ⌃2…⌃/ send nothing (SwiftTerm) | `UITests.TerminalUITests/theShellControlsItsTerminalAndCtrlCInterrupts` (⌃C) |
| T-28 | Mouse reporting to programs that ask (vim `mouse=a`, htop); right/middle buttons unreported (SwiftTerm) | — |
| T-29 | Wheel scrolls the scrollback; on the alternate screen without mouse reporting it sends arrows (SwiftTerm) | — |
| T-30 | Focus reporting (`CSI ?1004`), IME composition; focus reports only on first-responder changes (SwiftTerm) | — |
| T-31 | Bold uses the bright palette, for colors 0–6 only, not white (SwiftTerm) | — |
| T-32 | Cursor blinks only while focused; unfocused it's an outline (SwiftTerm) | — |
| T-33 | A flood (`yes`, `cat` of a huge file) never grows memory unbounded; ⌃C stops it at once (pty paused above 1 MB in flight; the program is held back, nothing dropped) | `TerminalProcessTests/aFloodIsPacedByTheMainActorAndCtrlCStopsIt` |

### Size

| Id | Case | Test |
|---|---|---|
| T-35 | Pane resize (window, split, separator) → pty resize: SIGWINCH, `stty size` agrees. Core sizes the view by autoresizing and by layout; the container follows both | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored`, `TerminalPluginTests/theTerminalFollowsItsPanesSizeThroughAutoresizing`, `TerminalPaneTests/aHiddenPaneNeverResizesThePtyButCatchesUpWhenShown` |
| T-36 | Hidden pane (background tab) never resizes the pty (no SIGWINCH for tab switches); the grid keeps its size too | `TerminalPaneTests/aHiddenPaneNeverResizesThePtyButCatchesUpWhenShown`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-37 | A pane first shown later (restored background tab) takes its real size then, once | ″ |
| T-38 | Resize to 0 cols or rows ignored | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored` |
| T-39 | Font, size or line-height change re-fits and resizes the pty (while shown) | `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` |

### Title

| Id | Case | Test |
|---|---|---|
| T-40 | OSC 0/2 → pane's header title | `TerminalPaneTests/oscTitlesTitleThePane`, `…/aShellsOscTitleReachesThePane` |
| T-41 | A manual title isn't replaced by OSC titles | `TerminalPaneTests/aManualTitleWinsAndClearingItShowsTheLatestOscTitle` |
| T-42 | Clearing the manual title shows the shell's latest OSC title, "Terminal" if none | ″ |
| T-43 | Empty OSC title → "Terminal" | `TerminalPaneTests/oscTitlesTitleThePane` |
| T-44 | A terminal's tab is titled "Terminal"; so is a new tab/split made from one | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |

### Staying alive when the layout changes

| Id | Case | Test |
|---|---|---|
| T-50 | Moving its tab to another group: same shell (pid), scrollback | — (drags can't be synthesized) |
| T-51 | New tab on a bare terminal promotes it into a group (same shell, scrollback, view) beside a new, separate terminal | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-52 | Closing the tab beside it collapses the group back (same shell, scrollback); the closed one's shell ends | ″ |
| T-53 | Splitting a sibling pane leaves an unrelated terminal alone | `UITests.TerminalUITests/splittingASiblingKeepsTheTerminal` |
| T-54 | Opening a terminal on a pane holding one → two tabs, two shells (core; the palette: NEW-CONTENT.md C-1) | — |
| T-55 | Away from its tab and back: same shell, output that arrived meanwhile shown | `TerminalPaneTests/outputWhileHiddenIsKept`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-56 | Wrapping it in a tab group (header control, root bar) keeps the shell | `UITests.TerminalUITests/wrappingInAGroupKeepsTheShell` |
| T-57 | Pane drags (center merge, edge dock) keep shell and scrollback | — (drags can't be synthesized; the moves they commit are, T-51…T-59) |
| T-58 | Unpin (floating) and pin back keep the shell | `UITests.TerminalUITests/unpinningAndPinningKeepTheShell` |
| T-59 | Moving a terminal (or a group of two) to another window keeps shells and scrollback | `UITests.TerminalUITests/movingToAnotherWindowKeepsTheShellAndItsOutput` (the engine's move, no drag) |
| T-60 | Output printed during the move arrives in the destination | ″ |
| T-62 | Clear pane (header) empties it in place and ends the shell; the title-bar close collapses the split and ends it | `TerminalPaneTests/closingThePaneEndsItsShell` (close only) |

### Ending

| Id | Case | Test |
|---|---|---|
| T-65 | Closing a window (not the last) ends its shells | `UITests.TerminalUITests/closingAWindowEndsItsShells` |
| T-66 | Closing the last window ends its shells; layout kept; New Window brings it back on fresh shells | — |
| T-67 | Two windows closed together both end their shells | — |
| T-68 | Quit ends every shell (`deactivate` → `endAll`), not only closed panes' | `TerminalPluginTests/deactivatingEndsEveryShell`, `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas` |
| T-69 | Crash or SIGKILL of the app leaves no shell: the pty master closes → SIGHUP | `TerminalEndToEndTests/aCrashStillRestoresTheLiveDirectory` |

### Close and quit confirmation

| Id | Case | Test |
|---|---|---|
| T-70 | Closing a pane/tab whose shell has a foreground job (terminal's group ≠ the shell's) asks first, naming it: `<name> is still running` (`A process is still running` if unnamed). Idle prompts and background jobs (`cmd &`) never ask | `TerminalProcessTests/theForegroundGroupNamesARunningCommandOnly`, `TerminalPaneTests/aRunningCommandWarnsBeforeClosing`, `UITests.TerminalUITests/aRunningCommandMakesClosingWarn`, `CloseConfirmationTests/onlyQuittingAsksAsAQuit` |
| T-71 | Same for closing a window and quitting, every busy pane listed | `CloseConfirmationTests/onlyQuittingAsksAsAQuit`, `…/quittingGoesAheadWithQuitAnyway` |
| T-72 | Core's words, for every plugin: title "A pane is still busy" / "N panes are still busy"; detail `• <warning>` per pane (`• vim is still running`), then "Closing will end it/them immediately."; buttons Cancel (default, Escape), then "Close Anyway" / "Quit Anyway" | `CloseConfirmationTests/oneWarningIsOneBulletAndClosingEndsIt`, `…/severalWarningsAreCountedAndListedInOrder`, `…/quittingGoesAheadWithQuitAnyway` |
| T-73 | Cancel keeps everything; a failed probe counts as nothing running | `TerminalPaneTests/aRunningCommandWarnsBeforeClosing` |

### Bell

| Id | Case | Test |
|---|---|---|
| T-75 | BEL (`\a`) in a pane the user isn't looking at raises `terminal.bell`: icon + pulsing alert outline, on every tab holding it. No sound: our `bell(source:)` replaces SwiftTerm's `NSSound.beep` | `TerminalPaneTests/aBellRaisesTheBellSignalWhenUnseen`, `…/aShellsBellReachesThePane`, `TerminalPluginTests/theBellIsAPulsingAlertSignalUntilSeen`, `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-76 | A bell in the pane being looked at (active pane, focused window) is dropped | `TerminalPaneTests/aBellInThePaneBeingLookedAtIsDropped`, `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-77 | A bell in the active pane of an unfocused window flags it; cleared when the window regains focus (core) | `PaneSignalsTests/aBellInTheActivePaneOfAnUnfocusedWindowFlagsIt`, `…/windowFocusClearsTheActivePanesBellOnly` |
| T-78 | Focusing the pane clears its bell; other panes' stay | `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-79 | Dock bounces (informational) on a bell while the window isn't focused | `TerminalPaneTests/aBellRaisesTheBellSignalWhenUnseen`, `PaneSignalsTests/aKindAskingForAttentionBouncesTheDockEveryTimeWhileUnfocused` |
| T-80 | Settings ▸ Panes & Tabs switch "Bell indicator" ("Pulse a bell icon and bounce the Dock icon when a terminal rings its bell."), on by default; off → dropped, no bounce | `TerminalPluginTests/theBellIsAPulsingAlertSignalUntilSeen`, `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `PaneSignalsTests/aSwitchedOffBellIsDroppedWithoutBouncing` |

### Links

| Id | Case | Test |
|---|---|---|
| T-85 | ⌘-click a plain-text URL → default browser, no dialog | — |
| T-86 | ⌘-click an OSC 8 hyperlink → its target, not its text | — |
| T-87 | A plain click on a link opens nothing (focuses the pane) | — |
| T-88 | Left button only (right-click, ⌃-click never) | — |
| T-89 | Only `http:`, `https:`, `mailto:` open (scheme case-insensitive), OSC 8 links included; `file:`, custom schemes dropped | `TerminalLinksTests/opensOnlyHttpHttpsAndMailto`, `…/dropsEverythingElse` |
| T-90 | A link shows as one only while ⌘ is held: dashed underline, I-beam kept, URL preview; file paths are underlined too (don't open) (SwiftTerm) | — |

### Clearing

| Id | Case | Test |
|---|---|---|
| T-95 | Edit ▸ Clear Buffer (⌘K) clears the active terminal, scrollback included: the cursor's line becomes the first, nothing above | `TerminalPaneTests/clearBufferClearsScreenAndScrollback`, `…/clearingALiveShellKeepsItWorking`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-96 | …but does nothing on the alternate screen (a TUI keeps its screen) | `TerminalPaneTests/clearBufferLeavesTheAlternateScreenAlone`, `UITests.TerminalUITests/commandKLeavesTheAlternateScreenAlone` |
| T-97 | ⌘K with another type's pane active: disabled, nothing cleared | `TerminalInheritanceFromOtherTypesTests/clearBufferIsForTheActiveTerminalOnly`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-98 | Header Clear scrollback (id `pane-terminal-clear-scrollback-button`, leftmost in the hover controls; three tapering rows + small ×) = ⌘K, alt-screen rule included | `TerminalPluginTests/offersTheClearScrollbackHeaderAction`, `TerminalPaneTests/theHeaderActionClearsLikeTheCommand`, `UITests.TerminalUITests/theHeaderClearScrollbackButtonClearsButNotTheAlternateScreen` |

### Working directory

| Id | Case | Test |
|---|---|---|
| T-100 | New tab/split from a terminal starts in that shell's live directory (after `cd`), read fresh, inheritance on | `TerminalPaneTests/aNewTerminalFromATerminalStartsInItsLiveDirectory`, `TerminalProcessTests/theWorkingDirectoryFollowsCd` |
| T-101 | Inheritance off → `~` | `TerminalPaneTests/withInheritanceOffANewTerminalStartsAtHome` |
| T-102 | From another type's pane → the directory it offers | `TerminalInheritanceFromOtherTypesTests/startsWhereAnotherTypesPaneOffers`, `UITests.TerminalUITests/aTerminalFromAPaneOfferingADirectoryStartsThere` |
| T-103 | A terminal offers its live directory to other types, whatever its inheritance setting: at start, then 150 ms after output (a `cd` prints a prompt) | `TerminalPaneTests/aTerminalOffersItsLiveDirectoryEvenWithInheritanceOff`, `UITests.TerminalUITests/aTerminalOffersItsShellsLiveDirectory` |
| T-104 | Origin offering nothing (empty pane, exited shell) → `~` | `TerminalPaneTests/anExitedOriginGivesHome`, `TerminalInheritanceFromOtherTypesTests/anOriginThatOffersNothingGivesHome` |

### Persistence

| Id | Case | Test |
|---|---|---|
| T-105 | Relaunch restores terminals: same layout, each on a fresh shell (new pid) that works | `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas` |
| T-106 | Restarts in its live directory, saved at every save (`currentConfig`: live ?? last offered ?? start), so a crash keeps it | `TerminalPaneTests/aNewTerminalFromATerminalStartsInItsLiveDirectory`, `TerminalProcessTests/theWorkingDirectoryFollowsCd`, `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas`, `…/aCrashStillRestoresTheLiveDirectory` |
| T-107 | Restored terminals in background tabs start their shells at launch (with the controller, not its view) | `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas` |
| T-108 | Saved config is `{cwd}` only (missing → home); no scrollback saved | `TerminalConfigTests/readsTolerantlyAndStrictly` |
| T-109 | Unreadable saved config (`cwd` not a string) refused (`makePane` throws): pane unavailable, leaf kept, never replaced | `TerminalPaneTests/anUnreadableConfigIsRefused`, `TerminalConfigTests/readsTolerantlyAndStrictly` |

### Settings (Settings ▸ Terminal)

Keys in the plugin's `terminal` settings blob.

| Id | Case | Test |
|---|---|---|
| T-110 | GPU rendering (Metal) `enableMetalRendering`: off; new panes only; a failed `setUseMetal` keeps CoreGraphics | `TerminalSettingsTests/defaultsAreTheClearDarkProfile` (Metal path untested) |
| T-111 | Inherit working directory `inheritCwdOnNewPane`: on; new panes | `TerminalPaneTests/withInheritanceOffANewTerminalStartsAtHome` |
| T-112 | Scrollback `scrollback`: 1000 lines above the screen, 0 = none; field + stepper, step 100; negative ignored; live, open panes too; capped at 100,000 (`TerminalSettings.maxScrollback`: SwiftTerm reserves the whole ring up front) | `TerminalPaneTests/scrollbackAppliesLiveDownToNone`, `…/aHugeScrollbackIsCapped` |
| T-113 | Font family `appearance.fontFamily`: JetBrains Mono NL; picker of `NSFontManager` families, current one always listed; live | `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` (renders; list untested) |
| T-114 | Font size: 15; 8–32 step 1; live, re-fits | `TerminalPaneTests/appearanceAppliesLive`, `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` |
| T-115 | Line height: 1; 0.8–2 step 0.05; live, re-fits; extra height goes above the text (SwiftTerm `lineSpacing`) | — |
| T-116 | Cursor style: bar; block / bar / underline; live | — |
| T-117 | Cursor blink: on; live | — |
| T-118 | Background / Foreground / Cursor / Selection: `#06225f` / `#e0e0e0` / `#ffffff` / `#273d4c`; live | `TerminalPaneTests/appearanceAppliesLive` (background), `TerminalSettingsTests/colorsRoundTripAsHex` |
| T-119 | 16 ANSI colors, Normal and Bright rows (black, red, green, yellow, blue, magenta, cyan, white), Clear Dark palette; a partial stored value decodes over the defaults | `TerminalSettingsTests/defaultsAreTheClearDarkProfile`, `…/aPartialStoredValueDecodesOverTheDefaults` |
| T-120 | The palette doesn't follow the app theme | — |
| T-121 | The page is hidden while the plugin is disabled (core) | — |

### Shortcuts

| Id | Case | Test |
|---|---|---|
| T-125 | Clear Buffer `terminal.clearBuffer`: ⌘K, Edit menu, rebindable, terminals only; summary "Clear the active terminal, scrollback included." | `TerminalPluginTests/clearBufferIsAnEditCommandOnCommandKForTerminalsOnly`, `TerminalPaneTests/clearBufferClearsScreenAndScrollback`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-126 | App shortcuts beat a focused terminal (⌘T/⇧⌘T/⌥⌘T/⌘W, ⌘-arrows, ⌘K, ⌘N, ⌘,): menu key equivalents come first (SwiftTerm's view doesn't override `performKeyEquivalent`); nav chords go through `WorkspaceInput`'s key monitor. The terminal doesn't use `PaneContext.isAppShortcut`: a `performKeyEquivalent` override in `TabsTerminalView` would need it | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack`, `…/commandArrowLeavesAFocusedTerminalAndTypingFollows` |
| T-127 | Keyboard focus follows the active pane into a terminal (⌘-arrow, tab click, ⌘T, New terminal): typing goes to that shell | `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard`, `…/commandArrowLeavesAFocusedTerminalAndTypingFollows`, `…/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-128 | A click anywhere in a terminal (padding included) focuses it | `UITests.TerminalUITests/clickingATerminalFocusesIt` |

### Disabling

| Id | Case | Test |
|---|---|---|
| T-130 | Disabling Terminal removes its creation button; open terminals keep running; New Tab on one opens an empty pane (core creation gate) | — |
| T-131 | A terminal pane of a disabled type survives a relaunch (core) | — |

### Control

| Id | Case | Test |
|---|---|---|
| T-135 | Contributes no control verbs (Debug builds: `terminal.test.state` only) | — |

## Look

No visual scenario captures terminal content: it is drawn from the settings (colors, font,
metrics) with the padding below.

| Id | Element | Box | Text, colors | States |
|---|---|---|---|---|
| L-1 | Terminal area | Fills the pane body; padding 4 top, 8 left, 0 right/bottom (`TerminalContainerView.padding`); padding and the strip past the last whole cell in the terminal background | JetBrains Mono NL 15, line height 1; settings colors (Clear Dark) in both app themes | dimmed when inactive (core's Dim inactive panes) |
| L-2 | Cursor | bar (default), block, underline | cursor color; glyph under a block cursor in the background color (`caretTextColor`) | blinks when focused; outline when not |
| L-3 | Selection | cell-aligned | selection background; selected text repainted in the foreground color (`selectedTextForegroundColor`) | — |
| L-4 | Links | as T-90 | text color | — |
| L-5 | `[process exited]` | own line | dim (SGR 2) | — |
| L-6 | Scrollbar | SwiftTerm's overlay `NSScroller` at the terminal's right edge, its width reserved (a couple of columns fewer) | — | while scrolling |
| L-7 | Header Clear scrollback | core header button: 23×17, 13pt icon, leftmost (x 0) in the hover-revealed controls; tooltip and AX label "Clear scrollback" | glyph `textDim`; hover bg `hover(0.12)`, radius 3 | rest, hover |
| L-8 | Creation button | empty pane's toolbar: "New terminal" (`creationLabel`), the terminal icon as a template image | chrome | hover |
| L-9 | Bell | core's signal (PANE-SIGNALS.md): icon before the title, alert outline + inner glow, 3 s pulse, tabs marked | `bellAlert` | — |
| L-10 | Settings page | SwiftUI grouped `Form`, sections as Terminal.app's profile editor: behaviour (GPU, inherit cwd, scrollback), Font (family, size, line height), Cursor (style, blink, color), Colors (bg, fg, selection; Normal and Bright rows of 8). Chips 28×22 (24×18 fill + 2 padding), 4 apart | system fonts; app theme | — |

## Checking the look

- Chrome is core's own drawing: the header action is a core header button (23×17, 13pt icon;
  asserted in `UITests.TerminalUITests/theHeaderClearScrollbackButtonClearsButNotTheAlternateScreen`).
- The bell's look is covered by the `signal-*` scenarios (`signal-header`, `signal-active`,
  `signal-floating`, `signal-tabs`, `signal-light`, …) through the stand-in
  `SignalFixtures.bell`: keep its parameters and glyph equal to `TerminalSignals.bell`. Their
  geometry is held to the goldens recorded from the app (`Visual/golden/<name>.geometry.json`)
  by `GeometryGoldenTests/theGeometryMatchesTheGolden`; `make visual-baseline` then `make
  visual` compare pixels before and after a change (`build/visual/compare/index.html`).
- Never exercised by hand in a real window (tests run in never-shown windows): mouse selection,
  ⌘-click on links, IME, the Metal renderer, the scroller, cursor blink.

## SwiftTerm

- v1.20.0 via SwiftPM, pinned to the tag's commit in `plugin.yml` (a tag can move),
  unpatched; linked statically into this plugin only. Its build-tool plugin → the Makefile's
  `-skipPackagePluginValidation`.
- Used only through `TerminalSurface`; pty, settings, links, bell, titles and directories are
  the plugin's.
- Set in `SwiftTermSurface.init` (SwiftTerm's default in parentheses):
  `optionAsMetaKey = false` (true), `ansi256PaletteStrategy: .xterm` (LAB-derived), scrollback
  and cursor from settings (500, blinking block), `silentLog` (DEBUG logging), OSC 133 clicks
  off, sixel not advertised, bidi `.explicit` (reordering), kitty image cache 16 MB (320 MB),
  OSC 9 ignored (notifications, 9;4 progress bar).
- Our delegate replaces SwiftTerm defaults: `bell` (beeps), `requestOpenLink` (opens any
  scheme). OSC 7 (`hostCurrentDirectoryUpdate`) and OSC 52 (`clipboardCopy`) ignored: the live
  directory comes from the kernel.

| SwiftTerm problem | Workaround (where) |
|---|---|
| A font or line-height change resizes through `resize`, which soft-resets (DECSTR): a running vim loses its modes | frame zeroed around the change (`SwiftTermSurface.apply`) |
| Every `feed` clears the selection while mouse reporting is allowed | `allowMouseReporting` only while a program asked (`feed`) |
| The grid follows its frame even while hidden | terminal placed only while shown, never a degenerate frame (`TerminalContainerView.placeTerminal`) |
| No `clear()` | feed `ESC[nS ESC[nA`, then `clearScrollback()`; refused on the alternate screen (`clear`) |
| No padding API | `TerminalContainerView` |
| Right-click doesn't select a word; paste keeps `\n` | `TabsTerminalView.rightMouseDown`, `.paste` |
| The scrollback ring is allocated whole, up front | capped (`TerminalSettings.scrollbackLines`); `changeScrollback(0)`, never nil (nil also stops reflow on resize) |
| `sizeChanged` reports unclamped numbers | read the terminal's own `cols`/`rows` |

Accepted: `keyDown`, `scrollWheel`, cursor rects are `public`, not `open` (the gaps under
Notes can't be fixed by subclassing); process-wide side effects (a `.mouseMoved` local event
monitor on macOS 26+ while tracking, toggling the window's `acceptsMouseMovedEvents`;
key/active observers for all windows; global statics; an `NSView.pending(_:)` extension).

## Implementation notes

- **Emulation and drawing**: SwiftTerm (above); GPU rendering is Metal.
- **The pty** is the plugin's own (Shell process), held by the pane controller, and
  the AppKit view survives core's moves: nothing reattaches, holds, replays or serializes
  output (T-50…T-62).
- **Clear scrollback** is a `PaneController.headerActions` entry, drawn by core: a
  `headerAccessory` view can't match header buttons drawn from core's private theme.
- **Font list**: `NSFontManager`'s families.

## Notes

- **SwiftTerm, unpatched**: Option+←/→/⌫ send nothing; ⌥⌘O toggles Option-as-Meta per pane;
  ⌃2…⌃/ send nothing; Shift+PageUp goes to the program, plain PageUp scrolls locally in the
  normal buffer; after ~65,533 OSC 8 links in one app run no terminal gets hyperlinks
  (process-wide 16-bit ids, never reused); bold brightens 0–6 only; extra line height above the
  text; links (T-90); right/middle clicks unreported; focus reports only on first-responder
  changes; kitty keyboard protocol answered and kitty graphics shown; scroller width reserved
  (L-6); selected text in the foreground color (L-3).
- **⌘K feeds escape sequences** to the emulator: can garble one sequence landing between two
  halves of a program's output.
- **Scrollback capped at 100,000** (T-112).
- **No View ▸ Zoom**: the font size setting scales terminal text instead.
- **A missing font** falls back to the system monospaced font.
- **Offered directory** is probed 150 ms after output; a new terminal from a terminal reads it
  fresh.
- **Control caller check** accepts any open pane, an exited shell's too (T-6).
