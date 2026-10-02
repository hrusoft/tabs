import './gitTree.css'
import { type ContentRendererProps, focusIsInPaneChrome } from '@tabs/plugin-sdk/renderer/api'
import type { LeafContent } from '@tabs/plugin-sdk/shared/model/types'
import { collectLeaves } from '@tabs/plugin-sdk/shared/model/types'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { type CheckoutTarget, checkoutTargetLabel, decideCheckout } from '../shared/checkoutTargets'
import { assignLanes } from '../shared/graph'
import { GIT_TREE_TYPE } from '../shared/manifest'
import type {
  Commit,
  CommitDetail,
  GitBranchScope,
  GitFailure,
  GitLogResult
} from '../shared/types'
import { UNCOMMITTED_CHANGES_HASH } from '../shared/types'
import { CommitDetailPanel } from './CommitDetailPanel'
import { CommitRow } from './CommitRow'
import { DetailDivider } from './DetailDivider'
import { type DetailSplit, readDetailSplit } from './detailSplit'
import { shortHash } from './format'
import { LANE_COLORS, ROW_HEIGHT } from './GitGraph'
import { gitTreeBridge } from './gitTreeBridge'
import { gitTreeHeads } from './gitTreeRegistry'
import { getGitTreeSettings, useGitTreeSetting } from './gitTreeSettingsAccess'
import { gitTreeCtx } from './pluginContext'

/**
 * A repository's commit graph: a scrollable list of commits drawn with a lane
 * gutter (CommitRow), and a detail panel for whichever commit is selected
 * (CommitDetailPanel), sized — or collapsed — by the divider between them
 * (DetailDivider). The path bar, browse button, HEAD label and
 * branch-scope select live in the pane header — see `GitTreeHeaderTitle`,
 * this type's `ContentRendererDef.HeaderTitle`.
 *
 * `node.config.cwd` is the directory the pane is looking at, and it is the
 * pane's whole subject — written back through `setLeafConfig` (from the
 * header) on every change, which is what makes a restored layout reopen the
 * same repository (the same pattern BrowserRenderer uses for `config.url`).
 *
 * All git work happens in main and arrives as data (see
 * packages/plugin-gitTree/main/git.ts); nothing here can throw from a failed
 * `git`, because nothing there rejects. Every `GitFailure` kind is rendered
 * as a sentence in place of the list, so every one of them is a state you can
 * act on (via the header's path bar or browse button) rather than a dead end.
 */

/** Commits per page. Big enough that most repositories need no second read, small enough to stay instant on a huge one. */
const PAGE_SIZE = 500

/** The gutter palette as CSS custom properties, computed once — gitTree.css consumes these, GitGraph.tsx owns them. */
const LANE_VARS = Object.fromEntries(
  LANE_COLORS.map((color, index) => [`--git-lane-${index}`, color])
) as React.CSSProperties

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

/**
 * "abc1234 — the subject line", for naming the commit a checkout dialog is
 * about. Module scope and takes `commits` explicitly rather than closing
 * over component state, so `handleCheckout` below can call it
 * through a stable ref (`commitsRef`) without giving its own `useCallback` a
 * dependency that changes identity on every log refresh.
 */
function commitLabel(commits: Commit[], hash: string): string {
  const subject = commits.find((commit) => commit.hash === hash)?.subject
  return subject ? `${shortHash(hash)} — ${subject}` : shortHash(hash)
}

/**
 * Reports a checkout failure through the one-button alert dialog — module
 * scope since it closes over nothing but the stable `gitTreeCtx` holder (see
 * core/dialogs.tsx's own comment on why `alert` is a distinct shape from
 * `confirm` rather than the latter with its Cancel button hidden).
 */
async function reportCheckoutFailure(message: string): Promise<void> {
  await gitTreeCtx.get().dialogs.alert({
    title: 'Checkout failed',
    message,
    testId: 'git-tree-checkout-failed-dialog'
  })
}

/**
 * A row's element id. Element ids have to be unique across the whole
 * document, and several git tree panes can be open at once — so a row's id is
 * scoped by its pane's.
 */
function rowId(paneId: string, hash: string): string {
  return `git-row-${paneId}-${hash}`
}

