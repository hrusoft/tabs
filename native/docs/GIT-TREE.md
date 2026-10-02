# Git tree

A pane showing a repository's commit graph: a lane-gutter commit list, the selected commit's
detail below it, a divider between. Port of Electron's `packages/plugin-gitTree`.

## Scope

- Toolbar (path bar, folder button, HEAD label, branch-scope select) = the pane header's title
  (`PaneController.headerTitle`); the body is list + detail only.
- Chrome is core's, never copied: theme tokens (`PaneContext.theme`,
  `paneAppearanceDidChange`), attention (`paneDidBecomeAttended`; no own active-pane tracking),
  menus (`showContextMenu`), dialogs (`confirm`/`choose`/`alert`: cards in the pane's window),
  picker (`chooseDirectory`). Plugin-owned colors: `GitTreeColors` only (lanes, diff stats).
- git: the user's, with the pane's `childEnvironment`; always async; never throws (`GitError`
  values); nothing at quit.
- AX ids = Electron's `data-testid`s (`git-tree`, `git-tree-list`, `git-tree-detail`,
  `git-tree-divider`, `git-tree-path-input`, `git-tree-browse-button`, `git-tree-branch-scope`).

## Sources

Native paths under `Plugins/GitTree/Sources/`, Electron under `packages/plugin-gitTree/`,
unless rooted.

| Native | Electron | What |
|---|---|---|
| `GitTreePlugin.swift` | `renderer/gitTreeContentDef.ts`, `renderer/index.ts`, `settings/index.ts` | Type `git-tree` (Electron `gitTree`), `git-tree.refresh`, settings page; `GitTreeServices` (live panes, checkout refresh, copy) |
| `Plugins/GitTree/Info.plist` | `shared/manifest.ts` | Manifest (`canDisable`) |
| `Model/GitTypes.swift` | `shared/types.ts` | Wire shapes; `uncommittedChangesHash` (`""`) |
| `Model/Graph.swift` | `shared/graph.ts` | `assignLanes` |
| `Model/CheckoutTargets.swift` | `shared/checkoutTargets.ts` | `splitRemoteRef`, `decideCheckout`, `checkoutTargetLabel` |
| `Model/DetailSplit.swift` | `renderer/detailSplit.ts` | `readDetailSplit`, `resolveDetailDrag` |
| `Model/Format.swift` | `renderer/format.ts`, `GitTreeRenderer.tsx` (`baseName`) | `shortHash`, `formatDate`, `baseName` |
| `Model/GitTreeSettings.swift` | `shared/settings.ts` | Settings value |
| `Git/Git.swift`, `Git/GitProcess.swift` | `main/git.ts` | Runner (`execFile` rules), parsers, reads, `checkout` |
| `Git/GitSource.swift` | `renderer/gitTreeBridge.ts`, `main/index.ts` (`defaultDirectory`), `testing/fakeApi.ts` | `GitRepositorySource`; Debug `ScriptedGitSource` |
| `UI/GitTreePane.swift` | `GitTreeRenderer.tsx`, `GitTreeHeaderTitle.tsx` (state) | Controller: loads, generations, selection, detail, paging, refresh, checkout, config |
| `UI/GitTreeView.swift` | `GitTreeRenderer.tsx` (markup) | Loading / list + detail / notice; list focus ring |
| `UI/GitTreeToolbar.swift` | `GitTreeHeaderTitle.tsx` | The toolbar |
| `UI/CommitListView.swift` | `CommitRow.tsx`, `GitGraph.tsx` | Rows, gutter, hover, keys, Load more, row menu |
| `UI/CommitDetailView.swift` | `CommitDetailPanel.tsx` | Detail panel |
| `UI/DetailDivider.swift` | `DetailDivider.tsx` | Divider drag |
| `UI/GitTreeStyle.swift` | `gitTree.css`, `GitGraph.tsx` | Metrics, Chromium-like text (`GitText`, `snap`), `GitTreeColors` |
| `UI/GitTreeGlyphs.swift` | `renderer/gitTreeIcons.tsx` | Pane and folder icons |
| `UI/GitTreeSettingsPage.swift` | `settings/GitTreeSettingsPage.tsx` | Three toggles |
| `GitTreeTestVerbs.swift` (Debug) | `testing/visualCapture.ts` | `git-tree.test.script`, `.state`, `.geometry` |
| `Sources/Tabs/Testing/VisualCapture.swift` (Debug) | `src/renderer/harness.html` | Stages `git-tree-*` scenarios |

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

