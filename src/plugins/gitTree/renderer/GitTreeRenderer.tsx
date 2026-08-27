import './gitTree.css'
import type { LeafContent } from '@shared/model/types'
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ContentRendererProps } from '../../../renderer/src/plugin/api'
import { assignLanes, type GraphRow } from '../shared/graph'
import type { Commit, CommitDetail, GitFailure, GitHead, GitLogResult } from '../shared/types'
import { GitGraph, LANE_COLORS, ROW_HEIGHT } from './GitGraph'
import { gitTreeBridge } from './gitTreeBridge'
import { FolderIcon } from './gitTreeIcons'
import { getGitTreeSettings } from './gitTreeSettingsAccess'
import { gitTreeCtx } from './pluginContext'

/**
 * A repository's commit graph: a path bar, a scrollable list of commits drawn
 * with a lane gutter, and a detail panel for whichever commit is selected.
 *
 * `node.config.cwd` is the directory the pane is looking at, and it is the
 * pane's whole subject — so it is written back through `setLeafConfig` on
 * every change, which is what makes a restored layout reopen the same
 * repository (the same pattern BrowserRenderer uses for `config.url`).
 *
 * All git work happens in main and arrives as data (see
 * src/plugins/gitTree/main/git.ts); nothing here can throw from a failed
 * `git`, because nothing there rejects. The four failure kinds are rendered as
 * sentences beside the same path bar and browse button, so every one of them
 * is a state you can act on rather than a dead end.
 */

/** Commits per page. Big enough that most repositories need no second read, small enough to stay instant on a huge one. */
const PAGE_SIZE = 500

/** The gutter palette as CSS custom properties, computed once — gitTree.css consumes these, GitGraph.tsx owns them. */
const LANE_VARS = Object.fromEntries(
  LANE_COLORS.map((color, index) => [`--git-lane-${index}`, color])
) as React.CSSProperties

function shortHash(hash: string): string {
  return hash.slice(0, 7)
}

