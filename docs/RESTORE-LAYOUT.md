# Restore layout on relaunch

One switch: whether the next launch reopens every window's tabs and panes (and what each
showed). Code: the setting `core.panes.persistLayoutOnExit`, read by `CoreRuntime.loadLayout()`
at launch and by `LayoutEngine.saveNow()` at each save point.

## Sources

| File | What |
|---|---|
| `SettingsStore.PaneSettings.persistLayoutOnExit` (`core.panes`, default `true`) | The setting |
| `CoreRuntime.loadLayout()` | Launch reads layout.json only while on |
| `LayoutEngine.saveNow()` | While off: nothing written, no pane asked for its state |
| `Sources/Tabs/UI/PaneSettingsPage.swift` (Panes & Tabs ▸ Startup) | The switch |

## Cases

| Id | Case | Test |
|---|---|---|
| R-1 | On by default | `SettingsTests/restoreLayoutIsOnByDefault` |
| R-2 | Settings ▸ Panes & Tabs ▸ Startup: "Restore layout on relaunch", "Reopen your tabs and panes, and what each was showing, when relaunching." (id `settings-persist-layout-checkbox`) | `UITests.RestoreLayoutSetting/theSwitchIsOnPanesAndTabsUnderStartup` |
| R-3 | On: relaunch restores every window | `RestoreLayoutTests/onAtLaunchReadsTheFile`, `RelaunchTests`, `PersistenceTests` |
| R-4 | Off at launch: layout.json not read (nor moved aside, even if unreadable); one fresh window | `RestoreLayoutTests/offAtLaunchNeitherReadsNorTouchesTheFile` |
| R-5 | Off: no save point writes layout.json (changes, window moves, quit) | `RestoreLayoutTests/offNothingIsWritten` |
| R-6 | Off: panes not asked for live state at save points or quit (keeps the `lsof` cwd probe off the quit path) | `RestoreLayoutTests/offNoPaneIsAskedForItsState` |
| R-7 | Turned on mid-session: next save point writes the whole live layout; quit saves too | `RestoreLayoutTests/turningItOnResumesSavingTheLiveLayout` |
| R-8 | Turned off mid-session: writing stops, file keeps its last content, next launch starts fresh | `RestoreLayoutTests/turningItOffStopsWriting` |
| R-9 | The setting itself persists in settings.json either way | `RestoreLayoutTests/theSettingPersists` |
| R-10 | In-session, closing the last window and reopening one (Dock, New Window) restores it regardless (kept in memory) | `RestoreLayoutTests/theLastClosedWindowComesBackEvenWhenOff` |
| R-11 | Off at launch: the old layout's content types don't force-load plugins | `RestoreLayoutTests/offAtLaunchNeitherReadsNorTouchesTheFile` |

## Notes

- Turning it on after a launch that didn't read layout.json replaces the file at the next save:
  the store's copy-aside safety (newer or partly unreadable files) covers only files it has read.