export function GitTreeRenderer({ node }: ContentRendererProps<LeafContent>) {
  const configuredDir = node.config.cwd as string | undefined
  // Stable for the window's lifetime (the context is built once at
  // activation), so this is safe in effect dependency lists.
  const { setLiveTitle } = gitTreeCtx.get().layout

  const listRef = useRef<HTMLDivElement>(null)

  const [log, setLog] = useState<GitLogResult | undefined>(undefined)
  const [selectedHash, setSelectedHash] = useState<string | null>(null)
  const [detail, setDetail] = useState<CommitDetail | undefined>(undefined)
  // The pane's branch filter — read straight from config rather than mirrored
  // into local state: nothing external ever rewrites `config.branchScope`
  // behind this pane's back (it only ever changes through GitTreeHeaderTitle's
  // own select, via setLeafConfig), and both this component and that one
  // re-render from the same store subscription whenever it does, so there is
  // nothing a second, local copy would buy here — unlike `cwd`, which the
  // path bar needs a guarded sync effect for (see GitTreeHeaderTitle.tsx).
  const branchScope = (node.config.branchScope as GitBranchScope | undefined) ?? 'all'
  const showAuthor = useGitTreeSetting((settings) => settings.showAuthorColumn)
  const showDate = useGitTreeSetting((settings) => settings.showDateColumn)

  // How the body divides between list and details: saved in config (read
  // straight from it, like `branchScope`), overridden by a local draft only
  // while the divider is being dragged — a drag previews every frame, but
  // only its release is worth a layout save.
  const savedSplit = readDetailSplit(node.config)
  const [draftSplit, setDraftSplit] = useState<DetailSplit | null>(null)
  const split = draftSplit ?? savedSplit
  const detailCollapsed = split.collapsed

  // Fetch generation counter: every first-page read (initial load, a
  // directory change, or an explicit refresh) claims a generation, and only
  // the read that is still current when it resolves is allowed to commit —
  // the same guard a per-effect `cancelled` flag gave the initial load alone,
  // now shared with `refresh` below so the two can't race each other either.
  const fetchGeneration = useRef(0)
  /** Whether the current generation's first-page read is still outstanding — see refreshIfAttended. */
  const fetchPending = useRef(false)

  const loadLog = useCallback(
    (dir: string, scope: GitBranchScope, options?: { showLoading?: boolean }) => {
      const generation = ++fetchGeneration.current
      fetchPending.current = true
      if (options?.showLoading) setLog(undefined)
      const settle = (result: GitLogResult): void => {
        if (fetchGeneration.current !== generation) return
        fetchPending.current = false
        setLog(result)
      }
      // Never rejects (see gitTreeBridge) — an unsettled read would leave
      // `fetchPending` set for good, silently switching auto-refresh off
      // (see refreshIfAttended).
      void gitTreeBridge.log(dir, PAGE_SIZE, 0, scope).then(settle)
    },
    []
  )

  // The log's first page. Later pages arrive through `loadMore` below, which
  // appends instead of re-reading from zero — git re-walking, re-shipping and
  // React re-mounting every already-loaded commit made paging quadratic in
  // what the list holds, and blanked the list to "Reading history…" each time.
  // A branch-scope change re-fetches page 0 the same way a directory change
  // does, since it changes which commits are even in scope for paging.
  useEffect(() => {
    if (configuredDir === undefined) return
    loadLog(configuredDir, branchScope, { showLoading: true })
  }, [configuredDir, branchScope, loadLog])

  /**
   * Re-reads the current directory's first page in place — deliberately no
   * "Reading history…" flash, since there is already something on screen
   * worth keeping visible while a fresher read is in flight. What the
   * Cmd/Ctrl+R shortcut (see the `extension.refresh` below) and
   * auto-refresh-on-focus both call.
   */
  const refresh = useCallback(() => {
    if (configuredDir !== undefined) loadLog(configuredDir, branchScope)
  }, [configuredDir, branchScope, loadLog])

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
    void gitTreeBridge
      .log(configuredDir, PAGE_SIZE, log.commits.length, branchScope)
      .then((result) => {
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

  // The working tree's own uncommitted state, folded straight into the commit
  // list as a synthetic `Commit` — its one parent is the newest real commit,
  // so `assignLanes` connects it into the graph exactly as it would a real
  // child/parent edge, and every mechanism below that already operates on
  // `Commit[]` (selection, keyboard nav, the detail fetch) handles it with no
  // special-casing of its own. See `CommitRowImpl` for how it renders and
  // `UNCOMMITTED_CHANGES_HASH` for why an empty hash is a safe sentinel.
  const commits = useMemo<Commit[]>(() => {
    const real = log?.ok ? log.commits : []
    if (!log?.ok || !log.hasUncommittedChanges) return real
    const workingTree: Commit = {
      hash: UNCOMMITTED_CHANGES_HASH,
      parents: real[0] ? [real[0].hash] : [],
      author: '',
      date: '',
      refs: [],
      subject: 'Uncommitted changes'
    }
    return [workingTree, ...real]
  }, [log])
  const graph = useMemo(() => assignLanes(commits), [commits])

  // Selection follows the list: keep it where it was if that commit is still
  // present (a Load more, a re-read of the same repo), otherwise fall to the
  // newest *real* commit so the detail panel is never empty beside a
  // populated list — a repo simply being dirty shouldn't reroute the default
  // selection away from actual history, only make the working-tree row
  // reachable (it's commits[0] when present, so Home/ArrowUp still reach it).
  useEffect(() => {
    if (commits.length === 0) {
      setSelectedHash(null)
      return
    }
    setSelectedHash((current) => {
      // `!== null`, not truthiness: the working-tree row's hash is the empty string.
      if (current !== null && commits.some((commit) => commit.hash === current)) return current
      const firstReal = commits.find((commit) => commit.hash !== UNCOMMITTED_CHANGES_HASH)
      return (firstReal ?? commits[0]!).hash
    })
  }, [commits])

  // A refresh re-reads the log but leaves the working-tree row's hash (always
  // empty) where it was, so that row — the one whose detail actually changes
  // between reads — is keyed on the log itself as well.
  const detailKey = selectedHash === UNCOMMITTED_CHANGES_HASH ? log : selectedHash

  useEffect(() => {
    // Collapsed, nothing shows the detail, so nothing reads it — a held arrow
    // key through a hidden panel costs no git spawns. Kept rather than
    // cleared, so reopening on the same row doesn't flash it empty while this
    // re-runs and re-reads.
    if (detailCollapsed) return
    if (configuredDir === undefined || selectedHash === null || detailKey === undefined) {
      setDetail(undefined)
      return
    }
    let cancelled = false
    // Kept while the same row is re-read, so a refresh doesn't flash it empty.
    setDetail((current) => (current?.hash === selectedHash ? current : undefined))
    // Debounced: a held arrow key traverses many rows a second, and each read
    // is two git spawns in main that run to completion even once stale. Only
    // the row the selection settles on is worth asking about.
    const timer = setTimeout(() => {
      const request =
        selectedHash === UNCOMMITTED_CHANGES_HASH
          ? gitTreeBridge.workingTree(configuredDir)
          : gitTreeBridge.commit(configuredDir, selectedHash)
      void request.then((result) => {
        if (!cancelled) setDetail(result.ok ? result.detail : undefined)
      })
    }, 100)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [configuredDir, selectedHash, detailKey, detailCollapsed])

  // The pane's tab reads as the repository rather than "Git tree", the way a
  // browser pane's reads as its page title — or, when the directory isn't one,
  // as that directory, rather than keeping the name of a repo no longer shown.
  useEffect(() => {
    if (log === undefined) return
    if (log.ok) setLiveTitle(node.id, baseName(log.root))
    else if (configuredDir !== undefined) setLiveTitle(node.id, baseName(configuredDir))
  }, [log, configuredDir, node.id, setLiveTitle])

  // Publishes this pane's HEAD for GitTreeHeaderTitle's own label — the one
  // piece of this component's state the header needs and cannot derive from
  // `leaf.config`/`gitTreeBridge` on its own (see gitTreeRegistry.ts).
  useEffect(() => {
    if (log?.ok) gitTreeHeads.set(node.id, log.head)
    else gitTreeHeads.delete(node.id)
    return () => gitTreeHeads.delete(node.id)
  }, [log, node.id])

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
          // A click on this pane's own header chrome (the path bar, the
          // browse button, the branch-scope select) activates the pane too —
          // the list must not yank focus off whatever the user just chose
          // there, and nor should the pane re-read under them.
          if (focusIsInPaneChrome(node.id)) return
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

  /**
   * The divider's release. Clears the draft and saves in one batch, so the
   * release frame shows the saved split rather than flicking back through
   * the old one — and saves nothing at all for a press that moved nothing,
   * which would otherwise be a layout write per stray click. A collapse keeps
   * the saved fraction, the last open size.
   */
  const commitSplit = (next: DetailSplit): void => {
    setDraftSplit(null)
    const unchanged = next.collapsed
      ? savedSplit.collapsed
      : !savedSplit.collapsed && next.fraction === savedSplit.fraction
    if (unchanged) return
    gitTreeCtx
      .get()
      .layout.setLeafConfig(
        node.id,
        next.collapsed
          ? { detailCollapsed: true }
          : { detailFraction: next.fraction, detailCollapsed: false }
      )
  }

  // Stable across renders so it never breaks CommitRow's memoization.
  const selectRow = useCallback((hash: string) => setSelectedHash(hash), [])

  // Checking out a commit or branch from the list.
  //
  // One checkout at a time per pane: the fresh `branchesAtCommit` read, the
  // dialog round trip and the checkout itself are all async, so a second
  // trigger landing while one is already running (a stray double-click on
  // top of a context-menu pick, say) would start a second `git switch`
  // racing the first over git's own `index.lock` rather than queue behind
  // it — dropped outright instead, via this ref rather than state, since
  // nothing about being "in flight" should cause a re-render.
  const checkoutInFlightRef = useRef(false)

  // A stable ref onto the latest commits, purely so handleCheckout can look a
  // hash's subject up (module-scope commitLabel above) without *depending*
  // on `commits` — depending on it would give handleCheckout/openCommitMenu
  // a new identity on every refresh and defeat CommitRow's memoization
  // exactly the way refreshRef above exists to avoid for `refresh` itself.
  const commitsRef = useRef(commits)
  commitsRef.current = commits

  /**
   * Refreshes this pane, plus every *other* mounted git tree pane pointed at
   * the exact same directory — an exact string match on `config.cwd` only,
   * not "same repo, different subdirectory" (that would need its own
   * `git rev-parse --show-toplevel` per candidate pane on every checkout, for
   * a setup few users have). Uses only capabilities already on the plugin
   * context (`layout.allRoots` + `panes.getCapability('refresh')`) — no new
   * core plumbing for this.
   */
  const refreshAfterCheckout = useCallback(
    (dir: string) => {
      refreshRef.current()
      const ctx = gitTreeCtx.get()
      for (const root of ctx.layout.allRoots()) {
        for (const leaf of collectLeaves(root)) {
          if (leaf.id === node.id) continue
          if (leaf.type !== GIT_TREE_TYPE) continue
          if ((leaf.config.cwd as string | undefined) !== dir) continue
          ctx.panes.getCapability(leaf.id, 'refresh')?.()
        }
      }
    },
    [node.id]
  )

  const performCheckout = useCallback(
    async (dir: string, target: CheckoutTarget) => {
      const result = await gitTreeBridge.checkout(dir, target)
      // `detail` is git's own full refusal text when there is one (a dirty
      // file list, the "commit or stash" hint) — falling back to the
      // one-line `reason` only for the rarer failures that never carry it
      // (git missing, not a repo). Never silent either way.
      if (!result.ok) await reportCheckoutFailure(result.detail ?? failureMessage(result.reason))
      refreshAfterCheckout(dir)
    },
    [refreshAfterCheckout]
  )

  const handleCheckout = useCallback(
    async (hash: string) => {
      if (hash === UNCOMMITTED_CHANGES_HASH) return
      if (configuredDir === undefined) return
      if (checkoutInFlightRef.current) return
      checkoutInFlightRef.current = true
      try {
        const dir = configuredDir
        // Fresh, unambiguous, and never the log's own `%D` decorations — see
        // git.ts's branchesAtCommit for why.
        const refs = await gitTreeBridge.branchesAtCommit(dir, hash)
        if (!refs.ok) {
          await reportCheckoutFailure(failureMessage(refs.reason))
          return
        }
        const decision = decideCheckout(refs.local, refs.remotes, refs.allLocalBranches)
        if (decision.kind === 'single') {
          await performCheckout(dir, decision.target)
          return
        }
        if (decision.kind === 'none') {
          const confirmed = await gitTreeCtx.get().dialogs.confirm({
            title: 'Checkout',
            message: `Checking out ${commitLabel(commitsRef.current, hash)} will leave HEAD detached — it won't be on any branch. Continue?`,
            confirmLabel: 'Checkout',
            testId: 'git-tree-checkout-detach-dialog'
          })
          if (!confirmed) return
          await performCheckout(dir, { kind: 'commit', hash })
          return
        }
        // decision.kind === 'choose'. Labels double as the select's values —
        // decideCheckout never mixes local and remote-tracking targets in one
        // list, and names are unique within either namespace, so this is
        // never ambiguous. Order is whatever branchesAtCommit's own
        // `--sort=refname` produced (deterministic, not "current branch
        // first" or any other UI-side reordering).
        const labels = decision.targets.map(checkoutTargetLabel)
        const picked = await gitTreeCtx.get().dialogs.choose({
          title: 'Checkout',
          message: `Several branches point at ${commitLabel(commitsRef.current, hash)}. Which one?`,
          options: labels,
          confirmLabel: 'Checkout',
          testId: 'git-tree-checkout-choose-dialog'
        })
        if (picked === null) return
        const target = decision.targets[labels.indexOf(picked)]
        if (target === undefined) return
        await performCheckout(dir, target)
      } catch (error) {
        // The bridge's calls never reject (see gitTreeBridge), but this
        // flow also awaits dialogs and runs its own logic between them. A
        // checkout must not fail silently, so this is the backstop: the
        // stack goes to the console, the user gets the alert every other
        // failure in this flow already uses.
        console.error('git tree checkout failed', error)
        await reportCheckoutFailure(error instanceof Error ? error.message : String(error))
      } finally {
        checkoutInFlightRef.current = false
      }
    },
    [configuredDir, performCheckout]
  )

  // Every item acts on the `hash` the row passed in — the row right-clicked —
  // never on `selectedHash`, even though the right-click also selects it.
  const openCommitMenu = useCallback(
    (hash: string, x: number, y: number) => {
      const ctx = gitTreeCtx.get()
      ctx.contextMenu.open(x, y, [
        { label: 'Checkout', onSelect: () => void handleCheckout(hash) },
        { label: 'Copy SHA-1', onSelect: () => ctx.copyText(hash) }
      ])
    },
    [handleCheckout]
  )

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

  // Built apart from the rest of the render: a divider drag re-renders this
  // component on every frame it moves, and rebuilding an element per loaded
  // commit for a change that only moves the split was most of that frame.
  const rowElements = useMemo(
    () =>
      graph.rows.map((row) => (
        <CommitRow
          key={row.commit.hash}
          row={row}
          laneCount={graph.laneCount}
          selected={row.commit.hash === selectedHash}
          id={rowId(node.id, row.commit.hash)}
          showAuthor={showAuthor}
          showDate={showDate}
          onSelect={selectRow}
          onCheckout={handleCheckout}
          onCommitMenu={openCommitMenu}
        />
      )),
    [graph, selectedHash, node.id, showAuthor, showDate, selectRow, handleCheckout, openCommitMenu]
  )

  return (
    <div className="git-tree-container" data-testid="git-tree" style={LANE_VARS}>
      {log === undefined ? (
        <div className="git-tree-notice" data-testid="git-tree-loading">
          Reading history…
        </div>
      ) : log.ok ? (
        <div
          className="git-tree-body"
          style={{ '--git-detail-basis': `${split.fraction * 100}%` } as React.CSSProperties}
        >
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
            aria-activedescendant={selectedHash ? rowId(node.id, selectedHash) : undefined}
            style={{ '--git-row-height': `${ROW_HEIGHT}px` } as React.CSSProperties}
            onKeyDown={onKeyDown}
          >
            {rowElements}
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

          <DetailDivider split={split} onPreview={setDraftSplit} onCommit={commitSplit} />
          {!detailCollapsed && <CommitDetailPanel detail={detail} />}
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
