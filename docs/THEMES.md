# Themes

A theme is a file: a name, dark or light, and the colors the app paints with. Settings ▸ Panes &
Tabs ▸ Theme lists every theme the app ships, and the one chosen paints the workspace chrome,
plugin panes' chrome and every window the app draws itself, live. Terminal colors are not part
of a theme (the Terminal plugin's palette, [TERMINAL.md](TERMINAL.md) T-120), nor is other
content with colors of its own (a git graph's lanes, a web page). Code: the files in
`Sources/Tabs/Resources/Themes`, core's `ThemeCatalog` and `Themes`
(`Sources/TabsCore/Themes/ThemeCatalog.swift`), the SDK's `PaneTheme` (the tokens), the shell's
`ThemedRoot` and `NSWindow.paint(with:)` (`Sources/Tabs/UI/ThemedWindows.swift`).

## Adding a theme

1. Copy `Sources/Tabs/Resources/Themes/dark.json` (or `light.json`) to
   `Sources/Tabs/Resources/Themes/<id>.json`: the file's name is the theme's id, which the
   setting stores (lowercase letters, digits and hyphens).
2. Give it a `name` (what the Theme menu shows), its `appearance`, and its colors.
3. `make run`: the menu lists it after System, Light and Dark, by name.

No code, no project change (the folder is bundled as it is, `Contents/Resources/Themes`), no
test and no golden of its own: `UITests.ThemeSetting` fails `make check` if a shipped file
doesn't load, and the packaging gate (`Scripts/verify-app.sh`, check 13) if the app doesn't bundle
exactly the files in the folder. To see it everywhere at once, render every surface in every theme
(`UITests.AppearanceSnapshots`, with `TEST_RUNNER_TABS_SNAPSHOT_DIR`).

## The file

```json
{
  "name": "Matrix",
  "appearance": "dark",
  "bg": "#000000",
  "bgElevated": "#0a1a0e",
  "border": "#0a4214",
  "text": "#00ff41",
  "textDim": "#00b030",
  "accent": "#00ff41",
  "onAccent": "#000000",
  "bellAlert": "#ff453a",
  "agent": "#b48cff",
  "hover": "#00ff41",
  "shadow": "#00ff41",
  "shadowStrength": 0.4
}
```

| Key | | What it paints |
|---|---|---|
| `name` | required | The Theme menu's title; no two themes share one |
| `appearance` | required, `dark` or `light` | What macOS draws for the app: alerts, menus, file panels, tooltips, scrollers, web pages' `prefers-color-scheme` (dark or light Aqua); a signal's own colors (`.custom(dark:light:)`) |
| `bg` | required | Window and page backgrounds (title bars included), the outermost bars, pane bodies |
| `bgElevated` | required | Every other bar (depths alternate); raised chrome: the palette, core's menus and dialogs, a dragged tab's ghost, an empty pane's buttons |
| `border` | required | Hairlines and outlines; a window's separators |
| `text` | required | Text; the caret in a workspace window's text fields |
| `textDim` | required | Secondary text, chrome glyphs |
| `accent` | required | The active pane's outline, focus, links, the tint of every control in a window, a selection, the palette's focus ring |
| `onAccent` | required | Text on an `accent` fill (a selection, a filled button) |
| `bellAlert` | required | The bell cue; errors in a window |
| `agent` | required | The agent-control cue |
| `hover` | optional, default `text` | Hover washes, used at a small alpha |
| `shadow` | optional, default `#000000` | Shadows: under floating panes, the palette, the active tab |
| `shadowStrength` | optional, 0 to 1, default 1 | Scales every shadow's alpha |

Colors are `#rrggbb` (either case), opaque. The keys are `PaneTheme`'s tokens, which plugins get
as they are (`paneAppearanceDidChange`, `PaneContext.theme`).

## Sources

| File | What |
|---|---|
| `Sources/Tabs/Resources/Themes/*.json` | Every theme: `dark`, `light`, `matrix` |
| `ThemeCatalog` | Loads a directory of files (`Contents/Resources/Themes` of the app), strictly; the menu's order; what a setting resolves to |
| `Themes` (`runtime.themes`) | The catalog and the current theme: SwiftUI observes it, an AppKit window registers (`observe`) |
| `AppShell.applyPaneSettings` | Resolves the setting, pins `NSApp.appearance` (`NSAppearance.pinned(by:theme:)`), sets the current theme and the chrome's |
| `ThemedRoot`, `EmbeddedSettingsPage`, `NSWindow.paint(with:)` | A window's SwiftUI content in the theme; a plugin's Settings page inside one; a window's background and title bar |
| `PaneTheme.placeholder` (SDK) | Not a theme: what a view holds before it's told one, and what is drawn if no file loads (AppKit's own colors) |

## Cases

| Id | Case | Test |
|---|---|---|
| TH-1 | A file in `Themes` is a theme: its file name the id, `name` the menu title, its values the tokens; `appearance` sets `isDark` | `ThemeCatalogTests/aFileIsAThemeAndWhatItLeavesOutTakesItsDefault` |
| TH-2 | An optional key left out takes its default: `hover` the text color, `shadow` black, `shadowStrength` 1 | `ThemeCatalogTests/aFileIsAThemeAndWhatItLeavesOutTakesItsDefault` |
| TH-3 | A file that doesn't decode is left out, and says which file and why (logged): not JSON, not an object, a required key missing, an unknown key, a color not `#rrggbb`, `appearance` not dark or light, `shadowStrength` outside 0…1, an empty or taken `name`, a file name that can't be an id, `system.json`. The others load | `ThemeCatalogTests/aFileThatIsntJSONIsLeftOut`, `/aFileWithAWrongValueIsLeftOut`, `/aFileWhoseNameCantBeAnIdIsLeftOut` |
| TH-4 | Every theme the app ships loads, Light and Dark among them | `UITests.ThemeSetting/everyThemeTheAppShipsLoadsAndSystemsPairIsAmongThem` |
| TH-5 | The Theme menu: System, then Light, Dark, then every other theme by name; choosing one stores its id (`core.panes.colorTheme`, default `dark`) | `ThemeCatalogTests/lightAndDarkComeFirstThenTheRestByName`, `UITests.ThemeSetting/thePickerListsSystemThenTheThemesAndKeepsTheStoredChoice` |
| TH-6 | System is Light or Dark as the OS is, following it live (the app's appearance unpinned); a stored id no file defines draws Dark and the menu shows Dark, the stored value kept; with no Dark either, the placeholder | `ThemeCatalogTests/aSettingResolvesWhateverItNames`, `UITests.ThemeSetting/thePickerListsSystemThenTheThemesAndKeepsTheStoredChoice`, `UITests.Appearance/systemFollowsTheOSAndALaterChoiceTakesOverWithoutReopeningAnything` |
| TH-7 | A theme reaches, live: the workspace chrome; every plugin pane (told before it's first shown); Settings — core's pages and every plugin's —, Plugins, About and Caffeinate (background and title bar, text, secondary text, separators, the controls' tint, filled buttons); the caret and selection of a workspace window's text fields; what macOS draws, as dark or light Aqua | `UITests.ThemeReach/aThemesTokensReachEveryWindowAndFollowAChange`, `UITests.Appearance/everyWindowFollowsTheSettingNotTheOS` |
| TH-8 | A filled button (the default button, a recording shortcut) has the accent for its bezel, which AppKit fills only in the key window: its title is `onAccent` there, the text color elsewhere | `UITests.ThemeReach/aThemesTokensReachEveryWindowAndFollowAChange` (not key); key: by eye |
| TH-9 | A change is drawn at once everywhere, open windows included | `UITests.ThemeReach/aThemesTokensReachEveryWindowAndFollowAChange` |

## What follows a theme how

| Surface | How |
|---|---|
| Workspace chrome: bars, tabs, headers, outlines, floating panes, the palette (its focus ring the accent, NEW-CONTENT L-12), core's dialogs and menus, drag ghosts, signals | Tokens, drawn by the app's workspace views (`Sources/Tabs/Workspace`) |
| Plugin panes' chrome (Browser's and Git tree's toolbars, Git tree's list) | Tokens, from `paneAppearanceDidChange` |
| Settings: core's pages | `ThemedRoot`: the background, `text` / `textDim` / `border` as the primary, secondary and third styles, `accent` as the tint; AppKit controls in them (the shortcut chips, the search field) read `appTheme` |
| Settings: a plugin's page | Its own view inside a `ThemedRoot` (`EmbeddedSettingsPage`): core's environment reaches the plugin's SwiftUI. Verified on macOS 27 only; where it didn't reach, the page would draw in dark or light Aqua |
| About | AppKit, every color a token, repainted on a change |
| Plugins, Caffeinate | `ThemedRoot` |
| Window title bars (Settings, Plugins, About, Caffeinate) | Transparent over the window's `bg`; the selected toolbar tab's pill is macOS's |
| Alerts, menus (core's main menu, a web page's context menu), file panels, system tooltips, scrollers, AppKit focus rings, search-field and stepper bezels | macOS draws them: dark or light Aqua only |
| Web pages, terminal colors, git lanes and diff colors | Their own colors; a page sees `prefers-color-scheme` |
| The "Tabs is damaged" alert | Runs before settings load: the OS's appearance |

## Notes

- **A grouped form's cards.** SwiftUI draws a section's card as a translucent wash over the
  window's background, which no modifier reaches (`listRowBackground`, `backgroundStyle` don't):
  cards read as `bg` slightly lifted, not `bgElevated`.
- **Descriptions.** Under a foreground style a grouped form draws a row's whole label in the
  primary style, so a row's description is marked `.foregroundStyle(.secondary)` (core's pages,
  Caffeinate, every plugin's page), which SwiftUI draws as the text color at half strength, not
  `textDim`. A new page does the same; it uses hierarchical styles (`.secondary`, `.tint`), not
  `Color.secondary` or `Color.accentColor`, which stay the system's.
- **Controls' states.** A switch, a slider or a pop-up's active look follows the tint only in
  the key window; a window that isn't key draws them grey, as macOS does.
- **One path.** Dark and Light are painted from their tokens like any theme: the windows use the
  theme's accent, not the one chosen in System Settings.
