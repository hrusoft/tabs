# Git tree

A pane showing a repository's commit graph: a lane-gutter commit list, the selected commit's
detail below it, a divider between. Plugin `Plugins/GitTree` (id and content type `git-tree`).

## Scope

- Toolbar (path bar, folder button, HEAD label, branch-scope select) = the pane header's title
  (`PaneController.headerTitle`); the body is list + detail only.
- Chrome is core's, never copied: theme tokens (`PaneContext.theme`,
  `paneAppearanceDidChange`), attention (`paneDidBecomeAttended`; no own active-pane tracking),
  menus (`showContextMenu`), dialogs (`confirm`/`choose`/`alert`: cards in the pane's window),
  picker (`chooseDirectory`). Plugin-owned colors: `GitTreeColors` only (lanes, diff stats).
- git: the user's, with the pane's `childEnvironment`; always async; never throws (`GitError`
  values); nothing at quit.
- AX ids: `git-tree`, `git-tree-list`, `git-tree-detail`, `git-tree-divider`,
  `git-tree-path-input`, `git-tree-browse-button`, `git-tree-branch-scope`.

## Sources

Paths under `Plugins/GitTree/Sources/` unless rooted.

| File | What |
|---|---|
| `GitTreePlugin.swift` | Type `git-tree`, `git-tree.refresh`, settings page; `GitTreeServices` (live panes, checkout refresh, copy) |
| `Plugins/GitTree/Info.plist` | Manifest (`canDisable`) |
| `Model/GitTypes.swift` | Wire shapes; `uncommittedChangesHash` (`""`) |
| `Model/Graph.swift` | `assignLanes` |
| `Model/CheckoutTargets.swift` | `splitRemoteRef`, `decideCheckout`, `checkoutTargetLabel` |
| `Model/DetailSplit.swift` | `readDetailSplit`, `resolveDetailDrag` |
| `Model/Format.swift` | `shortHash`, `formatDate`, `baseName` |
| `Model/GitTreeSettings.swift` | Settings value |
| `Git/Git.swift`, `Git/GitProcess.swift` | Runner (process rules), parsers, reads, `checkout` |
| `Git/GitSource.swift` | `GitSource`: `GitRepositorySource` (reads, default directory); Debug `ScriptedGitSource` |
| `UI/GitTreePane.swift` | Controller: loads, generations, selection, detail, paging, refresh, checkout, config |
| `UI/GitTreeView.swift` | Loading / list + detail / notice; list focus ring |
| `UI/GitTreeToolbar.swift` | The toolbar |
| `UI/CommitListView.swift` | Rows, gutter, hover, keys, Load more, row menu |
| `UI/CommitDetailView.swift` | Detail panel |
| `UI/DetailDivider.swift` | Divider drag |
| `UI/GitTreeStyle.swift` | Metrics, text layout (`GitText`), edge snapping (`snap`), `GitTreeColors` |
| `UI/GitTreeGlyphs.swift` | Pane and folder icons |
| `UI/GitTreeSettingsPage.swift` | Three toggles |
| `GitTreeTestVerbs.swift` (Debug) | `git-tree.test.stage`, `.state`, `.visual` |

## Git commands

Every call: `git -c core.quotePath=false --no-pager …`, env `GIT_TERMINAL_PROMPT=0`,
`GIT_OPTIONAL_LOCKS=0`, stdin null; killed after 10 s (`Git.timeout`) or past 32 MB of stdout
(`Git.maxBuffer`). `git` is looked up on the env's `PATH` (none: `/usr/bin:/bin:/usr/sbin:/sbin`).
Field separator U+001F.

| Read | Command |
|---|---|
| Root | `rev-parse --show-toplevel` |
| Page | `log <scope> --date-order --parents --max-count=<limit+1> --skip=<n> --pretty=format:%H%x1f%P%x1f%an%x1f%aI%x1f%D%x1f%s`; scope `HEAD` / `--branches` / `--branches --remotes`; the extra commit = `hasMore` |
| HEAD | `symbolic-ref --quiet --short HEAD`; fails → detached at `rev-parse HEAD` |
| Dirty (page 0 only) | `status --porcelain --ignore-submodules` |
| Commit | `show --no-patch --format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%B <hash>` + `show --numstat --format= -m --first-parent <hash>` |
| Working tree | `rev-parse HEAD`, `status --porcelain -z --untracked-files=all --ignore-submodules`, `diff --numstat -z --no-renames HEAD` |
| Refs at a commit | `for-each-ref --format=%(objectname)<U+001F>%(refname) --sort=refname refs/heads refs/remotes` + `remote` |
| Checkout | `switch <name>` / `switch -c <name> --track <remote>/<name>` / `switch --detach <hash>` (git ≥ 2.23) |

- Two `show`s per commit: `%B` holds newlines and would interleave with the numstat block.
- `-m --first-parent`: a plain `show --numstat` prints nothing for a merge.
- `for-each-ref --format` doesn't interpret `%x1f`: the separator byte goes in literally.
- `-z`: paths verbatim (porcelain quotes a path with a space even with `quotePath=false`).
  `--no-renames`: a staged rename keeps status's path, not `old => new` (else listed twice).
  `--untracked-files=all`: an untracked directory's files, not the directory.
- `--track` spelled out: never depend on the user's `branch.autoSetupMerge`.
- Failures classified on stderr (exit codes are 1/128 for everything): "not a git repository"
  → not-a-repo; "does not have any commits yet" / "bad default revision" → no-commits; else
  git's first non-empty stderr line. No `git` on `PATH` → git-missing if `cwd` exists, else
  no-such-directory.

## Cases

### Directory and opening

| Id | Case | Test |
|---|---|---|
| D-1 | Shows the repository containing `config.cwd` (the pane's subject, saved) | `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| D-2 | Created from a pane offering a working directory → opens there. Ungated (no inherit setting) | `GitTreeInheritanceTests/inherits`, `UITests.GitTreeUITests/aGitTreeFromAPaneOfferingADirectoryOpensThere` |
| D-3 | Origin offers nothing (plain pane, no origin, offer withdrawn) → default directory, never blank | `GitTreeInheritanceTests/noDirectory`, `GitTreeInheritanceTests/fromNothing` |
| D-4 | Default: the app's working directory if in a repository, else home; written into config | `GitTreeDirectoryTests/adoptsDefault`, `ReadLogRealTests/defaultDirectoryPrefersARepositoryElseHome` |
| D-5 | A directory chosen while the default lookup is pending wins | `GitTreeDirectoryTests/aChoiceMadeWhileTheDefaultIsPendingWins` |
| D-6 | Offers its configured directory as working directory (a terminal made from it starts there); none while the default is pending | `GitTreeInheritanceTests/offersItsDirectory`, `UITests.GitTreeUITests/aGitTreeOffersItsRepositoryAsItsWorkingDirectory`, `UITests.TerminalUITests/aTerminalFromAPaneOfferingADirectoryStartsThere` |
| D-7 | Path bar: Return or leaving the field applies the trimmed text; empty or unchanged → nothing | `GitTreeDirectoryTests/pathBar`, `UITests.GitTreeUITests/thePathBarReadsWhatIsTyped` |
| D-8 | Path bar: Escape restores the configured directory | `GitTreeDirectoryTests/typingWins` |
| D-9 | Path bar keys stay in it: arrows move the caret, not the selection | `GitTreeDirectoryTests/pathBarKeys`, `UITests.GitTreeUITests/thePathBarReadsWhatIsTyped` |
| D-10 | Path bar follows config changes from elsewhere (default adopted), except while being edited | `GitTreeDirectoryTests/typingWins`, `GitTreeDirectoryTests/adoptsDefault` |
| D-11 | Folder button → open-panel sheet "Choose a repository" at the current directory; Cancel → nothing. No window (tests, hidden) → cancelled; the sheet itself is hand-checked | `GitTreeDirectoryTests/browseAdopts`, `GitTreeDirectoryTests/browseCancelled` |
| D-12 | A toolbar press activates the pane without pulling the keyboard to the list (`focus()` skips while the path bar edits). Auto-refresh (F-5) still runs on that activation: `paneDidBecomeAttended` has no toolbar check (Notes) | — |

### The history list

| Id | Case | Test |
|---|---|---|
| H-1 | One row per commit, newest first (`--date-order`): short hash (7), ref pills, subject | `GitTreeListTests/rows`, `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| H-2 | Refs split out of `%D`: `HEAD -> main` → `HEAD`, `main` | `GitTreeListTests/rows`, `GitParserTests/parseRefsSplitsHeadArrow` |
| H-3 | Every pill on HEAD's commit is filled (inverted) | — (pixels) |
| H-4 | Dirty tree → dimmed italic "Uncommitted changes" row on top, joined into the graph (parent = newest real commit); also with no commits yet | `GitTreeListTests/workingTreeRow`, `ReadLogRealTests/dirtyThenClean` |
| H-5 | Clean tree → no such row; a drifted submodule doesn't count | `GitTreeListTests/cleanTree` |
| H-6 | Working-tree row: no hover wash; double-click and right-click do nothing | `GitTreeListTests/workingTreeRow`, `GitTreeCheckoutTests/workingTreeRow` |
| H-7 | Author and date columns hidden by default; each shows when its setting is on (live) | `GitTreeListTests/columnsHidden`, `GitTreeListTests/columnsShown` |
| H-8 | Dates `YYYY-MM-DD HH:MM`, local time; unparseable text passes through | `FormatTests/formatDateReadsAsSortableLocalTime` |
| H-9 | Hover washes a row; the selected row is accent-tinted | — (pixels: `git-tree-hover-row`) |
| H-10 | Load more only when the log has more; appends the next 500 (`skip` = real rows) without re-reading or blanking; only the first page reads `git status`, so later pages never change the working-tree row | `GitTreeListTests/loadMore`, `ReadLogRealTests/pagesWithHasMore` |
| H-11 | A page arriving after the list was replaced (directory change, refresh) is dropped (`logVersion`) | — |
| H-12 | A failed Load more replaces the whole list with the failure | `GitTreeFailureTests/aFailedLoadMoreReplacesTheList` |

### The graph

| Id | Case | Test |
|---|---|---|
| R-1 | Lanes, one pass in given order: leftmost lane waiting for the commit takes the dot (others released); unwaited → leftmost free lane; first parent inherits the dot's lane; others reuse a lane waiting for them, else leftmost free; trailing free lanes trimmed. `through` by lane index, never by hash (siblings sharing a parent) | `GitTreeModelTests.swift` graph suites (`LinearHistoryTests` … `EmptyLogTests`) |
| R-2 | One gutter width for every row: the widest row's lanes × 12, at least one lane | `GitTreeListTests/gutter`, `ReadLogRealTests/merge` |
| R-3 | Order: through (behind), incoming (top → dot), outgoing (dot → bottom); S-curves, control points at mid-height; color = source lane (through, in) / target lane (out) | — (pixels: `git-tree-lanes`) |
| R-4 | Dot hollow (`bg` fill), filled when selected; extra ring on HEAD's commit | — (pixels) |
| R-5 | Six lane colors cycling by lane index, same in both themes | — (pixels: `git-tree-lanes`, `git-tree-light`) |

### Selection and keys

| Id | Case | Test |
|---|---|---|
| S-1 | A loaded list selects the newest real commit (working-tree row skipped) | `GitTreeListTests/selectsNewest` |
| S-2 | Selection survives a re-read while its commit is there; else newest real commit | `GitTreeListTests/theSelectionSurvivesARereadWhileItsCommitIsThere` |
| S-3 | ↓/↑ move one, clamped at the ends; Home/End jump (Home reaches the working-tree row); moved-to row scrolled into view minimally | `GitTreeListTests/arrows`, `GitTreeListTests/homeReachesWorkingTree` |
| S-4 | Other keys go up to the app (pane navigation) | — |
| S-5 | Click selects and gives the list the keyboard | `GitTreeListTests/clickSelects`, `UITests.GitTreeUITests/clickingARowSelectsIt` |
| S-6 | The list holds focus as a whole; pane activation focuses it | `GitTreeListTests/listKeepsFocus` |
| S-7 | Inset accent ring only when focused from the keyboard (focus arrived during a key event) | — |

### The detail panel

| Id | Case | Test |
|---|---|---|
| P-1 | Full message; Commit (full hash), Author `name <email>`, Date (the row's format, local time, not the raw ISO date), Parent/Parents (short, comma-separated), Refs (comma-separated) | `GitTreeListTests/detail`, `ReadLogRealTests/commitFiles` |
| P-2 | Files with `+n −m` (U+2212, not `-`), or "binary" (numstat `-`: nil counts, never 0) | `GitTreeListTests/detail`, `ReadLogRealTests/aBinaryFileHasNoCounts` |
| P-3 | A merge lists its files against the first parent; a root commit lists its files | `ReadLogRealTests/mergeFiles`, `ReadLogRealTests/rootFiles` |
| P-4 | No files: "No files changed against the first parent." (commit) / "No uncommitted changes." (working tree) | `GitTreeListTests/theDetailPanelsDimLinesSayWhatsMissing` |
| P-5 | Over 500 files: the first 500, then "Only the first files are listed." | `GitParserTests/parseNumstatCutsAtTheFileCap` |
| P-6 | Working-tree detail: message "Uncommitted changes", no Commit/Author/Date, Parent = HEAD. Files: tracked (staged + unstaged, one diff), then other status paths counted off disk (lines = insertions; NUL in the first 8000 bytes = binary; unreadable → no counts); no commits yet → all off disk; one 500 cap | `GitTreeListTests/selectWorkingTree`, `ReadWorkingTreeChangesTests`, `ReadLogRealTests/noCommitsButStaged` |
| P-7 | Nothing selected, not read yet, or a failed read: "Select a commit." | `GitTreeListTests/theDetailPanelsDimLinesSayWhatsMissing` |
| P-8 | Read debounced 100 ms (a held arrow reads only where it settles); the same row's detail stays up while re-read. Tests read at once (`GitTreeServices.detailDebounceOverride`), but in the one that pins it | `GitTreeListTests/aHeldArrowReadsOnlyTheRowItRestsOn` |
| P-9 | ⌘R re-reads the working-tree row's detail (keyed on the log too: its hash never changes) | `GitTreeListTests/refreshWorkingTree` |
| P-10 | Collapsed: nothing read; reopening shows the kept detail, then re-reads | `GitTreeDividerTests/savedCollapse` |

### The divider

| Id | Case | Test |
|---|---|---|
| V-1 | Untouched pane: details 40% of the body, open; nothing saved | `GitTreeDividerTests/untouched`, `ReadDetailSplitTests/untouched` |
| V-2 | Saved `detailFraction`/`detailCollapsed` open as saved; fraction must be finite in (0, 1), collapsed a literal `true`, else defaults | `GitTreeDividerTests/saved`, `ReadDetailSplitTests` |
| V-3 | Drag previews every move, saves on release; a press that moves nothing saves nothing | `GitTreeDividerTests/drag`, `GitTreeDividerTests/stillPress` |
| V-4 | Details < 30 (half the 60 minimum) → collapse, keeping the last open fraction; 30–60 → hold at 60; list keeps ≥ 3 rows (72); body too short for both → details keep 60; saved fraction ≤ 0.99; zero-height body → unchanged | `GitTreeDividerTests/collapseAndReopen`, `ResolveDetailDragTests` |
| V-5 | Collapsed: 8 pt bar with a grip; dragging it up reopens the details on the selected commit | `GitTreeDividerTests/collapseAndReopen` |
| V-6 | An unseen release (a move with the button up) ends the drag where last shown | `GitTreeDividerTests/unseenRelease` |
| V-7 | A press a core split separator claims is core's (the collapsed bar's lower part yields to a split below) | — (core's separators sit above pane views) |
| V-8 | Pressing the divider takes no focus from the list, starts no selection | — |

### Refreshing

| Id | Case | Test |
|---|---|---|
| F-1 | ⌘R (View ▸ Refresh) re-reads the active git tree in place, no "Reading history…" flash | `GitTreeRefreshTests/refresh`, `UITests.GitTreeUITests/commandRReReadsTheActivePane` |
| F-2 | ⌘R does nothing unless a git tree pane is active | `GitTreeRefreshTests/refreshElsewhere` |
| F-3 | Every first-page read claims a generation; only the latest commits | `GitTreeRefreshTests/onlyTheLatestFirstPageReadCommits` |
| F-4 | Directory or branch-scope change → "Reading history…", page 0 | — |
| F-5 | Auto-refresh on focus (off by default): re-read when the pane becomes active in a focused window | `GitTreeRefreshTests/autoRefreshReReadsWhenThePaneBecomesActive` |
| F-6 | …and when its window regains focus with it already active; losing focus, or another pane active, reads nothing | `GitTreeRefreshTests/autoRefreshOn`, `GitTreeRefreshTests/windowRefocusDoesNothingWhenAnotherPaneIsActive` |
| F-7 | Auto-refresh skipped while a first-page read is in flight (opening reads once); ⌘R never skipped | `GitTreeRefreshTests/autoRefreshIsSkippedWhileAReadIsInFlight` |

### Branch scope

| Id | Case | Test |
|---|---|---|
| B-1 | Select offers Current branch / All local branches / All branches; default All branches (local + remote-tracking) | `GitTreeDirectoryTests/scopeOptions` |
| B-2 | Choosing re-reads with it (`HEAD` / `--branches` / `--branches --remotes`; never tags), saved as `config.branchScope` | `GitTreeDirectoryTests/chooseScope`, `ReadLogRealTests/branchScopes` |
| B-3 | A restored pane reads with its saved scope | `GitTreeDirectoryTests/restoredScope` |
| B-4 | HEAD label: the branch, or `detached at <short>`; absent while loading or failed | `GitTreeDirectoryTests/theHeadLabelReadsTheBranchOrDetached`, `ReadLogRealTests/head` |

### Failures and empty states

| Id | Case | Test |
|---|---|---|
| E-1 | Not a repository: "No git repository at <path>." + hint; the pane stays usable | `GitTreeFailureTests/notARepo`, `ReadLogRealTests/notARepo` |
| E-2 | No commits: "<root> is a git repository, but has no commits yet." Detected from an empty first page + clean tree (a ref-scoped `log` succeeds empty) or the stderr phrases. Only the `local`/`all` scopes say so; `current` (`git log HEAD` on an unborn branch) shows git's "fatal: ambiguous argument 'HEAD'…" line (E-5) | `GitTreeFailureTests/noCommits`, `ReadLogRealTests/noCommits` |
| E-3 | git missing: "git isn’t installed, or isn’t on this app’s PATH." | `GitTreeFailureTests/gitMissing`, `ReadLogRealTests/aMissingGitNamesItself` |
| E-4 | Directory doesn't exist: "No directory at <path>." (not git-missing) | `GitTreeFailureTests/noSuchDirectory`, `ReadLogRealTests/noSuchDirectory` |
| E-5 | Anything else: git's first non-empty stderr line | `GitTreeFailureTests/unclassified`, `GitParserTests/classifyReadsGitsStablePhrases` |
| E-6 | Hint under every failure: "Type a directory above, or use the folder button to choose one." | `GitTreeFailureTests/notARepo` |
| E-7 | Git runner rules (Git commands): 10 s timeout, 32 MB stdout cap, no prompts, no optional locks, raw non-ASCII paths, never throws | — |

### Checking out

| Id | Case | Test |
|---|---|---|
| C-1 | Double-click a row, or its menu's Checkout: refs at that commit read fresh (`for-each-ref`, never `%D`), decided (C-12), checked out | `GitTreeCheckoutTests/menuCheckout`, `UITests.GitTreeUITests/doubleClickChecksOutTheOneBranch` |
| C-2 | One local branch there → `git switch <name>`, no prompt; the pane refreshes to the new HEAD | `GitTreeCheckoutTests/oneBranch`, `UITests.GitTreeUITests/doubleClickChecksOutTheOneBranch` |
| C-3 | No local branch, one remote-tracking branch no local branch shares a name with → `git switch -c <name> --track <ref>` | `GitTreeCheckoutTests/remote` |
| C-4 | Several targets → choose dialog "Several branches point at <short> — <subject>. Which one?", options = labels in refname order, first preselected, confirm "Checkout"; Cancel → nothing | `GitTreeCheckoutTests/severalBranches`, `UITests.GitTreeUITests/doubleClickOnSeveralBranchesAsksWhichOne` |
| C-5 | No target → confirm "Checking out <short> — <subject> will leave HEAD detached — it won't be on any branch. Continue?" (confirm "Checkout") → `git switch --detach <hash>`; Cancel → nothing | `GitTreeCheckoutTests/noBranch`, `UITests.GitTreeUITests/doubleClickOnABranchlessCommitAsksBeforeDetaching` |
| C-6 | Failed switch → one-button alert "Checkout failed" with git's full stderr (trimmed, 20 lines + "… (n more lines)"), or the one-line reason when git printed nothing; this pane (and C-9's) still refreshes | `GitTreeCheckoutTests/refusal`, `UITests.GitTreeUITests/aRefusedCheckoutIsAnAlertWithGitsWords` |
| C-7 | One checkout at a time per pane: a trigger while one runs is dropped (no second ref read) | `GitTreeCheckoutTests/inFlight` |
| C-8 | Failed ref read → same alert, one-line reason; no checkout, no refresh; the next checkout works | `GitTreeCheckoutTests/refReadFails` |
| C-9 | After a checkout, other git trees with the exact same `cwd` string (not the same repository root) refresh, in any window; other directories don't | `GitTreeCheckoutTests/refreshesSibling`, `GitTreeCheckoutTests/notOtherDirectory` |
| C-10 | Nothing to check out on the working-tree row | `GitTreeCheckoutTests/workingTreeRow` |
| C-11 | Git layer: refs at a hash = local branches, remote-tracking ones (minus `<remote>/HEAD`, split against `git remote`), every local branch name; the three `switch` shapes; a refusal leaves HEAD untouched and keeps git's text | `BranchesAtCommitTests`, `CheckoutRealTests` |
| C-12 | Policy: local branches win; remote-tracking only with none local, minus any whose name a local branch anywhere has; 1 → single, >1 → choose, 0 → none. Labels: branch name / remote's full ref / hash. `splitRemoteRef`: longest configured remote first, else first segment | `SplitRemoteRefTests`, `DecideCheckoutTests`, `CheckoutTargetLabelTests` |

### Context menu

| Id | Case | Test |
|---|---|---|
| X-1 | Right-click a row: selects it; menu Checkout, then Copy SHA-1 (both always enabled) | `GitTreeCheckoutTests/menu`, `UITests.GitTreeUITests/rightClickSelectsTheRowAndOffersCheckoutThenCopy` |
| X-2 | Both items act on the row right-clicked, not an earlier selection; Copy SHA-1 = full hash | `GitTreeCheckoutTests/copy` |
| X-3 | No menu, and no selection, from a right-click on the working-tree row | `GitTreeCheckoutTests/workingTreeRow` |

### Title

| Id | Case | Test |
|---|---|---|
| T-1 | Tab title = the repository root's last path segment | `GitTreeListTests/title`, `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| T-2 | Failed read → the directory's last segment, not the old repository's name | `GitTreeFailureTests/titleFollows` |
| T-3 | Header shows the toolbar, no title and no Edit title; a press on a control activates without a drag, one on the slot's empty space drags | `GitTreeDirectoryTests/toolbarIsTheHeaderTitle`, `UITests.GitTreeUITests/theHeadersControlsDoNotStartAPaneDrag`, `UITests.HeaderTitle` |

### Settings (Settings ▸ Git tree)

| Id | Case | Test |
|---|---|---|
| ST-1 | "Auto-refresh on focus", off: "Re-read a git tree pane's history whenever it becomes active while the window is focused." (id `settings-auto-refresh-checkbox`) | `GitTreePluginTests/contributesASettingsPage` |
| ST-2 | "Show author column", off: "Show who authored each commit in the commit list, alongside its hash and message." (id `settings-show-author-column-checkbox`) | `GitTreeListTests/columnsShown` |
| ST-3 | "Show date column", off: "Show each commit's date in the commit list, alongside its hash and message." (id `settings-show-date-column-checkbox`) | `GitTreeListTests/columnsShown` |
| ST-4 | Stored values merge over defaults per field; a wrong-typed field → its default; never throws | `GitTreeSettingsTests` |

### Shortcuts

| Id | Case | Test |
|---|---|---|
| K-1 | ⌘R, View ▸ Refresh: plugin command `git-tree.refresh` (group Git tree, rebindable), only while a git tree pane is active | `GitTreeRefreshTests/refreshIsAViewCommandOnCommandRForGitTreesOnly`, `UITests.GitTreeUITests/commandRReReadsTheActivePane` |
| K-2 | ↓ ↑ Home End in the list, by key (not rebindable) | `GitTreeListTests/arrows`, `GitTreeListTests/homeEnd` |

### Persistence

| Id | Case | Test |
|---|---|---|
| PS-1 | `cwd`, `branchScope`, `detailFraction`, `detailCollapsed` saved in the pane's config; relaunch reopens the same repository, scope and split. Non-object config or non-string `cwd` → refused (no pane) | `GitTreeDirectoryTests/anUnreadableConfigIsRefused`, `GitTreePluginTests/savesItsStateInTheConfigAndKeepsUnknownKeys`, `GitTreeDirectoryTests/restoredScope`, `GitTreeDividerTests/saved` |
| PS-2 | Nothing else kept: no cache, no quit work, no process near quit; unknown config keys survive | `GitTreePluginTests/savesItsStateInTheConfigAndKeepsUnknownKeys` |

### Disabling

| Id | Case | Test |
|---|---|---|
| DS-1 | Disabled (`canDisable`): no creation action or settings page; open panes keep working | — (core's gate) |

## Look

Sizes in pt. Colors are core's `PaneTheme` tokens, except `GitTreeColors` (lanes, diff stats).
Text (`GitText`): line box = rounded ascent + rounded descent, baseline on a whole point; box
edges snap to a whole point, round half up (`snap`); wrapping breaks after spaces and
letter-hyphens, never at `/` (an overlong word breaks where the line is full).

| Id | Element | Box | Text | Colors | States |
|---|---|---|---|---|---|
| L-1 | Container | fills the body, clips | system font (SF), `text` | core's pane body | loading / list + detail / notice |
| L-2 | Toolbar (header title) | header slot after the grip and signal icons, before the controls; 24 tall, items centered, gap 8 | — | the header's surface | — |
| L-3 | Path bar | fills the rest, height 20, padding 2 6, 1pt `border`, radius 3 | 12 `textDim` (the header's color, not `text`) | fill `bg` | focused: border `accent`, no focus ring |
| L-4 | HEAD label | padding 0 4, at most 40% of the header's content box, ellipsis | 11 `textDim` | — | absent without a log |
| L-5 | Branch select | widest option + arrow area 20 + padding and border, rounded up (123), height 20, padding 1 4, 1pt `border`, radius 3; a bold chevron ~9×5.5, 4.5 from the right | 11 `textDim`, inset ~9.5 | fill `bg` | never focused |
| L-6 | Row | height 24, gap 8, padding 0 8 0 6 | 12 `text` | hover `hover` at 0.08; selected `accent` at 0.18, also when hovered | working tree: opacity 0.6 (gutter included), italic subject, no hover |
| L-7 | Gutter | max(lanes, 1) × 12 wide, 24 tall; lane x = 12·lane + 6 | — | lanes `#4f8cff #e0a44a #59b871 #c76fd0 #46bcc4 #e0705a` | — |
| L-8 | Graph lines | stroke 1.5; cubic (x1,y1) → (x1,mid), (x2,mid) → (x2,y2) | — | lane color | — |
| L-9 | Dot / HEAD ring | r 3.5, stroke 1.5; ring r 5, stroke 1.5, no fill | — | fill `bg`, lane color when selected | — |
| L-10 | Hash | — | Menlo 11 `textDim` | — | — |
| L-11 | Subject | fills the rest, ellipsis (pills first, then text) | 12 | — | — |
| L-12 | Ref pill | margin-right 6, padding 0 5, 1pt `accent` border, radius 8, line height 14, raised 1 | 10 `accent` | — | HEAD's commit: fill `accent`, text `onAccent` |
| L-13 | Author / date | own width; author at most 20% of the row's content box, ellipsis | 11 `textDim` | — | — |
| L-14 | Load more | full width − 16, margin 6 8, padding 4, 1pt `border`, radius 3 | 11 `textDim`, centered | — | hover: text `text`, fill `hover` at 0.12 |
| L-15 | Detail panel | height = fraction of the body, padding 8 10, 1pt `border` on top, scrolls | 12 | — | — |
| L-16 | Message | margin below 8, newlines kept, wraps (overlong words broken) | 12 `text` | — | — |
| L-17 | Fields | two columns (labels as wide as the widest, values the rest), gap 2 10, margin below 8 (kept when empty) | 11; labels `textDim`; values mono, wrap anywhere | — | — |
| L-18 | Files | 1pt `border` on top, padding-top 6; row gap 8, line height 17 | 11 | — | — |
| L-19 | File stat | width 84, right-aligned, gap 5 | mono 11; `+n` `#59b871`, `−m` `#e0705a`; "binary" `textDim` | — | — |
| L-20 | File path | wraps anywhere | mono 11 | — | — |
| L-21 | Dim lines | margins 12 | `textDim` | — | — |
| L-22 | Divider (open) | 0 tall; hit strip 7 (3 above, 4 below the detail's top border), up-down resize cursor | — | — | — |
| L-23 | Divider (collapsed) | 8 tall, 1pt `border` on top; grip 24×2, radius 1, centered below the border | — | grip `textDim` at 0.6 | hit strip from 4 above to its bottom |
| L-24 | Notice | padding 16; paragraphs margin below 6 | 12; hint `textDim` | — | — |
| L-25 | List focus | inset 1pt `accent` ring | — | — | keyboard focus only |
| L-26 | Folder button | header button: 13 icon, padding 2 5 → 23×17, radius 3 | — | icon `textDim`; hover fill `hover` at 0.12 | tooltip and AX label "Choose a repository" |

## Checking the look

- Scenarios `Plugins/GitTree/Visual/scenarios/git-tree-*.json`: `git-tree-default`,
  `git-tree-light`, `git-tree-columns`, `git-tree-collapsed`, `git-tree-split`,
  `git-tree-working-tree`, `git-tree-hover-row`, `git-tree-lanes` (8 lanes, palette cycling),
  `git-tree-notice`, `git-tree-load-more`, `git-tree-load-more-hover`, `git-tree-empty-detail`,
  `git-tree-truncated-files`, `git-tree-narrow`. Each seeds its history; dates pinned to UTC. The
  scenario format and the capture's plugin hooks: `Visual/README.md`.
- A git tree leaf's config is `{cwd, branchScope?, detailFraction?, detailCollapsed?}`; the git
  tree's settings, if any, go in `settings.plugins["git-tree"]`.
- The real plugin bundle, its pane answered from the scenario's `content` entry by the Debug verb
  `git-tree.test.stage` (and settled: read, the selection made, its details read); geometry from
  `git-tree.test.visual`.

The `content` entry:

- Exactly one of `log` `{root, commits: [Commit…], hasMore, hasUncommittedChanges}` or `failure`
  (a `GitFailure`: `git-missing`, `no-such-directory` `{path}`, `not-a-repo` `{path}`, `no-commits`
  `{root}`, `failed` `{message}`).
- `details` `{"<hash>": CommitDetail}`: an unset hash gets one synthesized from its log entry
  (message = subject, no files).
- `workingTree`: a `CommitDetail` (hash `""`). `head`: a `GitHead` (default
  `{kind: "branch", name: "main"}`).
- `select`: a hash, or `""` for the working-tree row (needs `hasUncommittedChanges`); default the
  newest commit.
- Shapes: `Plugins/GitTree/Sources/Model/GitTypes.swift`. Dates ISO, shown in UTC.

Geometry: `content.<leaf id>`, window coordinates. `git-tree.test.visual` reports the toolbar's keys
(`pathInput` … `selectBaseline`) in the header title view's coordinates (the toolbar is the
header's title) and the rest in the git tree view's; the capture offsets each to the window.

- `pathBaseline`/`selectBaseline`: one line of text centered in the control's content box.
- Text rect over wrapped text (a long file path): the bounding box of every line.
- The branch-scope menu is as wide as its widest option ("All local branches", 123 at 11pt);
  label ~9.5 in; bold chevron ~9×5.5, 4.5 from the right, vertically centered.

```jsonc
"content": {
  "<leaf id>": {
    "container": R,                           // the git tree's view (= the pane body)
    "pathInput": R,                           // toolbar parts: in the header
    "browse": R,                              // the folder button
    "pathBaseline": number | null,            // the path field's text baseline
    "head": R | null, "headText": R | null, "headBaseline": number | null,   // HEAD label box, its text; null without a log
    "select": R,
    "selectBaseline": number | null,          // the branch-scope menu's label baseline
    "state": "loading" | "list" | "notice",
    "notice": R | null,                       // the notice box (loading or failure)
    "noticeLines": [{"text": R, "baseline": number}],   // each paragraph of the failure notice
    "list": R | null,                         // the scrolling commit list
    "rows": {                                 // every row, including ones scrolled out of view (not clipped)
      "<full hash, or 'working-tree'>": {
        "rect": R, "gutter": R,               // the row; its graph
        "hash": R | null, "hashBaseline": number | null,          // null on the working-tree row
        "subject": R,                         // the subject box (refs + text, the rest of the row, ellipsis)
        "subjectText": R | null,              // the subject's own text (after the pills), clipped to the box
        "subjectBaseline": number | null,
        "truncated": bool,                    // drawn with an ellipsis
        "refs": [R, …],                       // ref pill boxes, in order
        "author": R | null, "date": R | null, // text rects, when those columns are on
        "selected": bool, "phantom": bool     // phantom = the dimmed working-tree row
      }
    },
    "loadMore": R | null,                     // the Load more button box
    "divider": R | null,                      // 0 tall while the details are open, 8 collapsed
    "dividerCollapsed": bool,
    "detail": R | null,                       // the detail panel (null while collapsed)
    "message": R | null,                      // the commit message box
    "fields": [{"dt": R, "dd": R}],           // label and value text rects, in order (Commit, Author, Date, Parent(s), Refs)
    "files": [{"row": R, "stat": R,           // boxes
               "insertions": R | null, "deletions": R | null, "binary": R | null, "path": R}],  // text rects
    "detailNotes": [R]                        // text rects of the detail's dim paragraphs ("No files changed…")
  }
}
```

- `Plugins/GitTree/Visual/golden/<name>.geometry.json` are recorded from the app (`make
  visual-golden` re-records them after an intended change);
  `GeometryGoldenTests/theGeometryMatchesTheGolden` holds every scenario to its golden within
  0.5 pt, and `GeometryGoldenTests/everyScenarioHasAGolden` requires one per scenario.
- Pixels: `make visual-baseline` captures the scenarios with the build before a change; `make
  visual` captures them with the current build and compares pixels and geometry
  (`build/visual/compare/index.html`).

## Notes

- **Narrow window**: the title slot shrinks to nothing (`headerTitle` has no minimum width), so
  the toolbar clips. `git-tree-narrow` (460 pt) stays above that.
- **Menus are core's** (`showContextMenu`): the row menu (X-1) and the branch select's pop-up
  (B-1): no checkmark on the current scope (the label says it); it opens under the select. The
  select never takes keyboard focus: no keyboard operation, no focus border (L-5).
- **Path bar editor** is an `NSTextField`, shown only while editing; its text line sits 1 pt
  higher than the text the bar draws at rest.
- **Auto-refresh on toolbar activation** still runs (D-12).
- **Rows aren't accessibility elements**: the list is one AX element (list, "Commits"); the
  keys (S-3) still move the selection.