| Id | Case | Electron | Native test |
|---|---|---|---|
| D-1 | Shows the repository containing `config.cwd` (the pane's subject, saved) | `GitTreeRenderer` | `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| D-2 | Created from a pane offering a working directory → opens there. Ungated (no inherit setting) | `gitTreeContentDef.ts:deriveConfig` | `GitTreeInheritanceTests/inherits`, `UITests.GitTreeUITests/aGitTreeFromATerminalOpensWhereTheShellIs` |
| D-3 | Origin offers nothing (plain pane, no origin, offer withdrawn) → default directory, never blank | `deriveConfig` → default effect | `GitTreeInheritanceTests/noDirectory`, `GitTreeInheritanceTests/fromNothing` |
| D-4 | Default: the app's working directory if in a repository, else home; written into config | `main/index.ts:defaultDirectory` | `GitTreeDirectoryTests/adoptsDefault`, `ReadLogRealTests/defaultDirectoryPrefersARepositoryElseHome` |
| D-5 | A directory chosen while the default lookup is pending wins | `GitTreeHeaderTitle` (`directoryChosen`) | `GitTreeDirectoryTests/aChoiceMadeWhileTheDefaultIsPendingWins` |
| D-6 | Offers its configured directory as working directory (a terminal made from it starts there); none while the default is pending | `exposeCwd` | `GitTreeInheritanceTests/offersItsDirectory`, `UITests.GitTreeUITests/aTerminalFromAGitTreeStartsInItsRepository` |
| D-7 | Path bar: Return or leaving the field applies the trimmed text; empty or unchanged → nothing | `GitTreeHeaderTitle:applyPath` | `GitTreeDirectoryTests/pathBar`, `UITests.GitTreeUITests/thePathBarReadsWhatIsTyped` |
| D-8 | Path bar: Escape restores the configured directory | path input `onKeyDown` | `GitTreeDirectoryTests/typingWins` |
| D-9 | Path bar keys stay in it: arrows move the caret, not the selection | path input `onKeyDown` (`stopPropagation`) | `GitTreeDirectoryTests/pathBarKeys`, `UITests.GitTreeUITests/thePathBarReadsWhatIsTyped` |
| D-10 | Path bar follows config changes from elsewhere (default adopted), except while being edited | `GitTreeHeaderTitle` sync effect | `GitTreeDirectoryTests/typingWins`, `GitTreeDirectoryTests/adoptsDefault` |
| D-11 | Folder button → open-panel sheet "Choose a repository" at the current directory; Cancel → nothing. No window (tests, hidden) → cancelled; the sheet itself is hand-checked | `GitTreeHeaderTitle:browse` | `GitTreeDirectoryTests/browseAdopts`, `GitTreeDirectoryTests/browseCancelled` |
| D-12 | A toolbar press activates the pane without pulling the keyboard to the list (`focus()` skips while the path bar edits). **Not yet:** auto-refresh still runs on that activation (`paneDidBecomeAttended` has no toolbar check; Electron skips it) | focus handle (`focusIsInPaneChrome`) | — |

### The history list

| Id | Case | Electron | Native test |
|---|---|---|---|
| H-1 | One row per commit, newest first (`--date-order`): short hash (7), ref pills, subject | `CommitRow` | `GitTreeListTests/rows`, `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| H-2 | Refs split out of `%D`: `HEAD -> main` → `HEAD`, `main` | `git.ts:parseRefs` | `GitTreeListTests/rows`, `GitParserTests/parseRefsSplitsHeadArrow` |
| H-3 | Every pill on HEAD's commit is filled (inverted) | `.git-tree-ref-head` | — (pixels) |
| H-4 | Dirty tree → dimmed italic "Uncommitted changes" row on top, joined into the graph (parent = newest real commit); also with no commits yet | `commits` memo | `GitTreeListTests/workingTreeRow`, `ReadLogRealTests/dirtyThenClean` |
| H-5 | Clean tree → no such row; a drifted submodule doesn't count | `readLog` (`--ignore-submodules`) | `GitTreeListTests/cleanTree` |
| H-6 | Working-tree row: no hover wash; double-click and right-click do nothing | `.git-tree-row-phantom:hover`, `CommitRow` | `GitTreeListTests/workingTreeRow`, `GitTreeCheckoutTests/workingTreeRow` |
| H-7 | Author and date columns hidden by default; each shows when its setting is on (live) | `CommitRow` | `GitTreeListTests/columnsHidden`, `GitTreeListTests/columnsShown` |
| H-8 | Dates `YYYY-MM-DD HH:MM`, local time; unparseable text passes through | `format.ts:formatDate` | `FormatTests/formatDateReadsAsSortableLocalTime` |
| H-9 | Hover washes a row; the selected row is accent-tinted | `gitTree.css` | — (pixels: `git-tree-hover-row`) |
| H-10 | Load more only when the log has more; appends the next 500 (`skip` = real rows) without re-reading or blanking | `GitTreeRenderer:loadMore` | `GitTreeListTests/loadMore`, `ReadLogRealTests/pagesWithHasMore` |
| H-11 | A page arriving after the list was replaced (directory change, refresh) is dropped (`logVersion`) | `loadMore` (`current !== log`) | — |
| H-12 | A failed Load more replaces the list with the failure | `loadMore` (`!result.ok`) | `GitTreeFailureTests/aFailedLoadMoreReplacesTheList` |

### The graph

| Id | Case | Electron | Native test |
|---|---|---|---|
| R-1 | Lanes, one pass in given order: leftmost lane waiting for the commit takes the dot (others released); unwaited → leftmost free lane; first parent inherits the dot's lane; others reuse a lane waiting for them, else leftmost free; trailing free lanes trimmed. `through` by lane index, never by hash (siblings sharing a parent) | `shared/graph.ts:assignLanes` | `GitTreeModelTests.swift` graph suites (`LinearHistoryTests` … `EmptyLogTests`) |
| R-2 | One gutter width for every row: the widest row's lanes × 12, at least one lane | `GitGraph` | `GitTreeListTests/gutter`, `ReadLogRealTests/merge` |
| R-3 | Order: through (behind), incoming (top → dot), outgoing (dot → bottom); S-curves, control points at mid-height; color = source lane (through, in) / target lane (out) | `GitGraph` | — (pixels: `git-tree-lanes`) |
| R-4 | Dot hollow (`--bg` fill), filled when selected; extra ring on HEAD's commit | `GitGraph` | — (pixels) |
| R-5 | Six lane colors cycling by lane index, same in both themes | `GitGraph.tsx:LANE_COLORS` | — (pixels: `git-tree-lanes`, `git-tree-light`) |

### Selection and keys

| Id | Case | Electron | Native test |
|---|---|---|---|
| S-1 | A loaded list selects the newest real commit (working-tree row skipped) | selection effect | `GitTreeListTests/selectsNewest` |
| S-2 | Selection survives a re-read while its commit is there; else newest real commit | selection effect | `GitTreeListTests/theSelectionSurvivesARereadWhileItsCommitIsThere` |
| S-3 | ↓/↑ move one, clamped at the ends; Home/End jump (Home reaches the working-tree row); moved-to row scrolled into view minimally | `moveSelection` (`block: 'nearest'`) | `GitTreeListTests/arrows`, `GitTreeListTests/homeReachesWorkingTree` |
| S-4 | Other keys go up to the app (pane navigation) | `onKeyDown` default | — |
| S-5 | Click selects and gives the list the keyboard | `CommitRow` `onClick` | `GitTreeListTests/clickSelects`, `UITests.GitTreeUITests/clickingARowSelectsIt` |
| S-6 | The list holds focus as a whole; pane activation focuses it | `aria-activedescendant`, focus handle | `GitTreeListTests/listKeepsFocus` |
| S-7 | Inset accent ring only when focused from the keyboard (native: focus arrived during a key event) | `.git-tree-list:focus-visible` | — |

### The detail panel

| Id | Case | Electron | Native test |
|---|---|---|---|
| P-1 | Full message; Commit (full hash), Author `name <email>`, Date (row format), Parent/Parents (short, comma-separated), Refs (comma-separated) | `CommitDetailPanel` | `GitTreeListTests/detail`, `ReadLogRealTests/commitFiles` |
| P-2 | Files with `+n −m` (U+2212, not `-`), or "binary" (numstat `-`: nil counts, never 0) | `CommitDetailPanel` | `GitTreeListTests/detail`, `ReadLogRealTests/aBinaryFileHasNoCounts` |
| P-3 | A merge lists its files against the first parent; a root commit lists its files | `readCommit` (`-m --first-parent`) | `ReadLogRealTests/mergeFiles`, `ReadLogRealTests/rootFiles` |
| P-4 | No files: "No files changed against the first parent." (commit) / "No uncommitted changes." (working tree) | `CommitDetailPanel` | `GitTreeListTests/theDetailPanelsDimLinesSayWhatsMissing` |
| P-5 | Over 500 files: the first 500, then "Only the first files are listed." | `git.ts` `FILE_CAP` | `GitParserTests/parseNumstatCutsAtTheFileCap` |
| P-6 | Working-tree detail: message "Uncommitted changes", no Commit/Author/Date, Parent = HEAD. Files: tracked (staged + unstaged, one diff), then other status paths counted off disk (lines = insertions; NUL in the first 8000 bytes = binary; unreadable → no counts); no commits yet → all off disk; one 500 cap | `readWorkingTreeChanges` | `GitTreeListTests/selectWorkingTree`, `ReadWorkingTreeChangesTests`, `ReadLogRealTests/noCommitsButStaged` |
| P-7 | Nothing selected, not read yet, or a failed read: "Select a commit." | `CommitDetailPanel` | `GitTreeListTests/theDetailPanelsDimLinesSayWhatsMissing` |
| P-8 | Read debounced 100 ms (a held arrow reads only where it settles); the same row's detail stays up while re-read | detail effect | — |
| P-9 | ⌘R re-reads the working-tree row's detail (keyed on the log too: its hash never changes) | `detailKey` | `GitTreeListTests/refreshWorkingTree` |
| P-10 | Collapsed: nothing read; reopening shows the kept detail, then re-reads | detail effect (`detailCollapsed`) | `GitTreeDividerTests/savedCollapse` |

### The divider

| Id | Case | Electron | Native test |
|---|---|---|---|
| V-1 | Untouched pane: details 40% of the body, open; nothing saved | `DEFAULT_DETAIL_FRACTION` | `GitTreeDividerTests/untouched`, `ReadDetailSplitTests/untouched` |
| V-2 | Saved `detailFraction`/`detailCollapsed` open as saved; fraction must be finite in (0, 1), collapsed a literal `true`, else defaults | `readDetailSplit` | `GitTreeDividerTests/saved`, `ReadDetailSplitTests` |
| V-3 | Drag previews every move, saves on release; a press that moves nothing saves nothing | `DetailDivider`, `commitSplit` | `GitTreeDividerTests/drag`, `GitTreeDividerTests/stillPress` |
| V-4 | Details < 30 (half the 60 minimum) → collapse, keeping the last open fraction; 30–60 → hold at 60; list keeps ≥ 3 rows (72); body too short for both → details keep 60; saved fraction ≤ 0.99; zero-height body → unchanged | `resolveDetailDrag` | `GitTreeDividerTests/collapseAndReopen`, `ResolveDetailDragTests` |
| V-5 | Collapsed: 8 pt bar with a grip; dragging it up reopens the details on the selected commit | `DetailDivider`, `.git-tree-divider-collapsed` | `GitTreeDividerTests/collapseAndReopen` |
| V-6 | An unseen release (a move with the button up) ends the drag where last shown | `DetailDivider` `onPointerMove` | `GitTreeDividerTests/unseenRelease` |
| V-7 | A press a core split separator claims is core's (the collapsed bar's lower part yields to a split below) | `DetailDivider` (`defaultPrevented`) | — (core's separators sit above pane views) |
| V-8 | Pressing the divider takes no focus from the list, starts no selection | `onMouseDown` `preventDefault` | — |

### Refreshing

| Id | Case | Electron | Native test |
|---|---|---|---|
| F-1 | ⌘R (View ▸ Refresh) re-reads the active git tree in place, no "Reading history…" flash | `GitTreeRenderer:refresh` | `GitTreeRefreshTests/refresh`, `UITests.GitTreeUITests/commandRReReadsTheActivePane` |
| F-2 | ⌘R does nothing unless a git tree pane is active | `refresh` capability | `GitTreeRefreshTests/refreshElsewhere` |
| F-3 | Every first-page read claims a generation; only the latest commits | `fetchGeneration` | `GitTreeRefreshTests/onlyTheLatestFirstPageReadCommits` |
| F-4 | Directory or branch-scope change → "Reading history…", page 0 | load effect | — |
| F-5 | Auto-refresh on focus (off by default): re-read when the pane becomes active in a focused window | focus handle → `refreshIfAttended` | `GitTreeRefreshTests/autoRefreshReReadsWhenThePaneBecomesActive` |
| F-6 | …and when its window regains focus with it already active; losing focus, or another pane active, reads nothing | `onWindowFocus` | `GitTreeRefreshTests/autoRefreshOn`, `GitTreeRefreshTests/windowRefocusDoesNothingWhenAnotherPaneIsActive` |
| F-7 | Auto-refresh skipped while a first-page read is in flight (opening reads once); ⌘R never skipped | `fetchPending` | `GitTreeRefreshTests/autoRefreshIsSkippedWhileAReadIsInFlight` |

### Branch scope

| Id | Case | Electron | Native test |
|---|---|---|---|
| B-1 | Select offers Current branch / All local branches / All branches; default All branches | `BRANCH_SCOPE_OPTIONS` | `GitTreeDirectoryTests/scopeOptions` |
| B-2 | Choosing re-reads with it (`HEAD` / `--branches` / `--branches --remotes`; never tags), saved as `config.branchScope` | `git.ts:scopeArgs` | `GitTreeDirectoryTests/chooseScope`, `ReadLogRealTests/branchScopes` |
| B-3 | A restored pane reads with its saved scope | `config.branchScope` | `GitTreeDirectoryTests/restoredScope` |
| B-4 | HEAD label: the branch, or `detached at <short>`; absent while loading or failed | `headLabel` | `GitTreeDirectoryTests/theHeadLabelReadsTheBranchOrDetached`, `ReadLogRealTests/head` |

### Failures and empty states

| Id | Case | Electron | Native test |
|---|---|---|---|
| E-1 | Not a repository: "No git repository at <path>." + hint; the pane stays usable | `failureMessage` | `GitTreeFailureTests/notARepo`, `ReadLogRealTests/notARepo` |
| E-2 | No commits: "<root> is a git repository, but has no commits yet." Detected from an empty first page + clean tree (a ref-scoped `log` succeeds empty) or the stderr phrases | `readLog`, `classify` | `GitTreeFailureTests/noCommits`, `ReadLogRealTests/noCommits` |
| E-3 | git missing: "git isn’t installed, or isn’t on this app’s PATH." | `classify` (ENOENT) | `GitTreeFailureTests/gitMissing`, `ReadLogRealTests/aMissingGitNamesItself` |
| E-4 | Directory doesn't exist: "No directory at <path>." (not git-missing) | `classify` (ENOENT + stat) | `GitTreeFailureTests/noSuchDirectory`, `ReadLogRealTests/noSuchDirectory` |
| E-5 | Anything else: git's first non-empty stderr line | `classify` | `GitTreeFailureTests/unclassified`, `GitParserTests/classifyReadsGitsStablePhrases` |
| E-6 | Hint under every failure: "Type a directory above, or use the folder button to choose one." | `GitTreeRenderer` | `GitTreeFailureTests/notARepo` |
| E-7 | Git runner rules (Git commands): 10 s timeout, 32 MB stdout cap, no prompts, no optional locks, raw non-ASCII paths, never throws | `git.ts:git` | — |

### Checking out

| Id | Case | Electron | Native test |
|---|---|---|---|
| C-1 | Double-click a row, or its menu's Checkout: refs at that commit read fresh (`for-each-ref`, never `%D`), decided (C-12), checked out | `handleCheckout` | `GitTreeCheckoutTests/menuCheckout`, `UITests.GitTreeUITests/doubleClickChecksOutTheOneBranch` |
| C-2 | One local branch there → `git switch <name>`, no prompt; the pane refreshes to the new HEAD | `handleCheckout` (`single`) | `GitTreeCheckoutTests/oneBranch`, `UITests.GitTreeUITests/doubleClickChecksOutTheOneBranch` |
| C-3 | No local branch, one remote-tracking branch no local branch shares a name with → `git switch -c <name> --track <ref>` | `decideCheckout` | `GitTreeCheckoutTests/remote` |
| C-4 | Several targets → choose dialog "Several branches point at <short> — <subject>. Which one?", options = labels in refname order, first preselected, confirm "Checkout"; Cancel → nothing | `handleCheckout` (`choose`) | `GitTreeCheckoutTests/severalBranches`, `UITests.GitTreeUITests/doubleClickOnSeveralBranchesAsksWhichOne` |
| C-5 | No target → confirm "Checking out <short> — <subject> will leave HEAD detached — it won't be on any branch. Continue?" (confirm "Checkout") → `git switch --detach <hash>`; Cancel → nothing | `handleCheckout` (`none`) | `GitTreeCheckoutTests/noBranch`, `UITests.GitTreeUITests/doubleClickOnABranchlessCommitAsksBeforeDetaching` |
| C-6 | Failed switch → one-button alert "Checkout failed" with git's full stderr (trimmed, 20 lines + "… (n more lines)"), or the one-line reason when git printed nothing; this pane (and C-9's) still refreshes | `performCheckout` | `GitTreeCheckoutTests/refusal`, `UITests.GitTreeUITests/aRefusedCheckoutIsAnAlertWithGitsWords` |
| C-7 | One checkout at a time per pane: a trigger while one runs is dropped (no second ref read) | `checkoutInFlightRef` | `GitTreeCheckoutTests/inFlight` |
| C-8 | Failed ref read → same alert, one-line reason; no checkout, no refresh; the next checkout works. (Electron also alerts on a throw mid-flow; native can't throw) | `handleCheckout` (`!refs.ok`, `catch`) | `GitTreeCheckoutTests/refReadFails` |
| C-9 | After a checkout, other git trees with the exact same `cwd` string refresh; other directories don't. **Deviation:** in any window (Electron: same window only; `layout.allRoots()` is per renderer) | `refreshAfterCheckout` | `GitTreeCheckoutTests/refreshesSibling`, `GitTreeCheckoutTests/notOtherDirectory` |
| C-10 | Nothing to check out on the working-tree row | `CommitRow` (handlers unwired) | `GitTreeCheckoutTests/workingTreeRow` |
| C-11 | Git layer: refs at a hash = local branches, remote-tracking ones (minus `<remote>/HEAD`, split against `git remote`), every local branch name; the three `switch` shapes; a refusal leaves HEAD untouched and keeps git's text | `git.ts:branchesAtCommit`, `checkout` | `BranchesAtCommitTests`, `CheckoutRealTests` |
| C-12 | Policy: local branches win; remote-tracking only with none local, minus any whose name a local branch anywhere has; 1 → single, >1 → choose, 0 → none. Labels: branch name / remote's full ref / hash. `splitRemoteRef`: longest configured remote first, else first segment | `shared/checkoutTargets.ts` | `SplitRemoteRefTests`, `DecideCheckoutTests`, `CheckoutTargetLabelTests` |

### Context menu

| Id | Case | Electron | Native test |
|---|---|---|---|
| X-1 | Right-click a row: selects it; menu Checkout, then Copy SHA-1 (both always enabled) | `openCommitMenu`, `CommitRow` | `GitTreeCheckoutTests/menu`, `UITests.GitTreeUITests/rightClickSelectsTheRowAndOffersCheckoutThenCopy` |
| X-2 | Both items act on the row right-clicked, not an earlier selection; Copy SHA-1 = full hash | `openCommitMenu` | `GitTreeCheckoutTests/copy` |
| X-3 | No menu, and no selection, from a right-click on the working-tree row | `CommitRow` | `GitTreeCheckoutTests/workingTreeRow` |

### Title

| Id | Case | Electron | Native test |
|---|---|---|---|
| T-1 | Tab title = the repository root's last path segment | `setLiveTitle` effect | `GitTreeListTests/title`, `UITests.GitTreeUITests/aPaneShowsARealRepository` |
| T-2 | Failed read → the directory's last segment, not the old repository's name | ″ | `GitTreeFailureTests/titleFollows` |
| T-3 | Header shows the toolbar, no title and no Edit title; a press on a control activates without a drag, one on the slot's empty space drags | `src/renderer/src/content/Pane.tsx` (`HeaderTitle`) | `GitTreeDirectoryTests/toolbarIsTheHeaderTitle`, `UITests.GitTreeUITests/theHeadersControlsDoNotStartAPaneDrag`, `UITests.HeaderTitle` |

### Settings (Settings ▸ Git tree)

| Id | Case | Electron | Native test |
|---|---|---|---|
| ST-1 | "Auto-refresh on focus", off: "Re-read a git tree pane's history whenever it becomes active while the window is focused." (id `settings-auto-refresh-checkbox`) | `settings/GitTreeSettingsPage.tsx` | `GitTreePluginTests/contributesASettingsPage` |
| ST-2 | "Show author column", off: "Show who authored each commit in the commit list, alongside its hash and message." (id `settings-show-author-column-checkbox`) | ″ | `GitTreeListTests/columnsShown` |
| ST-3 | "Show date column", off: "Show each commit's date in the commit list, alongside its hash and message." (id `settings-show-date-column-checkbox`) | ″ | `GitTreeListTests/columnsShown` |
| ST-4 | Stored values merge over defaults per field; a wrong-typed field → its default; never throws | `shared/settings.ts:mergeGitTreeSettings` | `GitTreeSettingsTests` |

### Shortcuts

| Id | Case | Electron | Native test |
|---|---|---|---|
| K-1 | ⌘R, View ▸ Refresh: plugin command `git-tree.refresh` (group Git tree, rebindable), only while a git tree pane is active | `shortcuts.ts` `refresh-pane` (core, Panes & Tabs) | `GitTreeRefreshTests/refreshIsAViewCommandOnCommandRForGitTreesOnly`, `UITests.GitTreeUITests/commandRReReadsTheActivePane` |
| K-2 | ↓ ↑ Home End in the list, by key (not rebindable) | `onKeyDown` | `GitTreeListTests/arrows`, `GitTreeListTests/homeEnd` |

### Persistence

| Id | Case | Electron | Native test |
|---|---|---|---|
| PS-1 | `cwd`, `branchScope`, `detailFraction`, `detailCollapsed` saved in the pane's config; relaunch reopens the same repository, scope and split. Non-object config or non-string `cwd` → refused (no pane) | `setLeafConfig` | `GitTreeDirectoryTests/anUnreadableConfigIsRefused`, `GitTreeEndToEndTests/theRepositoryAPaneReadsSurvivesARelaunch` |
| PS-2 | Nothing else kept: no cache, no quit work, no process near quit; unknown config keys survive | `main/index.ts` (no hooks) | `GitTreePluginTests/savesItsStateInTheConfigAndKeepsUnknownKeys` |

### Disabling

| Id | Case | Electron | Native test |
|---|---|---|---|
| DS-1 | Disabled (`canDisable`): no creation action or settings page; open panes keep working | `manifest.ts` `canDisable` | — (core's gate) |

## Look

From `gitTree.css` (px = pt). Colors are theme tokens (`src/shared/theme.ts`; native: core's
`PaneTheme`). Native text mimics Chromium (`GitText`): line box = rounded ascent + rounded
descent, baseline on a whole point; box edges snap round-half-up (`snap`); wrapping breaks after
spaces and letter-hyphens, never at `/` (an overlong word breaks where the line is full).

| Id | Element | Box | Text | Colors | States |
|---|---|---|---|---|---|
| L-1 | Container | fills the body, column, clips | `system-ui` (SF), `--text` | core's pane body | loading / list + detail / notice |
| L-2 | Toolbar (header title) | header slot after the grip and signal icons, before the controls; 24 tall, items centered, gap 8 | — | the header's `--surface` | — |
| L-3 | Path bar | flex 1, height 20, padding 2 6, 1px `--border`, radius 3 | 12px `--text-dim` (the header's color) | bg `--bg` | focused: border `--accent`, no ring |
| L-4 | HEAD label | padding 0 4, max 40% of the header's content box, ellipsis | 11px `--text-dim` | — | absent without a log |
| L-5 | Branch select | width of the widest option + menulist chrome (123), height 20, padding 1 4, 1px `--border`, radius 3; Chromium's bold chevron ~9×5.5, 4.5 from the right | 11px `--text-dim`, inset ~9.5 | bg `--bg` | Electron focused: border `--accent` (native never focused) |
| L-6 | Row | height 24, gap 8, padding 0 8 0 6 | 12px `--text` | hover `rgb(hover / 0.08)`; selected `color-mix(accent 18%, transparent)`, also when hovered | working tree: opacity 0.6 (gutter included), italic subject, no hover |
| L-7 | Gutter | max(lanes, 1) × 12 wide, 24 tall; lane x = 12·lane + 6 | — | lanes `#4f8cff #e0a44a #59b871 #c76fd0 #46bcc4 #e0705a` | — |
| L-8 | Graph lines | stroke 1.5; cubic (x1,y1) → (x1,mid), (x2,mid) → (x2,y2) | — | lane color | — |
| L-9 | Dot / HEAD ring | r 3.5, stroke 1.5; ring r 5, stroke 1.5, no fill | — | fill `--bg`, lane color when selected | — |
| L-10 | Hash | — | `--font-mono` 11px `--text-dim`: Menlo on both (Chromium has no `ui-monospace`; SF Mono isn't installed) | — | — |
| L-11 | Subject | flex 1, ellipsis (pills first, then text) | 12px | — | — |
| L-12 | Ref pill | inline-block, margin-right 6, padding 0 5, 1px `--accent`, radius 8, line-height 14, vertical-align 1px | 10px `--accent` | — | HEAD's commit: bg `--accent`, text `--on-accent` |
| L-13 | Author / date | flex none; author max 20% of the row's content box, ellipsis | 11px `--text-dim` | — | — |
| L-14 | Load more | block, width 100% − 16, margin 6 8, padding 4, 1px `--border`, radius 3 | 11px `--text-dim`, centered | — | hover: text `--text`, bg `rgb(hover / 0.12)` |
| L-15 | Detail panel | basis = fraction of the body, padding 8 10, border-top 1px `--border`, scrolls | 12px | — | — |
| L-16 | Message | margin-bottom 8, pre-wrap, breaks words | 12px `--text` | — | — |
| L-17 | Fields | grid max-content / 1fr, gap 2 10, margin-bottom 8 (kept when empty) | 11px; dt `--text-dim`; dd mono, wraps anywhere | — | — |
| L-18 | Files | border-top 1px `--border`, padding-top 6; row gap 8, line-height 17 | 11px | — | — |
| L-19 | File stat | width 84, right-aligned, gap 5 | mono 11px; `+n` `#59b871`, `−m` `#e0705a`; "binary" `--text-dim` | — | — |
| L-20 | File path | wraps anywhere | mono 11px | — | — |
| L-21 | Dim lines | `<p>` margins 12 | `--text-dim` | — | — |
| L-22 | Divider (open) | 0 tall; hit strip 7 (3 above, 4 below the detail's top border), row-resize cursor | — | — | — |
| L-23 | Divider (collapsed) | 8 tall, border-top 1px `--border`; grip 24×2, radius 1, centered below the border | — | grip `--text-dim` at 0.6 | hit strip from 4 above to its bottom |
| L-24 | Notice | padding 16; paragraphs margin-bottom 6 | 12px; hint `--text-dim` | — | — |
| L-25 | List focus | inset 1px `--accent` ring | — | — | keyboard focus only |
| L-26 | Folder button | `.pane-header-button`: 13 icon, padding 2 5 → 23×17, radius 3 | — | icon `--text-dim`; hover bg `rgb(hover / 0.12)` | tooltip and AX label "Choose a repository" |

## Electron quirks kept for parity

- Path bar text is `--text-dim`, inherited from `.pane-header`, not `--text`.
- Checkout refresh matches other panes by exact `cwd` string, not by repository root.
- A failed Load more replaces the whole list with the failure notice.
- Only the first page reads `git status`: later pages never change the working-tree row.
- The detail's Date is the row format (local time), not the raw ISO date.
- Branch scope defaults to `all` (local + remote-tracking), not the current branch.
- No commits yet: only `local`/`all` say "has no commits yet"; `current` (`git log HEAD` on an
  unborn branch) shows git's "fatal: ambiguous argument 'HEAD'…" line.

## Not ported

- **Row accessibility** (`aria-activedescendant`, `option` rows): the list is one AX element
  (list, "Commits"); rows aren't exposed. Keys behave the same.

## Checking the look

- Scenarios `Visual/scenarios/git-tree-*.json`: default, light, columns, collapsed, split,
  working-tree, hover-row, lanes (8 lanes, palette cycling), notice, load-more,
  load-more-hover, empty-detail, truncated-files, narrow. Same seeded history on both sides;
  dates pinned to UTC.
- Electron: the harness registers the package's real content def, so the toolbar is the
  header's real `HeaderTitle`, answered by the fake bridge (`testing/visualCapture.ts`).
- Native: the real plugin bundle, answered by the Debug verb `git-tree.test.script`; geometry
  from `git-tree.test.geometry`.
- Geometry: the `gitTree.<leaf id>` block (keys in `Visual/README.md`), window coordinates,
  toolbar included; gate `VisualParityTests/theGeometryIsTheElectronApps` (±0.5 pt).
- Pixels: `make visual` → `build/visual/compare/index.html`.

## Known differences

- **Narrow window**: Electron's header overflows and pushes its controls out of the bar; the
  native title slot shrinks to nothing (`headerTitle` has no minimum width), so the toolbar
  clips. `git-tree-narrow` (460 pt) stays above that.
- **Menus are core's** (`showContextMenu`): the row menu (X-1) and the branch select's pop-up
  (B-1): no checkmark on the current scope (the label says it); opens under the select. The
  select never takes keyboard focus: no keyboard operation, no focus border (L-5).
- **Path bar editor** is an `NSTextField`, shown only while editing; its line sits 1 pt higher
  than Chromium's. At rest the text is drawn where Chromium puts it.
- **Checkout refresh** reaches same-`cwd` git trees in every window (C-9).
- **Auto-refresh on toolbar activation** still runs (D-12).