/** Author dates as `2026-08-05 14:32` in local time — sortable at a glance, and no relative-time ticking to keep alive. */
function formatDate(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  const pad = (value: number) => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

/** The trailing path segment, which is what a repository is called in conversation. */
function baseName(path: string): string {
  const parts = path.split('/').filter((part) => part.length > 0)
  return parts[parts.length - 1] ?? path
}

function failureMessage(reason: GitFailure): string {
  switch (reason.kind) {
    case 'git-missing':
      return 'git isn’t installed, or isn’t on this app’s PATH.'
    case 'no-such-directory':
      return `No directory at ${reason.path}.`
    case 'not-a-repo':
      return `No git repository at ${reason.path}.`
    case 'no-commits':
      return `${reason.root} is a git repository, but has no commits yet.`
    default:
      return reason.message
  }
}

function headLabel(head: GitHead): string {
  return head.kind === 'branch' ? head.name : `detached at ${shortHash(head.hash)}`
}

/**
 * One commit row. Memoized so a selection change reconciles only the two rows
 * whose `selected` flipped instead of rebuilding every row's SVG — the row
 * data is already stable across selection changes (`graph` is memoized on the
 * commits), so without this each key-repeat of a held arrow re-rendered the
 * whole list.
 */
function CommitRowImpl({
  row,
  laneCount,
  selected,
  id,
  onSelect
}: {
  row: GraphRow
  laneCount: number
  selected: boolean
  id: string
  onSelect: (hash: string) => void
}) {
  return (
    // biome-ignore lint/a11y/useKeyWithClickEvents: the keyboard equivalent is the list's own onKeyDown, which is the whole point of the activedescendant pattern — a per-row handler could only fire for a row that had focus, and no row ever does
    <div
      id={id}
      className={selected ? 'git-tree-row git-tree-row-selected' : 'git-tree-row'}
      data-testid="git-tree-row"
      data-hash={row.commit.hash}
      role="option"
      aria-selected={selected}
      // Out of the tab sequence but programmatically focusable, which is what
      // an option in an activedescendant listbox should be — the container is
      // the tab stop, not the row.
      tabIndex={-1}
      onClick={() => onSelect(row.commit.hash)}
    >
      <GitGraph row={row} laneCount={laneCount} selected={selected} />
      <span className="git-tree-hash">{shortHash(row.commit.hash)}</span>
      <span className="git-tree-subject">
        {row.commit.refs.map((ref) => (
          <span key={ref} className="git-tree-ref" data-testid="git-tree-ref">
            {ref}
          </span>
        ))}
        {row.commit.subject}
      </span>
      <span className="git-tree-author">{row.commit.author}</span>
      <span className="git-tree-date">{formatDate(row.commit.date)}</span>
    </div>
  )
}

const CommitRow = memo(CommitRowImpl)

export function GitTreeRenderer({ node }: ContentRendererProps<LeafContent>) {
  const configuredDir = node.config.cwd as string | undefined
  // Stable for the window's lifetime (the context is built once at
  // activation), so these are safe in effect dependency lists.
  const { setLeafConfig, setLiveTitle } = gitTreeCtx.get().layout

  const listRef = useRef<HTMLDivElement>(null)
  const pathInputRef = useRef<HTMLInputElement>(null)

  // Element ids have to be unique across the whole document, and several git
  // tree panes can be open at once — so a row's id is scoped by its pane's.
  const rowId = (hash: string): string => `git-row-${node.id}-${hash}`

  const [log, setLog] = useState<GitLogResult | undefined>(undefined)
  const [selectedHash, setSelectedHash] = useState<string | null>(null)
  const [detail, setDetail] = useState<CommitDetail | undefined>(undefined)
  const [pathValue, setPathValue] = useState(configuredDir ?? '')

  /**
   * Whether anything has chosen a directory for this pane yet.
   *
   * A ref rather than state because its only job is to be readable from inside
   * an in-flight promise — see the default-directory effect below, which must
   * not overwrite a choice made while it was waiting.
   */
  const directoryChosen = useRef(configuredDir !== undefined)

  // Keep the path bar showing the pane's actual directory when that changes
  // from anywhere but this input — the browse button, or a restored layout
  // arriving after first paint.
  //
  // Never while the caret is *in* the path bar, though. A pane opens with no
  // directory and adopts one asynchronously, so without this guard a user who
  // opens a git tree and immediately types a path has their half-typed input
  // replaced by the default the moment it arrives — and the value they then
  // submit is the one that was pushed at them. Found by an e2e test doing
  // exactly that, faster than a person could.
  useEffect(() => {
    if (document.activeElement === pathInputRef.current) return
    setPathValue(configuredDir ?? '')
  }, [configuredDir])

  /**
   * A pane created with no directory adopts one.
   *
   * This is the fallback for when creation inherited nothing — a pane whose
   * origin had a directory to offer arrives with `cwd` already set by
   * `deriveConfig` (see gitTreeContentDef.ts) and never reaches this. Main
   * answers with the app's own working directory when that is a repository
   * and the home directory otherwise, and either way the answer is written
   * into config so the pane stops being directory-less — including across a
   * restart.
   */
  useEffect(() => {
    if (configuredDir !== undefined) return
    let cancelled = false
    void gitTreeBridge.defaultDirectory().then((dir) => {
      // Two guards, and both are needed. `cancelled` covers the pane
      // unmounting or its directory arriving from elsewhere before this
      // resolved; `directoryChosen` covers the narrower window where a choice
      // was made *during* the round trip but React has not re-run this effect
      // yet. A default silently overwriting a directory the user picked is the
      // worst outcome available here, so it is checked twice rather than
      // relying on render timing.
      if (cancelled || directoryChosen.current) return
      directoryChosen.current = true
      setLeafConfig(node.id, { cwd: dir })
    })
    return () => {
      cancelled = true
    }
  }, [configuredDir, node.id, setLeafConfig])

  // Fetch generation counter: every first-page read (initial load, a
  // directory change, or an explicit refresh) claims a generation, and only
  // the read that is still current when it resolves is allowed to commit —
  // the same guard a per-effect `cancelled` flag gave the initial load alone,
  // now shared with `refresh` below so the two can't race each other either.
  const fetchGeneration = useRef(0)
  /** Whether the current generation's first-page read is still outstanding — see refreshIfAttended. */
  const fetchPending = useRef(false)

  const loadLog = useCallback((dir: string, options?: { showLoading?: boolean }) => {
    const generation = ++fetchGeneration.current
    fetchPending.current = true
    if (options?.showLoading) setLog(undefined)
    void gitTreeBridge.log(dir, PAGE_SIZE, 0).then((result) => {
      if (fetchGeneration.current !== generation) return
      fetchPending.current = false
      setLog(result)
    })
  }, [])

  // The log's first page. Later pages arrive through `loadMore` below, which
  // appends instead of re-reading from zero — git re-walking, re-shipping and
  // React re-mounting every already-loaded commit made paging quadratic in
  // what the list holds, and blanked the list to "Reading history…" each time.
  useEffect(() => {
    if (configuredDir === undefined) return
    loadLog(configuredDir, { showLoading: true })
  }, [configuredDir, loadLog])

  /**
   * Re-reads the current directory's first page in place — deliberately no
   * "Reading history…" flash, since there is already something on screen
   * worth keeping visible while a fresher read is in flight. What the
   * Cmd/Ctrl+R shortcut (see the `extension.refresh` below) and
   * auto-refresh-on-focus both call.
   */
  const refresh = useCallback(() => {
    if (configuredDir !== undefined) loadLog(configuredDir)
  }, [configuredDir, loadLog])

  // Held in a ref so the handle registration below can depend on `node.id`
  // alone. Re-registering re-runs `registerPaneHandle`, which calls `focus()`
  // on an already-active pane — so a `refresh` in the deps (it changes identity
  // with the directory) made every mount and directory change read the first
  // page twice, the second read discarded by the generation counter. This is
  // the shape PaneHandle asks for: every member a getter or a closure over
  // refs.
  const refreshRef = useRef(refresh)
  refreshRef.current = refresh

  const loadMore = (): void => {
    if (configuredDir === undefined || !log?.ok) return
    void gitTreeBridge.log(configuredDir, PAGE_SIZE, log.commits.length).then((result) => {
      setLog((current) => {
        // Append only onto the exact list the click saw. A directory change
        // (or any fresh first-page read) replaces `log` while this page is in
        // flight, and these rows belong to the list that no longer exists.
        if (current !== log) return current
        if (!result.ok) return result
        return {
          ...current,
          commits: [...current.commits, ...result.commits],
          hasMore: result.hasMore
        }
      })
    })
  }

  const commits = useMemo<Commit[]>(() => (log?.ok ? log.commits : []), [log])
  const graph = useMemo(() => assignLanes(commits), [commits])

  // Selection follows the list: keep it where it was if that commit is still
  // present (a Load more, a re-read of the same repo), otherwise fall to the
  // newest commit so the detail panel is never empty beside a populated list.
  useEffect(() => {
    if (commits.length === 0) {
      setSelectedHash(null)
      return
    }
    setSelectedHash((current) =>
      current && commits.some((commit) => commit.hash === current) ? current : commits[0]!.hash
    )
  }, [commits])

  useEffect(() => {
    if (configuredDir === undefined || selectedHash === null) {
      setDetail(undefined)
      return
    }
    let cancelled = false
    setDetail(undefined)
    // Debounced: a held arrow key traverses many rows a second, and each read
    // is two git spawns in main that run to completion even once stale. Only
    // the row the selection settles on is worth asking about.
    const timer = setTimeout(() => {
      void gitTreeBridge.commit(configuredDir, selectedHash).then((result) => {
        if (!cancelled) setDetail(result.ok ? result.detail : undefined)
      })
    }, 100)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [configuredDir, selectedHash])

  // The pane's tab reads as the repository rather than "Git tree", the way a
  // browser pane's reads as its page title.
  useEffect(() => {
    if (log?.ok) setLiveTitle(node.id, baseName(log.root))
  }, [log, node.id, setLiveTitle])

  // Tracks whether this pane is the active one, purely from the focus/blur
  // signals core already sends it (see PaneFocusFollower) — the pane-window
  // plugin API exposes no direct "which pane is active" read, and this is the
  // signal it hands out instead. auto-refresh-on-focus below needs this for
  // the case where the OS window itself regains focus without any pane
  // activation happening alongside it.
  const isActiveRef = useRef(false)

  // Auto-refresh's one gate, in one place: the pane is the attended one (active
  // here *and* the window focused — the same two-part test bellStore.ring
  // applies) and the setting is on. Both callers below decide *when* to ask;
  // neither restates what qualifies.
  const refreshIfAttended = useCallback((windowFocused: boolean) => {
    // A read already in flight is as fresh as a new one, and this fires
    // exactly when one usually is: a pane that mounts already-active gets its
    // focus() from registerPaneHandle in the same commit that starts the first
    // page. Without this, opening the pane read the log twice and threw the
    // first answer away. Cmd/Ctrl+R goes to `refresh` directly and is never
    // suppressed — an explicit ask always re-reads.
    if (fetchPending.current) return
    if (windowFocused && isActiveRef.current && getGitTreeSettings().autoRefreshOnFocus) {
      refreshRef.current()
    }
  }, [])

  // The window's own focus event *is* the evidence that the window is focused,
  // so it says so rather than asking `document.hasFocus()` — which lags the
  // event under Playwright's focus emulation and is plainly false in jsdom.
  const onWindowFocus = useCallback(() => refreshIfAttended(true), [refreshIfAttended])

  useEffect(
    () =>
      gitTreeCtx.get().panes.registerHandle(node.id, {
        focus: () => {
          isActiveRef.current = true
          // A click on this pane's own path bar activates the pane too — the
          // list must not yank focus off the input the user just chose, and
          // nor should the pane re-read under them.
          if (document.activeElement === pathInputRef.current) return
          listRef.current?.focus()
          refreshIfAttended(document.hasFocus())
        },
        blur: () => {
          isActiveRef.current = false
          if (document.activeElement === listRef.current) listRef.current?.blur()
        },
        // Refresh is a core capability any content type may claim by
        // exposing it here (see getPaneCapability in
        // core/registry/paneHandles.ts) — what Cmd/Ctrl+R dispatches to.
        extension: { refresh: () => refreshRef.current() }
      }),
    [node.id, refreshIfAttended]
  )

  // The other half of "attended": the window regaining OS focus while this
  // pane is *already* the active one. The focus() callback above only fires on
  // activation, not on a window refocus that leaves the active pane
  // unchanged, so that case needs its own listener — one per mounted instance
  // rather than bellStore's module-scope one, since a refresh has to reach
  // this pane's own directory.
  useEffect(() => {
    window.addEventListener('focus', onWindowFocus)
    return () => window.removeEventListener('focus', onWindowFocus)
  }, [onWindowFocus])

  // Stable across renders so it never breaks CommitRow's memoization.
  const selectRow = useCallback((hash: string) => setSelectedHash(hash), [])

  const moveSelection = (delta: number): void => {
    if (commits.length === 0) return
    const index = commits.findIndex((commit) => commit.hash === selectedHash)
    const next = Math.min(Math.max((index === -1 ? 0 : index) + delta, 0), commits.length - 1)
    const target = commits[next]!
    setSelectedHash(target.hash)
    // Keep the moved-to row on screen. `nearest` rather than `center` so a
    // held arrow key scrolls by a row instead of jumping the viewport around
    // a selection that was already visible.
    listRef.current
      ?.querySelector(`[data-hash="${target.hash}"]`)
      ?.scrollIntoView({ block: 'nearest' })
  }

  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>): void => {
    // Matched on `key`, not `code`: these are cursor-motion keys with the same
    // meaning on every layout, unlike the app's rebindable shortcuts (see
    // shared/shortcuts.ts, which is why those are matched by physical key).
    switch (event.key) {
      case 'ArrowDown':
        moveSelection(1)
        break
      case 'ArrowUp':
        moveSelection(-1)
        break
      case 'Home':
        moveSelection(-commits.length)
        break
      case 'End':
        moveSelection(commits.length)
        break
      default:
        return
    }
    // Only reached for a key handled above, so an unhandled one still bubbles
    // to the pane's own navigation.
    event.preventDefault()
  }

  const chooseDirectory = (dir: string): void => {
    directoryChosen.current = true
    setLeafConfig(node.id, { cwd: dir })
  }

  const applyPath = (): void => {
    const next = pathValue.trim()
    if (next.length === 0 || next === configuredDir) return
    chooseDirectory(next)
  }

  const browse = async (): Promise<void> => {
    const chosen = await gitTreeBridge.chooseDirectory(configuredDir)
    // Undefined is "cancelled" — and is what the handler always answers under
    // E2E_HIDDEN, where a native picker would hang the run.
    if (chosen === undefined) return
    chooseDirectory(chosen)
  }

  return (
    <div className="git-tree-container" data-testid="git-tree" style={LANE_VARS}>
      <div className="git-tree-toolbar">
        <input
          ref={pathInputRef}
          className="git-tree-path-input"
          data-testid="git-tree-path-input"
          aria-label="Repository directory"
          spellCheck={false}
          value={pathValue}
          onChange={(event) => setPathValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') applyPath()
            if (event.key === 'Escape') setPathValue(configuredDir ?? '')
            // The list's own handler is on an ancestor, so an arrow press
            // inside the input would move the selection as well as the caret.
            event.stopPropagation()
          }}
          onBlur={applyPath}
        />
        <button
          type="button"
          className="git-tree-browse-button"
          data-testid="git-tree-browse-button"
          aria-label="Choose a repository"
          title="Choose a repository"
          onClick={() => void browse()}
        >
          <FolderIcon />
        </button>
        {log?.ok && (
          <span className="git-tree-head" data-testid="git-tree-head">
            {headLabel(log.head)}
          </span>
        )}
      </div>

      {log === undefined ? (
        <div className="git-tree-notice" data-testid="git-tree-loading">
          Reading history…
        </div>
      ) : log.ok ? (
        <div className="git-tree-body">
          <div
            ref={listRef}
            className="git-tree-list"
            data-testid="git-tree-list"
            role="listbox"
            aria-label="Commits"
            tabIndex={0}
            // The activedescendant pattern: the list itself keeps DOM focus
            // (so one keydown handler serves every row, and the pane handle
            // has a single thing to focus) while this names which row is
            // current for assistive technology.
            aria-activedescendant={selectedHash ? rowId(selectedHash) : undefined}
            style={{ '--git-row-height': `${ROW_HEIGHT}px` } as React.CSSProperties}
            onKeyDown={onKeyDown}
          >
            {graph.rows.map((row) => (
              <CommitRow
                key={row.commit.hash}
                row={row}
                laneCount={graph.laneCount}
                selected={row.commit.hash === selectedHash}
                id={rowId(row.commit.hash)}
                onSelect={selectRow}
              />
            ))}
            {log.hasMore && (
              <button
                type="button"
                className="git-tree-load-more"
                data-testid="git-tree-load-more"
                onClick={loadMore}
              >
                Load more
              </button>
            )}
          </div>

          <div className="git-tree-detail" data-testid="git-tree-detail">
            {detail ? (
              <>
                <pre className="git-tree-message" data-testid="git-tree-message">
                  {detail.message}
                </pre>
                <dl className="git-tree-fields">
                  <dt>Commit</dt>
                  <dd data-testid="git-tree-detail-hash">{detail.hash}</dd>
                  <dt>Author</dt>
                  <dd>{`${detail.author} <${detail.authorEmail}>`}</dd>
                  <dt>Date</dt>
                  {/* The same formatter the rows use. Showing the raw `%aI`
                      here instead reads as a bug rather than as precision:
                      the same commit displays two different-looking times,
                      one local and one in the author's offset. */}
                  <dd>{formatDate(detail.date)}</dd>
                  {detail.parents.length > 0 && (
                    <>
                      <dt>{detail.parents.length > 1 ? 'Parents' : 'Parent'}</dt>
                      <dd>{detail.parents.map(shortHash).join(', ')}</dd>
                    </>
                  )}
                  {detail.refs.length > 0 && (
                    <>
                      <dt>Refs</dt>
                      <dd>{detail.refs.join(', ')}</dd>
                    </>
                  )}
                </dl>
                <div className="git-tree-files" data-testid="git-tree-files">
                  {detail.files.map((file) => (
                    <div key={file.path} className="git-tree-file" data-testid="git-tree-file">
                      <span className="git-tree-file-stat">
                        {file.insertions === null || file.deletions === null ? (
                          <span className="git-tree-binary">binary</span>
                        ) : (
                          <>
                            <span className="git-tree-insertions">+{file.insertions}</span>
                            <span className="git-tree-deletions">−{file.deletions}</span>
                          </>
                        )}
                      </span>
                      <span className="git-tree-file-path">{file.path}</span>
                    </div>
                  ))}
                  {detail.files.length === 0 && (
                    <p className="git-tree-dim">No files changed against the first parent.</p>
                  )}
                  {detail.filesTruncated && (
                    <p className="git-tree-dim">Only the first files are listed.</p>
                  )}
                </div>
              </>
            ) : (
              <p className="git-tree-dim">Select a commit.</p>
            )}
          </div>
        </div>
      ) : (
        <div className="git-tree-notice" data-testid="git-tree-empty">
          <p>{failureMessage(log.reason)}</p>
          <p className="git-tree-dim">
            Type a directory above, or use the folder button to choose one.
          </p>
        </div>
      )}
    </div>
  )
}
