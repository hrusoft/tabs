# Terminal

Interactive login shells in panes: plugin `Plugins/Terminal` (id and content type `terminal`),
SDK only. Port of Electron's `packages/plugin-terminal` (xterm.js 6 on node-pty), drawn by
SwiftTerm.

## Scope

- Behaviour matches case by case; the look follows the settings (no pixel pipeline for
  terminal content).
- SwiftTerm unpatched, behind the `TerminalSurface` seam (libghostty could replace it); its
  gaps are deviations.
- Header controls are core-drawn `PaneController.headerActions`; the close/quit dialog is
  core's, for every plugin.
- GPU rendering = Metal, new panes only, off by default.
- Four Electron quirks fixed, not kept (see below).
- Restored background terminals start their shells at launch.
- No Option-as-Meta setting.
- Test hooks: Debug-only verb `terminal.test.state`.

## Sources

Native under `Plugins/Terminal/Sources/`. Electron under `packages/plugin-terminal/`;
`content/`, `core/` under `src/renderer/src/`; `plugin-sdk/` = `packages/plugin-sdk/`.

| Native | Electron | What |
|---|---|---|
| `../Info.plist` | `shared/manifest.ts` | Identity: `terminal`, "Terminal", can be disabled |
| `TerminalPlugin.swift` | `renderer/index.ts`, `renderer/terminalContentDef.ts`, `main/index.ts` | Content type, bell kind `terminal.bell`, command `terminal.clearBuffer`, settings page; links (`TerminalLinks`); `deactivate` ends every shell |
| `TerminalSettings.swift` | `shared/settings.ts` | Settings, Clear Dark defaults. Stored values merge over defaults at every depth (SDK): no `mergeTerminalSettings` |
| `Shell.swift` | `main/terminal.ts` (`resolveShell`, `resolveCwd`, `createTerminal` env) | Pure: shell, start directory, environment, locale |
| `ShellProcess.swift` | `main/terminal.ts`, node-pty | One shell on one pty (below) |
| `ProcessProbe.swift` | `plugin-sdk/main/processProbe.ts` | Live cwd (`PROC_PIDVNODEPATHINFO`; Electron `lsof`), foreground group (`pbi_pgid` vs `e_tpgid`; Electron `ps`), name (`proc_name`). Sync syscalls, no timeout; failure → nil |
| `TerminalPane.swift` | `renderer/TerminalRenderer.tsx` | Pane controller: shell + surface, sizing, settings, titles, bell, clear, close warning, live directory |
| `TerminalSurface.swift` | xterm.js, `renderer/terminal.css` | `TerminalSurface` seam; `SwiftTermSurface`, `TerminalContainerView` (padding), `TabsTerminalView` (paste, right-click) |
| `TerminalGlyphs.swift` | `renderer/TerminalIcon.tsx`, `renderer/ClearScrollbackControl.tsx`, `content/icons.tsx` (`BellIcon`) | Template images from the Electron SVGs |
| `TerminalSettingsPage.swift` | `settings/TerminalSettingsPage.tsx`, `src/main/fonts.ts` | SwiftUI page. Colors via one shared `NSColorPanel` (`ColorPanelEditor`): many live `NSColorWell`s break unrelated views |
| `TerminalTestVerbs.swift` | `data-pty-pid`, DOM text | Debug `terminal.test.state`: `pid`, `columns`/`rows`, `ptyColumns`/`ptyRows`, `screen`, `buffer`, `alternateScreen`, `exited`, `cwd`, `focused` |
| core `PaneController.headerActions`, shell `PaneActionButton` | `ContentRendererDef.HeaderControl` | Clear scrollback button |
| core `CloseConfirmation`, `closeWarning`, `LayoutEngine.shouldClose`/`shouldQuit` | `src/main/closeDialogs.ts`, `closeBlockers.ts` | Close/quit confirmation |
| core `PaneSignals` | `src/main/bell.ts`, `core/store/bellStore.ts` | Bell |
| core `PaneContext.setTitle`, `titleIsManual` | `src/shared/model/tree.ts` (`setLiveTitle`) | OSC titles |
| core `PaneCreation.origin`, `PaneCapability.workingDirectory` | `content/exposedCwd.ts`, `content/createFrom.ts` | cwd inheritance, both ways |
| core `PaneContext.childEnvironment` | `registerPaneHost`, `controlSocketPath()` | App env minus `TABS_DATA_DIR`/`TABS_LISTEN_SOCKET`/`TABS_E2E_HIDDEN`, plus `TABS_CONTROL_SOCKET`, `TABS_PANE_ID` |
| shell main-menu key equivalents, `WorkspaceInput` | `content/spatialNav.ts` | App shortcuts beat the shell (T-126) |
| — | `terminalRegistry.ts`, `terminalBridge.ts`, `shared/ipc.ts`, `shared/orphans.ts`, hold/release, `SerializeAddon` | Don't reintroduce: the pty lives in the controller and the AppKit view survives core's moves; nothing to reattach, hold, replay or serialize (T-50…T-62) |
| — | `migrateTerminalSettings` | Dropped: no format back-compat |

