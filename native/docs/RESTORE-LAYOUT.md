# Restore layout on relaunch

One switch: whether the next launch reopens every window's tabs and panes (and what each
showed). Port of Electron's `persistLayoutOnExit`.

## Sources

| Native | Electron | What |
|---|---|---|
| `SettingsStore.PaneSettings.persistLayoutOnExit` (`core.panes`, default `true`) | `src/shared/settings.ts` (`persistLayoutOnExit`) | The setting |
| `CoreRuntime.loadLayout()` | `src/main/layout.ts:registerLayoutIpc` | Launch reads layout.json only while on |
| `LayoutEngine.saveNow()` | `layout.ts:persistLayoutFile`, `refreshLeafConfigs` | While off: nothing written, no pane asked for its state |
| `Sources/Tabs/UI/PaneSettingsPage.swift` (Panes & Tabs ▸ Startup) | `settings/GeneralSettings.tsx` (General ▸ Startup) | The switch |

## Cases

| Id | Case | Electron | Native test |
|---|---|---|---|
| R-1 | On by default | `DEFAULT_SETTINGS` | `SettingsTests/restoreLayoutIsOnByDefault` |
| R-2 | Settings ▸ Panes & Tabs ▸ Startup: "Restore layout on relaunch", "Reopen your tabs and panes, and what each was showing, when relaunching." (id `settings-persist-layout-checkbox`) | `GeneralSettings.tsx` | `UITests.RestoreLayoutSetting/theSwitchIsOnPanesAndTabsUnderStartup` |
| R-3 | On: relaunch restores every window | `registerLayoutIpc` | `RestoreLayoutTests/onAtLaunchReadsTheFile`, `RelaunchTests`, `PersistenceTests` |
| R-4 | Off at launch: layout.json not read (nor moved aside, even if unreadable); one fresh window | `registerLayoutIpc` | `RestoreLayoutTests/offAtLaunchNeitherReadsNorTouchesTheFile`, `RestoreLayoutRelaunchTests/offStartsTheNextLaunchFreshAndOnResumesSaving` |
| R-5 | Off: no save point writes layout.json (changes, window moves, quit) | `persistLayoutFile` gate | `RestoreLayoutTests/offNothingIsWritten` |
| R-6 | Off: panes not asked for live state at save points or quit (keeps the `lsof` cwd probe off the quit path) | `refreshLeafConfigs` gate | `RestoreLayoutTests/offNoPaneIsAskedForItsState` |
| R-7 | Turned on mid-session: next save point writes the whole live layout; quit saves too | in-memory `windowLayouts` kept current while off | `RestoreLayoutTests/turningItOnResumesSavingTheLiveLayout`, `RestoreLayoutRelaunchTests/offStartsTheNextLaunchFreshAndOnResumesSaving` |
| R-8 | Turned off mid-session: writing stops, file keeps its last content, next launch starts fresh | `persistLayoutFile` gate + `registerLayoutIpc` | `RestoreLayoutTests/turningItOffStopsWriting` |
| R-9 | The setting itself persists in settings.json either way | — | `RestoreLayoutTests/theSettingPersists`, `RestoreLayoutRelaunchTests/offStartsTheNextLaunchFreshAndOnResumesSaving` |
| R-10 | In-session, closing the last window and reopening one (Dock, New Window) restores it regardless (kept in memory) | `layout.ts` last-closed rule | `RestoreLayoutTests/theLastClosedWindowComesBackEvenWhenOff` |
| R-11 | Off at launch: the old layout's content types don't force-load plugins | — (Electron loads every type) | `RestoreLayoutTests/offAtLaunchNeitherReadsNorTouchesTheFile` |

## Known differences

- The switch is on Panes & Tabs (Electron: General), which already holds Electron's General ▸
  Appearance.
- As in Electron, turning it on after a launch that didn't read layout.json replaces the file
  at the next save: the store's copy-aside safety (newer or partly unreadable files) covers
  only files it has read.
