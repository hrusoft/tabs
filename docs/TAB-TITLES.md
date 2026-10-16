# Tab titles follow panes

One switch: whether a tab the user didn't name shows the title of the pane last active in it (a
shell's command or directory, a page's title) as that title changes. Code: the setting
`core.panes.tabTitlesFollowPanes`, which pane a tab follows (`WindowLayout.followedPane(of:)`),
and what it shows (`LayoutEngine.tabTitle(of:in:followingPanes:)`).

## Sources

| File | What |
|---|---|
| `SettingsStore.PaneSettings.tabTitlesFollowPanes` (`core.panes`, default `true`) | The setting |
| `WindowLayout.recentPanes`, `followedPane(of:)` | The window's panes, the most recently active first (recorded as `activePaneID` is set; saved as `recentPaneIds`); a tab follows the first one inside it, else the pane it shows |
| `Tab.titleIsManual`, `WindowLayout.renameTab(_:_:titles:)` | A name the user typed; nil gives the default back (`Tree.resetTabTitle`) |
| `LayoutEngine.renameTab(_:in:to:from:)`, `renamePane(_:in:to:from:)` | The user's edit, from the title shown: unchanged changes nothing, emptied gives the default back |
| `LayoutEngine.tabTitle(of:in:followingPanes:)` | What a tab shows: the followed pane's title (`paneTitle`, as its header shows it), else the tab's own |
| `LayoutEngine.paneTitleDidChange`, `titleSettleDelay` (500 ms) | A pane's own title change waits before the chrome shows it (`shownTitles`); zero in the plugin harness and the visual capture |
| `Sources/Tabs/Workspace/TabStrip.swift` (`TabView.title`), `Overlays.swift` (`TitleEditor`) | Drawing it (via `ChromeHost.tabTitle`, with `PaneAppearance.tabTitlesFollowPanes`); renaming |
| `Sources/Tabs/UI/PaneSettingsPage.swift` (Panes & Tabs ▸ Tabs) | The switch |

## Cases

| Id | Case | Test |
|---|---|---|
| TT-1 | On by default; absent or undecodable in settings.json → on | `SettingsTests/tabTitlesFollowPanesByDefault` |
| TT-2 | Settings ▸ Panes & Tabs ▸ Tabs: "Tab titles follow the active pane", "Each tab shows the title of the pane last active in it, as that title changes. A tab you rename keeps your name; clear it to follow again." (id `settings-tab-titles-follow-checkbox`) | `UITests.TabTitlesSetting/theSwitchIsOnPanesAndTabsUnderTabs` |
| TT-3 | A tab shows its pane's title as it changes, trimmed as the pane's header shows it (a pane the user renamed: their name); the strip lays out again; shown, never stored in the tab | `LayoutEngineTests/aTabShowsThePaneLastActiveInItUnlessTheUserNamedIt`, `UITests.TabTitles/aTabShowsItsPanesTitleAsItChanges` |
| TT-4 | A different pane in the tab becomes active → the tab shows that pane's title | `WindowLayoutTests.FollowedPanes/lastActiveInTheTab`, `UITests.TabTitles/aTabSwitchesToThePaneThatBecomesActiveInItAndKeepsItInTheBackground` |
| TT-5 | Each tab follows its own last active pane: a tab in the background keeps following it; nested tabs each follow the pane last active inside them; a tab none of whose panes has been active follows the pane it shows | `WindowLayoutTests.FollowedPanes/lastActiveInTheTab`, `.nested`, `.noneYet`, `UITests.TabTitles/aTabSwitchesToThePaneThatBecomesActiveInItAndKeepsItInTheBackground` |
| TT-6 | The followed pane leaves the tab (moved, closed) → the next most recently active pane still in it | `WindowLayoutTests.FollowedPanes/paneLeaves`, `.recentPanes` |
| TT-7 | An empty pane has no title of its own: a tab following one shows its own title ("Tabs", "New Tab") | `LayoutEngineTests/aTabShowsThePaneLastActiveInItUnlessTheUserNamedIt` |
| TT-8 | A tab the user renames keeps exactly their name: title changes and pane switches don't touch it, setting on or off; other tabs keep following | `TreeTests.RenameTab/marksManual`, `.onlyThatTab`, `UITests.TabTitles/aRenamedTabKeepsTheNameAndAnEmptiedOneFollowsAgain` |
| TT-9 | Renaming to an empty title gives the tab the title a new tab of its content gets ("Terminal", "Split", "New Tab"; "Tabs" for an empty pane in the window's own strip), and it follows its pane again. Return on the title the tab shows changes nothing (a following tab isn't pinned) | `TreeTests.ResetTabTitle`, `WindowLayoutTests.Titles/resetsATabTitle`, `LayoutEngineTests/aTitleConfirmedUnchangedPinsNothingAndAnEmptiedOneGivesTheDefaultBack`, `UITests.TabStrip/escapeAbandonsARenameAndAnEmptyTitleGivesTheDefaultBack`, `UITests.TabTitles/aRenamedTabKeepsTheNameAndAnEmptiedOneFollowsAgain` |
| TT-10 | Off: every tab shows its own title (its default, or the user's name); on again, they follow again (nothing was stored) | `LayoutEngineTests/aTabShowsThePaneLastActiveInItUnlessTheUserNamedIt`, `UITests.TabTitles/turnedOffATabShowsItsOwnTitle` |
| TT-11 | Relaunch keeps the user's names (`titleIsManual`) and which pane each tab follows (`recentPaneIds`, written when it says more than the active pane) | `LayoutCodingTests.Windows/namesAndRecentPanes`, `WindowLayoutTests.FollowedPanes/given` |
| TT-12 | A tab rebuilt under its old name keeps the user's name: the root's rewrap when its other tabs close, a drop that nests the root's lone content, unpin and pin back (the anchor and its siblings, saved too) | `WindowLayoutTests.Titles/manualSurvivesRewrap`, `.manualSurvivesPromotion`, `FloatingTests.RestoreFloating/keepsTheUsersNames`, `LayoutCodingTests.Windows/floatingAnchorNames` |
| TT-13 | A pane's own title change shows (its header, its tab, the window title) 500 ms later, as the title is then: a title that changes back meanwhile never shows (a shell's command title for a quick `ls`), and one that keeps changing shows at most every 500 ms. At once: a pane's first title, the user's renames, a switch to another pane; control verbs and the saved layout read the live title | `LayoutEngineTests/aPanesOwnTitleChangeShowsWhateverItIsOnceTheWaitIsOver`, `UITests.TabTitles/aPanesOwnTitleChangeWaitsHalfASecondToShow` |
| TT-14 | Return (or clicking away) on the title a pane's header shows changes nothing: the pane isn't pinned to it, and its header and the tab following it keep showing its content's live title | `LayoutEngineTests/aTitleConfirmedUnchangedPinsNothingAndAnEmptiedOneGivesTheDefaultBack`, `UITests.TabTitles/confirmingAPanesShownTitleKeepsItFollowingItsContent` |

## Notes

- Which pane a tab follows is one list per window, not a field on each tab: a tab's last active
  pane is the first pane of `recentPanes` inside it, so a pane that leaves a tab hands over to
  the next one without anything to repair, and nested tabs each get theirs from the same list.
- Only the shown title follows: `Tab.title` keeps what the tab was named (by its content when it
  was made, or by the user), so turning the setting off shows it again.