## Shell process (`ShellProcess`)

- `forkpty`: new session, pty as controlling terminal; `IUTF8` on (as node-pty). Not
  `posix_spawn` + `setsid`: no controlling terminal (zsh reopens its tty `O_NOCTTY` → no job
  control, no ⌃C).
- Fork → exec: syscalls only (argv, envp, cwd built before): signals 1–31 `SIG_DFL`, mask
  cleared, fds ≥ 3 closed, `chdir`, `execve`. Never `setenv`/`chdir` in the app.
- `access(X_OK)` before forking: a failed exec can't report.
- Reads on a private queue, ≤ 256 KB per main-actor hand-off, in order, last output before the
  exit. Paused while > 1 MB (`highWater`) waits to be drawn, resumed at 256 KB.
- Writes never block: `O_NONBLOCK`; `EAGAIN` → retry after 10 ms, doubling to 250 ms.
- `terminate()`: synchronous (runs at quit), idempotent; SIGHUP only while unreaped (pid can't
  be reused); closes the pty (resumes a suspended read source first, or its cancel handler never
  runs).
- Exit: dispatch process source, plus one check at start (it may exit before the watch).

## Cases

Pane and UI tests run real `$SHELL -l` with your dotfiles: wait for computed markers
(`echo X-$((1+1))` → `X-2`), never a prompt. `—`: nothing drives it (mostly input a
never-shown window can't get).

### The shell

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-1 | New terminal (empty pane's button, or a new tab/split like a terminal) → interactive login shell `$SHELL -l`, startup files run | `terminal.ts:createTerminal` | `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |
| T-2 | Shell: `$SHELL` if non-empty, else `/bin/zsh` if it exists, else `/bin/bash` (even if missing; never throws). A shell that can't start → dim `[could not start <shell>: <error>]`, pane kept as exited | `terminal.ts:resolveShell` | `ResolveShellTests` (5, Electron's titles), `TerminalProcessTests/aMissingExecutableThrows` |
| T-3 | Start directory from config `cwd`: absent, `""`, `~` → home; `~/x` → home/x; absolute kept; no longer a directory → home (quirk fixed) | `terminal.ts:resolveCwd` | `ResolveCwdTests` (5), `TerminalProcessTests/theEnvironmentAndDirectoryAreApplied`, `TerminalPaneTests/aDeletedSavedDirectoryStartsAtHome`, `TerminalEndToEndTests/aDeletedSavedDirectoryStartsTheShellAtHome` |
| T-4 | New pane without origin seeded `{cwd: "~"}` | `terminalContentDef.ts` `createAction.createContent` | `TerminalPluginTests/aNewPaneIsSeededToStartAtHome` |
| T-5 | Env: `childEnvironment` + `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Tabs`, `TERM_PROGRAM_VERSION` (bundle version), over inherited values. `LANG=<lang>_<region>.UTF-8` (if in `/usr/share/locale`, else `en_US.UTF-8`) only when `LANG`/`LC_ALL`/`LC_CTYPE` are all empty (quirk fixed) | `createTerminal` env | `EnvironmentTests` (3), `TerminalProcessTests/theEnvironmentAndDirectoryAreApplied`, `TerminalEndToEndTests/theShellIsToldWhatTerminalItIsIn`, `…/aLocaleTheAppHasIsPassedOnAsIs`, `…/aShellGetsAUTF8LocaleWhenTheAppHasNone` |
| T-6 | `TABS_CONTROL_SOCKET` (per-boot socket), `TABS_PANE_ID` (this pane); launch settings stripped. **Not yet:** core's caller check (`ControlPlane.dispatch`) accepts any open pane, an exited shell's too (Electron: live ptys only, unregistered on exit) | `createTerminal` env, `src/main/paneHostRegistry.ts` | `EnvironmentTests/statesTheTerminalsIdentityOverInheritedValues`, `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `TerminalEndToEndTests/theShellIsToldWhatTerminalItIsIn` |
| T-7 | Controlling terminal + job control (`fg`, ⌃Z, ⌃C reach the foreground job); every signal default and unblocked, whatever the app ignores (`nohup`) | node-pty spawn (`POSIX_SPAWN_SETSIGDEF`) | `TerminalProcessTests/thePtyIsTheControllingTerminal`, `…/anIgnoredSignalIsntInherited`, `UITests.TerminalUITests/theShellControlsItsTerminalAndCtrlCInterrupts` |
| T-8 | pty starts at the pane's size (one turn after creation, once laid out); a hidden pane's catches up when shown (T-37) | `create(id, cwd, cols, rows)` | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored` |
| T-9 | Shell exits (`exit`, ⌃D) → dim `[process exited]` on its own line; pane and output stay; typing goes nowhere; no close warning; offers no directory | `TerminalRenderer.tsx` `onExit` | `TerminalProcessTests/outputArrivesInOrderAndBeforeTheExit`, `TerminalPaneTests/anExitedShellKeepsItsPane` |
| T-10 | pty never outlives its pane: close → SIGHUP, pty closed, reaped; `deinit` terminates as a safety net | `disposeTerminal` | `TerminalProcessTests/terminatingEndsAndReapsTheShell`, `TerminalPaneTests/closingThePaneEndsItsShell`, `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-11 | Each pane's shell pid readable by tests: `terminal.test.state` | `data-pty-pid` | `TerminalPaneTests/runsALoginShellThatKnowsItsTerminalAndPane`, `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |

### Output, input and the emulator

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-20 | Typed keys reach the shell; output drawn; 256-color (xterm palette) and 24-bit escapes render (color depth untested) | xterm.js | `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard` |
| T-21 | Output arriving while the pane is a hidden tab is kept | `terminalBridge.onData` | `TerminalPaneTests/outputWhileHiddenIsKept`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-22 | Full-screen programs (vim, less, htop): alternate screen, screen back on exit (SwiftTerm) | xterm.js | — |
| T-23 | Mouse selection: drag, double-click word, triple-click line; ⌘C copies (Edit ▸ Copy) (SwiftTerm) | xterm.js, menu role `copy` | — |
| T-24 | ⌘V pastes (Edit ▸ Paste): `\r\n`/`\n` → `\r`, bracketed when the program asked (`TabsTerminalView.paste`); a paste larger than the pty buffer arrives whole | xterm.js, role `paste` | `TerminalProcessTests/aLargeWriteArrivesWhole` |
| T-25 | Right-click selects the word under it (a synthesized double-click), unless a program has the mouse | xterm `rightClickSelectsWord` (macOS default) | — |
| T-26 | Option types the layout's characters (é, ∑), not Meta (`optionAsMetaKey = false`). **Deviation:** Option+←/→/⌫ send nothing; ⌥⌘O toggles Option-as-Meta for that pane (SwiftTerm `keyDown`; no app chord takes it) | xterm `macOptionIsMeta: false` | — |
| T-27 | ⌃ keys reach the shell (⌃C, ⌃R, ⌃A…); no default app shortcut is a bare ⌃ letter. **Deviation:** ⌃2…⌃/ send nothing (SwiftTerm) | `shortcuts.ts` `hasRequiredModifier` | `UITests.TerminalUITests/theShellControlsItsTerminalAndCtrlCInterrupts` (⌃C) |
| T-28 | Mouse reporting to programs that ask (vim `mouse=a`, htop). **Deviation:** right/middle buttons unreported (SwiftTerm) | xterm.js | — |
| T-29 | Wheel scrolls the scrollback; on the alternate screen without mouse reporting it sends arrows (SwiftTerm) | xterm.js viewport | — |
| T-30 | Focus reporting (`CSI ?1004`), IME composition. **Deviation:** focus reports only on first-responder changes (SwiftTerm) | xterm.js | — |
| T-31 | Bold uses the bright palette. **Deviation:** SwiftTerm brightens 0–6 only (not white) | xterm `drawBoldTextInBrightColors` | — |
| T-32 | Cursor blinks only while focused; unfocused it's an outline (SwiftTerm) | xterm.js | — |
| T-33 | A flood (`yes`, `cat` of a huge file) never grows memory unbounded; ⌃C stops it at once (pty paused above 1 MB in flight; the program is held back, nothing dropped) | xterm.js `WriteBuffer` (discards past 50 MB) | `TerminalProcessTests/aFloodIsPacedByTheMainActorAndCtrlCStopsIt` |

### Size

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-35 | Pane resize (window, split, separator) → pty resize: SIGWINCH, `stty size` agrees. Core sizes the view by autoresizing and by layout; the container follows both | ResizeObserver → `fit()` → `resize` | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored`, `TerminalPluginTests/theTerminalFollowsItsPanesSizeThroughAutoresizing`, `TerminalPaneTests/aHiddenPaneNeverResizesThePtyButCatchesUpWhenShown` |
| T-36 | Hidden pane (background tab) never resizes the pty (no SIGWINCH for tab switches); the grid keeps its size too | ResizeObserver 0×0 guard | `TerminalPaneTests/aHiddenPaneNeverResizesThePtyButCatchesUpWhenShown`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-37 | A pane first shown later (restored background tab) takes its real size then, once | mount-time `fit()` guard | ″ |
| T-38 | Resize to 0 cols or rows ignored | `resizeTerminal` | `TerminalProcessTests/resizingReachesTheShellAndAZeroSizeIsIgnored` |
| T-39 | Font, size or line-height change re-fits and resizes the pty (while shown) | restyle effect | `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` |

### Title

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-40 | OSC 0/2 → pane's header title | `onTitleChange` → `setLiveTitle` | `TerminalPaneTests/oscTitlesTitleThePane`, `…/aShellsOscTitleReachesThePane`, `UITests.TerminalUITests/anOSCTitleNamesThePaneAndAnEmptyOneClearsIt` |
| T-41 | A manual title isn't replaced by OSC titles | `setLiveTitle` (`titleIsManual`) | `TerminalPaneTests/aManualTitleWinsAndClearingItShowsTheLatestOscTitle`, `UITests.TerminalUITests/aManualTitleWinsAndClearingItShowsTheShellsLatest` |
| T-42 | Clearing the manual title shows the shell's latest OSC title, "Terminal" if none (Electron quirk fixed) | `setLiveTitle` | ″ |
| T-43 | Empty OSC title → "Terminal" | `setLiveTitle('')` | `TerminalPaneTests/oscTitlesTitleThePane`, `UITests.TerminalUITests/anOSCTitleNamesThePaneAndAnEmptyOneClearsIt` |
| T-44 | A terminal's tab is titled "Terminal"; so is a new tab/split made from one | `core/registry/titles.ts:titleForContent` | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |

### Staying alive when the layout changes

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-50 | Moving its tab to another group: same shell (pid), scrollback | `terminalRegistry.ts` reattach | — (drags can't be synthesized) |
| T-51 | New tab on a bare terminal promotes it into a group (same shell, scrollback, view) beside a new, separate terminal | reattach | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-52 | Closing the tab beside it collapses the group back (same shell, scrollback); the closed one's shell ends | reattach | ″ |
| T-53 | Splitting a sibling pane leaves an unrelated terminal alone | reattach | `UITests.TerminalUITests/splittingASiblingKeepsTheTerminal` |
| T-54 | Opening a terminal on a pane holding one → two tabs, two shells (core; the palette: NEW-CONTENT.md C-1) | `placeNewPane` | — |
| T-55 | Away from its tab and back: same shell, output that arrived meanwhile shown | reattach | `TerminalPaneTests/outputWhileHiddenIsKept`, `UITests.TerminalUITests/aHiddenTerminalKeepsOutputAndIsResizedOnlyWhenShown` |
| T-56 | Wrapping it in a tab group (header control, root bar) keeps the shell | reattach | `UITests.TerminalUITests/wrappingInAGroupKeepsTheShell` |
| T-57 | Pane drags (center merge, edge dock) keep shell and scrollback | reattach | — (drags can't be synthesized; the moves they commit are, T-51…T-59) |
| T-58 | Unpin (floating) and pin back keep the shell | reattach | `UITests.TerminalUITests/unpinningAndPinningKeepTheShell` |
| T-59 | Moving a terminal (or a group of two) to another window keeps shells and scrollback | `prepareCrossWindowDetach`, `captureTransferState` | `UITests.TerminalUITests/movingToAnotherWindowKeepsTheShellAndItsOutput` (the engine's move, no drag) |
| T-60 | Output printed during the move arrives in the destination | `holdOutput`/`releaseOutput` | ″ |
| T-61 | A shell exiting mid-move shows its last output and the exit in the destination. **n/a:** a move is one synchronous step in one process | `exitedWhileHeld` | — |
| T-62 | Clear pane (header) empties it in place and ends the shell; the title-bar close collapses the split and ends it | `layoutStore` `clearPane`/`closePane` | `TerminalPaneTests/closingThePaneEndsItsShell` (close only) |

### Ending

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-65 | Closing a window (not the last) ends its shells | `main/index.ts` `onWindowDiscarded` | `UITests.TerminalUITests/closingAWindowEndsItsShells` |
| T-66 | Closing the last window ends its shells; layout kept; New Window brings it back on fresh shells | `src/main/layout.ts` last-closed rule | — |
| T-67 | Two windows closed together both end their shells | `onWindowDiscarded` | — |
| T-68 | Quit ends every shell (`deactivate` → `endAll`), not only closed panes' | `onQuitSync` → `disposeAllTerminals` | `TerminalPluginTests/deactivatingEndsEveryShell`, `TerminalEndToEndTests/quittingEndsEveryShell` |
| T-69 | Crash or SIGKILL of the app leaves no shell: the pty master closes → SIGHUP | kernel | `TerminalEndToEndTests/aCrashLeavesNoShellRunning` |

### Close and quit confirmation

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-70 | Closing a pane/tab whose shell has a foreground job (terminal's group ≠ the shell's) asks first, naming it: `<name> is still running` (`A process is still running` if unnamed). Idle prompts and background jobs (`cmd &`) never ask | `processProbe.ts:getForegroundProcess`, `closeDialogs.ts:confirmClosingPanes` | `TerminalProcessTests/theForegroundGroupNamesARunningCommandOnly`, `TerminalPaneTests/aRunningCommandWarnsBeforeClosing`, `UITests.TerminalUITests/aRunningCommandMakesClosingWarn`, `CloseConfirmationTests/onlyQuittingAsksAsAQuit` |
| T-71 | Same for closing a window and quitting, every busy pane listed | `confirmQuitSync`, `listRunningTerminals` | `CloseConfirmationTests/onlyQuittingAsksAsAQuit`, `…/quittingGoesAheadWithQuitAnyway` |
| T-72 | Detail: `• <warning>` per pane, then "Closing will end it/them immediately."; buttons Cancel (default, Escape), then "Close Anyway" / "Quit Anyway". **Deviation:** core's words for every plugin: title "A pane is still busy" / "N panes are still busy", bullet `• vim is still running` (Electron: "A process is still running" / "N processes are still running", `• vim`, `• a process`) | `closeDialogs.ts:runningProcessesCopy` | `CloseConfirmationTests/oneWarningIsOneBulletAndClosingEndsIt`, `…/severalWarningsAreCountedAndListedInOrder`, `…/quittingGoesAheadWithQuitAnyway` |
| T-73 | Cancel keeps everything; a failed probe counts as nothing running | `collectCloseBlockers` (fail-open) | `TerminalPaneTests/aRunningCommandWarnsBeforeClosing` |

### Bell

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-75 | BEL (`\a`) in a pane the user isn't looking at raises `terminal.bell`: icon + pulsing alert outline, on every tab holding it. No sound: our `bell(source:)` replaces SwiftTerm's `NSSound.beep` | `onBell` → `bell.ring` | `TerminalPaneTests/aBellRaisesTheBellSignalWhenUnseen`, `…/aShellsBellReachesThePane`, `TerminalPluginTests/theBellIsASignalWithTheElectronBellsParameters`, `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-76 | A bell in the pane being looked at (active pane, focused window) is dropped | `bellStore.ts:ring` | `TerminalPaneTests/aBellInThePaneBeingLookedAtIsDropped`, `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-77 | A bell in the active pane of an unfocused window flags it; cleared when the window regains focus (core) | `bellStore.ts` | `PaneSignalsTests/aBellInTheActivePaneOfAnUnfocusedWindowFlagsIt`, `…/windowFocusClearsTheActivePanesBellOnly` |
| T-78 | Focusing the pane clears its bell; other panes' stay | focus handle → `bell.clear` | `UITests.TerminalUITests/aBellFlagsATerminalTheUserIsntLookingAt` |
| T-79 | Dock bounces (informational) on a bell while the window isn't focused | `src/main/bell.ts` | `TerminalPaneTests/aBellRaisesTheBellSignalWhenUnseen`, `PaneSignalsTests/aKindAskingForAttentionBouncesTheDockEveryTimeWhileUnfocused` |
| T-80 | Settings ▸ Panes & Tabs switch "Bell indicator" ("Pulse a bell icon and bounce the Dock icon when a terminal rings its bell."), on by default; off → dropped, no bounce | `Settings.enableBellIndicator` | `TerminalPluginTests/theBellIsASignalWithTheElectronBellsParameters`, `UITests.Signals/theSettingsPageHasASwitchPerKindThatHidesIt`, `PaneSignalsTests/aSwitchedOffBellIsDroppedWithoutBouncing` |

### Links

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-85 | ⌘-click a plain-text URL → default browser, no dialog | `WebLinksAddon` → `openTerminalLink` | — |
| T-86 | ⌘-click an OSC 8 hyperlink → its target, not its text | `linkHandler` | — |
| T-87 | A plain click on a link opens nothing (focuses the pane) | `links.ts:isLinkActivationEvent` | — |
| T-88 | Left button only (right-click, ⌃-click never) | `isLinkActivationEvent` | — |
| T-89 | Only `http:`, `https:`, `mailto:` open (scheme case-insensitive); `file:`, custom schemes dropped. Native also opens an OSC 8 `mailto:` (xterm.js refuses non-http OSC 8: `allowNonHttpProtocols` off) | `plugin-sdk/shared/url.ts:isSafeExternalUrl` | `TerminalLinksTests/opensOnlyHttpHttpsAndMailto`, `…/dropsEverythingElse` |
| T-90 | Hovering a link shows it as one (pointer, underline). **Deviation:** dashed underline only while ⌘ is held, I-beam kept, URL preview; file paths underlined too (don't open) (SwiftTerm) | xterm.js | — |

### Clearing

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-95 | Edit ▸ Clear Buffer (⌘K) clears the active terminal, scrollback included: the cursor's line becomes the first, nothing above | `clear` capability → `term.clear()` | `TerminalPaneTests/clearBufferClearsScreenAndScrollback`, `…/clearingALiveShellKeepsItWorking`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-96 | …but does nothing on the alternate screen (a TUI keeps its screen) | `buffer.active.type !== 'normal'` | `TerminalPaneTests/clearBufferLeavesTheAlternateScreenAlone`, `UITests.TerminalUITests/commandKLeavesTheAlternateScreenAlone` |
| T-97 | ⌘K with another type's pane active: disabled, nothing cleared | `paneShortcuts.ts` `clear-buffer` | `TerminalInheritanceFromOtherTypesTests/clearBufferIsForTheActiveTerminalOnly`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-98 | Header Clear scrollback (id `pane-terminal-clear-scrollback-button`, leftmost in the hover controls; three tapering rows + small ×) = ⌘K, alt-screen rule included | `ClearScrollbackControl.tsx` | `TerminalPluginTests/offersTheClearScrollbackHeaderAction`, `TerminalPaneTests/theHeaderActionClearsLikeTheCommand`, `UITests.TerminalUITests/theHeaderClearScrollbackButtonClearsButNotTheAlternateScreen` |

### Working directory

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-100 | New tab/split from a terminal starts in that shell's live directory (after `cd`), read fresh, inheritance on | `deriveConfig` → `exposedCwdOf` | `TerminalPaneTests/aNewTerminalFromATerminalStartsInItsLiveDirectory`, `TerminalProcessTests/theWorkingDirectoryFollowsCd` |
| T-101 | Inheritance off → `~` | `deriveConfig` gate | `TerminalPaneTests/withInheritanceOffANewTerminalStartsAtHome` |
| T-102 | From another type's pane → the directory it offers | `exposedCwdOf` | `TerminalInheritanceFromOtherTypesTests/startsWhereAnotherTypesPaneOffers` |
| T-103 | A terminal offers its live directory to other types, whatever its inheritance setting: at start, then 150 ms after output (a `cd` prints a prompt) | `exposeCwd` (ungated) | `TerminalPaneTests/aTerminalOffersItsLiveDirectoryEvenWithInheritanceOff` |
| T-104 | Origin offering nothing (empty pane, exited shell) → `~` | `deriveConfig` fallback | `TerminalPaneTests/anExitedOriginGivesHome`, `TerminalInheritanceFromOtherTypesTests/anOriginThatOffersNothingGivesHome` |

### Persistence

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-105 | Relaunch restores terminals: same layout, each on a fresh shell (new pid) that works | layout persistence | `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas` |
| T-106 | Restarts in its live directory, saved at every save (`currentConfig`: live ?? last offered ?? start), so a crash keeps it (Electron quirk fixed) | `onQuitSync` → `refreshLeafConfigs` | `TerminalPaneTests/aNewTerminalFromATerminalStartsInItsLiveDirectory`, `TerminalProcessTests/theWorkingDirectoryFollowsCd`, `TerminalEndToEndTests/aRelaunchRestoresAFreshShellWhereTheOldOneWas`, `…/aCrashStillRestoresTheLiveDirectory` |
| T-107 | Restored terminals in background tabs start their shells at launch (with the controller, not its view) | `TabsRenderer` keeps inactive tabs mounted | — |
| T-108 | Saved config is `{cwd}` only (missing → home); no scrollback saved | `LeafContent.config` | `TerminalConfigTests/readsTolerantlyAndStrictly` |
| T-109 | Unreadable saved config (`cwd` not a string) refused: pane unavailable, leaf kept, never replaced | native (`makePane` throws) | `TerminalPaneTests/anUnreadableConfigIsRefused`, `TerminalConfigTests/readsTolerantlyAndStrictly` |

### Settings (Settings ▸ Terminal)

Keys in the plugin's `terminal` settings blob.

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-110 | GPU rendering (Metal) `enableMetalRendering`: off; new panes only; a failed `setUseMetal` keeps CoreGraphics. **Deviation:** Electron's WebGL rendering, on by default | `enableWebglRendering` | `TerminalSettingsTests/defaultsAreTheElectronAppsClearDarkProfile` (Metal path untested) |
| T-111 | Inherit working directory `inheritCwdOnNewPane`: on; new panes | `inheritCwdOnNewPane` | `TerminalPaneTests/withInheritanceOffANewTerminalStartsAtHome` |
| T-112 | Scrollback `scrollback`: 1000 lines above the screen, 0 = none; field + stepper, step 100; negative ignored; live, open panes too. **Deviation:** capped at 100,000 (`TerminalSettings.maxScrollback`: SwiftTerm reserves the whole ring up front) | `updateScrollback` | `TerminalPaneTests/scrollbackAppliesLiveDownToNone`, `…/aHugeScrollbackIsCapped` |
| T-113 | Font family `appearance.fontFamily`: JetBrains Mono NL; picker of `NSFontManager` families, current one always listed; live | `src/main/fonts.ts` | `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` (renders; list untested) |
| T-114 | Font size: 15; 8–32 step 1; live, re-fits | `TerminalSettingsPage.tsx` | `TerminalPaneTests/appearanceAppliesLive`, `UITests.TerminalUITests/theSettingsPageRendersAndAFontSizeChangeAppliesLive` |
| T-115 | Line height: 1; 0.8–2 step 0.05; live, re-fits. **Deviation:** extra height goes above the text (SwiftTerm `lineSpacing`) | ″ | — |
| T-116 | Cursor style: bar; block / bar / underline; live | ″ | — |
| T-117 | Cursor blink: on; live | ″ | — |
| T-118 | Background / Foreground / Cursor / Selection: `#06225f` / `#e0e0e0` / `#ffffff` / `#273d4c`; live | ″ | `TerminalPaneTests/appearanceAppliesLive` (background), `TerminalSettingsTests/colorsRoundTripAsHex` |
| T-119 | 16 ANSI colors, Normal and Bright rows (`ANSI_LABELS` order), Clear Dark palette; a partial stored value decodes over the defaults | `shared/settings.ts` | `TerminalSettingsTests/defaultsAreTheElectronAppsClearDarkProfile`, `…/aPartialStoredValueDecodesOverTheDefaults` |
| T-120 | The palette doesn't follow the app theme | CLAUDE.md | — |
| T-121 | The page is hidden while the plugin is disabled (core) | content-type gate | — |

### Shortcuts

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-125 | Clear Buffer `terminal.clearBuffer`: ⌘K, Edit menu, rebindable, terminals only; summary "Clear the active terminal, scrollback included." | `shortcuts.ts` `clear-buffer` | `TerminalPluginTests/clearBufferIsAnEditCommandOnCommandKForTerminalsOnly`, `TerminalPaneTests/clearBufferClearsScreenAndScrollback`, `UITests.TerminalUITests/commandKClearsTheActiveTerminalOnly` |
| T-126 | App shortcuts beat a focused terminal (⌘T/⇧⌘T/⌥⌘T/⌘W, ⌘-arrows, ⌘K, ⌘N, ⌘,): menu key equivalents come first (SwiftTerm's view doesn't override `performKeyEquivalent`); nav chords go through `WorkspaceInput`'s key monitor. The terminal doesn't use `PaneContext.isAppShortcut`: a `performKeyEquivalent` override in `TabsTerminalView` would need it | `spatialNav.ts`, `data-nav-text-input` | `UITests.TerminalUITests/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack`, `…/commandArrowLeavesAFocusedTerminalAndTypingFollows` |
| T-127 | Keyboard focus follows the active pane into a terminal (⌘-arrow, tab click, ⌘T, New terminal): typing goes to that shell | `paneHandles.ts` (`PaneFocusFollower`) | `UITests.TerminalUITests/aNewTerminalIsALoginShellWithTheKeyboard`, `…/commandArrowLeavesAFocusedTerminalAndTypingFollows`, `…/commandTPromotesALiveTerminalAndClosingTheTabCollapsesItBack` |
| T-128 | A click anywhere in a terminal (padding included) focuses it | `focusOnClick` | `UITests.TerminalUITests/clickingATerminalFocusesIt` |

### Disabling

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-130 | Disabling Terminal removes its creation button; open terminals keep running; New Tab on one opens an empty pane (core creation gate) | `isContentTypeEnabled` | — |
| T-131 | A terminal pane of a disabled type survives a relaunch (core) | content-type gate | — |

### Control

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-135 | Contributes no control verbs (Debug builds: `terminal.test.state` only) | `renderer/index.ts` | — |

## Look

No pixel comparison for terminal content: same colors, font, metrics and padding, not identical
rasterization.

| Id | Element | Box | Text, colors | States |
|---|---|---|---|---|
| L-1 | Terminal area | Fills the pane body; padding 4 top, 8 left, 0 right/bottom (`TerminalContainerView.padding` = `.terminal-container`); padding and the strip past the last whole cell in the terminal background | JetBrains Mono NL 15, line height 1; settings colors (Clear Dark) in both app themes | dimmed when inactive (core's Dim inactive panes) |
| L-2 | Cursor | bar (default), block, underline | cursor color; glyph under a block cursor in the background color (`caretTextColor`) | blinks when focused; outline when not |
| L-3 | Selection | cell-aligned | selection background. **Deviation:** selected text repainted in the foreground color (`selectedTextForegroundColor`) | — |
| L-4 | Links | Electron: underline on hover, pointer. **Deviation:** T-90 | text color | — |
| L-5 | `[process exited]` | own line | dim (SGR 2) | — |
| L-6 | Scrollbar | Electron: xterm's overlay, inside the padded area. **Deviation:** SwiftTerm's overlay `NSScroller` at the terminal's right edge, its width reserved (a couple of columns fewer) | — | while scrolling |
| L-7 | Header Clear scrollback | core header button: 23×17, 13pt icon, leftmost (x 0) in the hover-revealed controls; tooltip and AX label "Clear scrollback" | glyph `textDim`; hover bg `hover(0.12)`, radius 3 | rest, hover |
| L-8 | Creation button | empty pane's toolbar: "New terminal" (`creationLabel`), Electron `TerminalIcon` as a template image | chrome | hover |
| L-9 | Bell | core's signal (PANE-SIGNALS.md): icon before the title, alert outline + inner glow, 3 s pulse, tabs marked | `--bell-alert` | — |
| L-10 | Settings page | **Deviation:** SwiftUI grouped `Form`, sections as Terminal.app's profile editor: behaviour (GPU, inherit cwd, scrollback), Font (family, size, line height), Cursor (style, blink, color), Colors (bg, fg, selection; Normal and Bright rows of 8). Chips 28×22 (24×18 fill + 2 padding), 4 apart. Electron: behaviour, then one Appearance section | system fonts; app theme | — |

## Checking the look

- Chrome is core's own drawing: the header action is a core header button (23×17, 13pt icon;
  asserted in `UITests.TerminalUITests/theHeaderClearScrollbackButtonClearsButNotTheAlternateScreen`).
- The bell is held to the Electron captures by the `signal-*` scenarios through the stand-in
  `SignalFixtures.bell`: keep its parameters and glyph equal to `TerminalSignals.bell`.
- Never exercised by hand in a real window (tests run in never-shown windows): mouse selection,
  ⌘-click on links, IME, the Metal renderer, the scroller, cursor blink.

## SwiftTerm

- v1.20.0 via SwiftPM, pinned to the tag's commit in `plugin.yml` (a tag can move),
  unpatched; linked statically into this plugin only. Its build-tool plugin → the Makefile's
  `-skipPackagePluginValidation`.
- Used only through `TerminalSurface`; pty, settings, links, bell, titles and directories are
  the plugin's.
- Set as xterm.js in `SwiftTermSurface.init` (SwiftTerm default in parentheses):
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

Accepted: `keyDown`, `scrollWheel`, cursor rects are `public`, not `open` (gaps under Known
differences can't be fixed by subclassing); process-wide side effects (a `.mouseMoved` local
event monitor on macOS 26+ while tracking, toggling the window's `acceptsMouseMovedEvents`;
key/active observers for all windows; global statics; an `NSView.pending(_:)` extension).

## Electron quirks fixed natively

- **Deleted saved directory**: node-pty's spawn helper `_exit(1)`s on `chdir` failure → a dead
  `[process exited]` pane every launch. Native: starts at `~` (T-3).
- **Live directory saved only at quit**: a crash restores where terminals started. Native: at
  every save (T-106).
- **No `LANG`** for a Finder-launched app: C locale, non-ASCII shown as escapes in zsh's line
  editor. Native: UTF-8 `LANG` when none is set (T-5).
- **Clearing a manual title** shows "Terminal" until the next OSC title (earlier ones were
  dropped). Native: the latest (T-42).

## Can't be ported as-is

- **xterm.js** → SwiftTerm (above). **WebGL** → Metal.
- **node-pty** → `forkpty` in the plugin (Shell process).
- **`HeaderControl`** → `PaneController.headerActions`: a `headerAccessory` view can't match
  header buttons drawn from core's private theme.
- **Font list**: `osascript` → `NSFontManager`.
- **View ▸ Zoom** (whole web content, terminal text included): none natively; the font size
  setting instead.

## Known differences

- **SwiftTerm, unpatched**: Option+←/→/⌫ send nothing; ⌥⌘O toggles Option-as-Meta per pane;
  ⌃2…⌃/ send nothing; Shift+PageUp goes to the program, plain PageUp scrolls locally in the
  normal buffer (xterm.js: the opposite); after ~65,533 OSC 8 links in one app run no terminal
  gets hyperlinks (process-wide 16-bit ids, never reused); bold brightens 0–6 only; extra line
  height above the text; links (T-90); right/middle clicks unreported; focus reports only on
  first-responder changes; kitty keyboard protocol answered and kitty graphics shown (xterm.js:
  neither); scroller width reserved (L-6); selected text in the foreground color (L-3).
- **⌘K feeds escape sequences** to the emulator: can garble one sequence landing between two
  halves of a program's output.
- **Scrollback capped at 100,000** (T-112).
- **Close/quit dialog words are core's** (T-72).
- **GPU rendering** is Metal, off by default (T-110).
- **Missing font** → system monospaced (Chromium: its own fallback).
- **Offered directory** is probed 150 ms after output; a new terminal from a terminal reads it
  fresh, as Electron's `lsof` did.
- **Control caller check** accepts any open pane (T-6).
