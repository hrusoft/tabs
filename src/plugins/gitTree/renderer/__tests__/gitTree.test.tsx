import { createLeaf, createSplit } from '@shared/model/factories'
import { findNode } from '@shared/model/tree'
import { EMPTY_TYPE, type LeafContent } from '@shared/model/types'
import { act, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from 'vitest'
import { contentRegistry } from '../../../../renderer/src/core/registry/registry'
import { useContextMenuStore } from '../../../../renderer/src/core/store/contextMenuStore'
import { useLayoutStore } from '../../../../renderer/src/core/store/layoutStore'
import { useModalStore } from '../../../../renderer/src/core/store/modalStore'
import { createRendererPluginContext } from '../../../../renderer/src/plugin/context'
import { renderApp } from '../../../../renderer/src/testing/renderApp'
import { GIT_TREE_TYPE } from '../../shared/manifest'
import type { Commit } from '../../shared/types'
import { activate as activateGitTree } from '../index'

/**
 * The git tree pane's behaviour, against a scripted bridge.
 *
 * This tier rather than Electron for everything except the git integration
 * itself: what the rows say, how the selection moves, what the detail panel
 * shows and how each failure reads are all questions about the renderer, and
 * none of them needs a repository on disk. Real `git` against a real repo is
 * e2e/git-tree.spec.ts's job, and only that.
 *
 * The package is activated here rather than in registerTestContent because it
 * is this file's own premise — the other tiers deliberately register stubs,
 * and this renderer is safe to import into jsdom only because it pulls in no
 * xterm and no `<webview>`, which is exactly what makes it the odd one out.
 * The activation is the real one, context and all, same as registerBuiltins
 * performs it.
 *
 * Every test seeds its own log rather than inheriting one: the fake bridge is
 * built once per process (vitest.setup.ts) and its git state is not part of
 * `reset`, so an inherited log would be whatever the previous test left.
 */

beforeAll(() => {
  activateGitTree(createRendererPluginContext(GIT_TREE_TYPE))
})

afterAll(() => {
  contentRegistry.unregister(GIT_TREE_TYPE)
})

function commit(
  hash: string,
  subject: string,
  parents: string[] = [],
  refs: string[] = []
): Commit {
  return { hash, parents, author: 'Ann', date: '2026-01-02T03:04:05Z', refs, subject }
}

// Full-length hashes, named, because the parent lists have to reference the
// *same* strings — a fixture whose parents don't resolve produces four
// unconnected tips and a five-lane gutter, which is the graph being right
// about a history nobody meant to describe.
const MERGE = 'mmmmmmm0000000000000000000000000000000a'
const ON_FEATURE = 'ccccccc0000000000000000000000000000000a'
const ON_MAIN = 'bbbbbbb0000000000000000000000000000000a'
const ROOT = 'aaaaaaa0000000000000000000000000000000a'

/** A small history with a merge, so the graph has something real to lay out. */
const HISTORY: Commit[] = [
  commit(MERGE, 'merge feature', [ON_MAIN, ON_FEATURE], ['HEAD', 'main']),
  commit(ON_FEATURE, 'on feature', [ROOT], ['feature']),
  commit(ON_MAIN, 'on main', [ROOT]),
  commit(ROOT, 'root commit', [])
]

/** Renders a pane already pointed at a directory, with `commits` as its history. Returns the pane's node id. */
async function renderGitTree(commits: Commit[] = HISTORY, cwd = '/repo'): Promise<string> {
  window.__fakeApi?.setGitTreeLog(commits, { root: cwd })
  const leaf = createLeaf(GIT_TREE_TYPE, { cwd })
  renderApp({ root: leaf, settings: { disabledContentTypes: [] } })
  await listReady()
  return leaf.id
}

/**
 * Waits for the list *and* its default selection. The list renders a commit
 * before the selection effect lands, so a test that asserts on the selection
 * right after the list appears races that effect — measured at roughly one
 * failure in eight full parallel runs.
 */
async function listReady(): Promise<void> {
  await screen.findByTestId('git-tree-list')
  await waitFor(() => expect(selectedRow()).toBeDefined())
}

function rows(): HTMLElement[] {
  return screen.getAllByTestId('git-tree-row')
}

function selectedRow(): HTMLElement | undefined {
  return rows().find((row) => row.getAttribute('aria-selected') === 'true')
}

beforeEach(() => {
  window.__fakeApi?.setGitTreeChosenDirectory(undefined)
})

test('renders one row per commit, newest first, with its hash, subject and refs', async () => {
  await renderGitTree()

  expect(rows()).toHaveLength(4)
  expect(rows()[0]).toHaveTextContent('merge feature')
  expect(rows()[3]).toHaveTextContent('root commit')
  // Abbreviated, the way every git UI shows a hash in a list.
  expect(rows()[0]).toHaveTextContent('mmmmmmm')
  expect(rows()[0]).not.toHaveTextContent('mmmmmmm0000')
  // `%D` decorations, already split so HEAD is its own badge rather than an
  // arrow glued to a branch name.
  const refs = within(rows()[0]!).getAllByTestId('git-tree-ref')
  expect(refs.map((ref) => ref.textContent)).toEqual(['HEAD', 'main'])
})

test('draws a gutter as wide as the graph actually needs', async () => {
  await renderGitTree()

  // Two lanes for this history (a merge and its two sides), at 12px each —
  // the one assertion tying the pure lane assignment to what is drawn. The
  // *appearance* of the gutter is not a jsdom question; that it is wired to
  // assignLanes at all is.
  const svg = rows()[0]!.querySelector('svg')
  expect(svg?.getAttribute('width')).toBe('24')

  // A purely linear history needs exactly one.
  await renderGitTree([commit('aaa', 'only commit')])
  expect(rows()[0]!.querySelector('svg')?.getAttribute('width')).toBe('12')
})

test('selects the newest commit so the detail panel is never empty beside a full list', async () => {
  await renderGitTree()

  expect(selectedRow()).toBe(rows()[0])
  expect(await screen.findByTestId('git-tree-message')).toHaveTextContent('merge feature')
})

test('arrow keys move the selection, and stop at both ends', async () => {
  await renderGitTree()
  const user = userEvent.setup()
  await user.click(screen.getByTestId('git-tree-list'))

  await user.keyboard('{ArrowDown}')
  expect(selectedRow()).toBe(rows()[1])
  await user.keyboard('{ArrowDown}{ArrowDown}')
  expect(selectedRow()).toBe(rows()[3])

  // Clamped, not wrapped: holding the key at the oldest commit should sit
  // still rather than jump back to the top.
  await user.keyboard('{ArrowDown}')
  expect(selectedRow()).toBe(rows()[3])

  await user.keyboard('{ArrowUp}{ArrowUp}{ArrowUp}{ArrowUp}')
  expect(selectedRow()).toBe(rows()[0])
})

test('Home and End jump to the ends of the list', async () => {
  await renderGitTree()
  const user = userEvent.setup()
  await user.click(screen.getByTestId('git-tree-list'))

  await user.keyboard('{End}')
  expect(selectedRow()).toBe(rows()[3])
  await user.keyboard('{Home}')
  expect(selectedRow()).toBe(rows()[0])
})

test('names the selected row through aria-activedescendant, not by moving focus', async () => {
  await renderGitTree()
  const user = userEvent.setup()
  const list = screen.getByTestId('git-tree-list')
  await user.click(list)
  await user.keyboard('{ArrowDown}')

  // The list keeps focus — that is what lets one handler serve every row.
  expect(list).toHaveFocus()
  expect(list.getAttribute('aria-activedescendant')).toBe(selectedRow()?.id)
})

test('clicking a row selects it and swaps the detail panel', async () => {
  await renderGitTree()
  const user = userEvent.setup()

  await user.click(rows()[2]!)

  expect(selectedRow()).toBe(rows()[2])
  expect(await screen.findByTestId('git-tree-message')).toHaveTextContent('on main')
})

test('the detail panel shows the full hash, author with email, and changed files', async () => {
  window.__fakeApi?.setGitTreeCommitDetail(ON_MAIN, {
    hash: ON_MAIN,
    parents: [ROOT],
    author: 'Ann',
    authorEmail: 'ann@example.com',
    date: '2026-01-02T03:04:05Z',
    refs: [],
    message: 'on main\n\nWith a body.',
    files: [
      { path: 'src/a.ts', insertions: 12, deletions: 3 },
      { path: 'logo.png', insertions: null, deletions: null }
    ],
    filesTruncated: false
  })
  await renderGitTree()
  const user = userEvent.setup()

  await user.click(rows()[2]!)

  // Full hash here, unlike the abbreviated one in the row.
  expect(await screen.findByTestId('git-tree-detail-hash')).toHaveTextContent(ON_MAIN)
  const detail = screen.getByTestId('git-tree-detail')
  expect(detail).toHaveTextContent('Ann <ann@example.com>')
  expect(detail).toHaveTextContent('With a body.')

  const files = within(screen.getByTestId('git-tree-files')).getAllByTestId('git-tree-file')
  expect(files).toHaveLength(2)
  expect(files[0]).toHaveTextContent('src/a.ts')
  expect(files[0]).toHaveTextContent('+12')
  // A binary file reports `-` rather than a count, and must not read as "changed nothing".
  expect(files[1]).toHaveTextContent('binary')
  expect(files[1]).not.toHaveTextContent('+0')
})

test("moving to a directory that isn't a repository stops the title naming the old one", async () => {
  await renderGitTree(HISTORY, '/home/ann/projects/tabs')
  await waitFor(() => {
    expect(JSON.stringify(useLayoutStore.getState().root)).toContain('"title":"tabs"')
  })

  window.__fakeApi?.setGitTreeFailure({ kind: 'not-a-repo', path: '/tmp/nowhere' })
  const user = userEvent.setup()
  await user.clear(screen.getByTestId('git-tree-path-input'))
  await user.type(screen.getByTestId('git-tree-path-input'), '/tmp/nowhere{Enter}')

  await screen.findByTestId('git-tree-empty')
  await waitFor(() => {
    expect(JSON.stringify(useLayoutStore.getState().root)).toContain('"title":"nowhere"')
  })
})

test('a directory that is not a repository is a sentence, not an error', async () => {
  window.__fakeApi?.setGitTreeFailure({ kind: 'not-a-repo', path: '/tmp/nowhere' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/tmp/nowhere' }),
    settings: { disabledContentTypes: [] }
  })

  const empty = await screen.findByTestId('git-tree-empty')
  expect(empty).toHaveTextContent('No git repository at /tmp/nowhere.')
  // Still actionable: the path bar and the browse button are the way out, so
  // this state is never a dead end.
  expect(screen.getByTestId('git-tree-path-input')).toBeVisible()
  expect(screen.getByTestId('git-tree-browse-button')).toBeVisible()
})

test('an empty repository says so rather than claiming it is not a repository', async () => {
  window.__fakeApi?.setGitTreeFailure({ kind: 'no-commits', root: '/repo' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })

  // The distinction that exists purely so a brand-new repo isn't called a
  // non-repo — `rev-parse` succeeds there and only `log` fails.
  expect(await screen.findByTestId('git-tree-empty')).toHaveTextContent(
    '/repo is a git repository, but has no commits yet.'
  )
})

test('a missing git binary names itself', async () => {
  window.__fakeApi?.setGitTreeFailure({ kind: 'git-missing' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })

  expect(await screen.findByTestId('git-tree-empty')).toHaveTextContent('git isn’t installed')
})

test('a nonexistent directory names itself, not git', async () => {
  window.__fakeApi?.setGitTreeFailure({ kind: 'no-such-directory', path: '/tmp/gone' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/tmp/gone' }),
    settings: { disabledContentTypes: [] }
  })

  const empty = await screen.findByTestId('git-tree-empty')
  expect(empty).toHaveTextContent('No directory at /tmp/gone.')
  expect(empty).not.toHaveTextContent('installed')
})

test('an unclassified git failure still reaches the user as words', async () => {
  window.__fakeApi?.setGitTreeFailure({ kind: 'failed', message: 'fatal: bad object HEAD' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })

  expect(await screen.findByTestId('git-tree-empty')).toHaveTextContent('fatal: bad object HEAD')
})

test('typing a directory into the path bar re-reads that repository', async () => {
  await renderGitTree()
  const user = userEvent.setup()

  await user.clear(screen.getByTestId('git-tree-path-input'))
  await user.type(screen.getByTestId('git-tree-path-input'), '/other{Enter}')

  // The directory is the pane's whole subject, so it lands in config — which
  // is what makes it survive a remount and a restart.
  await waitFor(() => {
    const leaf = useLayoutStore.getState().root
    expect(JSON.stringify(leaf)).toContain('/other')
  })
  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/other')
  })
})

test('arrow keys inside the path bar move the caret, not the selection', async () => {
  await renderGitTree()
  const user = userEvent.setup()

  await user.click(screen.getByTestId('git-tree-list'))
  await user.keyboard('{ArrowDown}')
  expect(selectedRow()).toBe(rows()[1])

  await user.click(screen.getByTestId('git-tree-path-input'))
  await user.keyboard('{ArrowDown}{ArrowDown}')

  // The list's handler is on an ancestor of the input, so without the
  // stopPropagation this would have walked the selection to the bottom.
  expect(selectedRow()).toBe(rows()[1])
})

test('the browse button adopts the directory it returns', async () => {
  await renderGitTree()
  const user = userEvent.setup()
  window.__fakeApi?.setGitTreeChosenDirectory('/chosen')

  await user.click(screen.getByTestId('git-tree-browse-button'))

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/chosen')
  })
  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/chosen')
  })
})

test('cancelling the browse dialog changes nothing', async () => {
  await renderGitTree()
  const user = userEvent.setup()
  // Undefined is "cancelled" — and is what the real handler always answers
  // under E2E_HIDDEN, so this is the path an e2e run would take too.
  window.__fakeApi?.setGitTreeChosenDirectory(undefined)

  await user.click(screen.getByTestId('git-tree-browse-button'))

  expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/repo')
  expect(rows()).toHaveLength(4)
})

test('a pane created with no directory adopts the default one', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/default-repo' })
  window.__fakeApi?.setGitTreeDefaultDirectory('/default-repo')
  // No cwd in config — which is exactly what `createAction` produces, since a
  // fresh pane cannot yet inherit a directory from the pane it was made from.
  renderApp({ root: createLeaf(GIT_TREE_TYPE), settings: { disabledContentTypes: [] } })

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/default-repo')
  })
  // Awaited on the value itself: the input already exists (empty) before the
  // directory arrives, and syncing it from config is an effect of its own.
  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/default-repo')
  })
})

test('a directory arriving while the path bar is being typed in does not replace it', async () => {
  // The guard behind a real bug, found by an e2e test typing faster than a
  // person can: a fresh pane has no directory and asks main for one, so the
  // answer can land mid-keystroke — and before this, it replaced whatever was
  // half-typed, so the value the user then submitted was the one pushed at
  // them. Driven here by writing config directly, because the *timing* of the
  // real lookup is an Electron-tier fact (this fake resolves immediately) while
  // the guard itself is ordinary renderer behaviour.
  const paneId = await renderGitTree()
  const user = userEvent.setup()

  const input = screen.getByTestId('git-tree-path-input')
  await user.click(input)
  await user.clear(input)
  await user.type(input, '/typed')

  act(() => {
    useLayoutStore.getState().setLeafConfig(paneId, { cwd: '/arrived-late' })
  })

  expect(input).toHaveValue('/typed')

  // ...and submitting still sends what was typed, not what arrived.
  await user.keyboard('{Enter}')
  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/typed')
  })
})

test('Load more appears only when there is more, and asks for another page', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasMore: true })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  const user = userEvent.setup()
  await screen.findByTestId('git-tree-load-more')
  // Measured against a baseline rather than against 1: the fake's call log
  // accumulates for the whole file (it is not part of `reset`), so an absolute
  // count would pass without this button doing anything at all.
  const before = window.__fakeApi?.gitTreeLogCalls().length ?? 0

  await user.click(screen.getByTestId('git-tree-load-more'))
  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls().length ?? 0).toBeGreaterThan(before)
  })

  // And it is gone once the log says there is nothing further.
  await renderGitTree()
  expect(screen.queryByTestId('git-tree-load-more')).not.toBeInTheDocument()
})

test('Cmd/Ctrl+R re-reads the current directory and shows what changed', async () => {
  await renderGitTree()
  expect(rows()).toHaveLength(4)
  const before = window.__fakeApi?.gitTreeLogCalls().length ?? 0

  // A commit landed on the repository behind this pane's back (a terminal
  // pane on the same directory, in the real app) — the fake stands in for
  // that by mutating what the next `log` call will answer.
  const withNewCommit = [
    commit('nnnnnnn0000000000000000000000000000000a', 'new commit'),
    ...HISTORY
  ]
  window.__fakeApi?.setGitTreeLog(withNewCommit, { root: '/repo' })

  await act(async () => {
    window.__fakeApi?.fireShortcut('refresh-pane')
  })

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls().length ?? 0).toBeGreaterThan(before)
  })
  // The same directory, not a different one — refresh re-reads in place.
  expect(window.__fakeApi?.gitTreeLogCalls().at(-1)).toBe('/repo')
  expect(await screen.findByText('new commit')).toBeVisible()
  expect(rows()).toHaveLength(5)
})

test('Cmd/Ctrl+R does nothing when no git tree pane is active', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
  renderApp({ root: createLeaf(EMPTY_TYPE), settings: { disabledContentTypes: [] } })
  const before = window.__fakeApi?.gitTreeLogCalls().length ?? 0

  await act(async () => {
    window.__fakeApi?.fireShortcut('refresh-pane')
  })

  expect(window.__fakeApi?.gitTreeLogCalls().length ?? 0).toBe(before)
})

test('auto-refresh-on-focus re-reads the pane when the window regains focus, only when enabled', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [], contentTypes: { gitTree: { autoRefreshOnFocus: true } } }
  })
  await listReady()
  const before = window.__fakeApi?.gitTreeLogCalls().length ?? 0

  await act(async () => {
    window.dispatchEvent(new Event('focus'))
  })
  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls().length ?? 0).toBeGreaterThan(before)
  })
})

test('...and does not, with the setting at its off-by-default value', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  await listReady()
  const before = window.__fakeApi?.gitTreeLogCalls().length ?? 0

  await act(async () => {
    window.dispatchEvent(new Event('focus'))
  })
  // Nothing to wait for succeeding, so prove the negative by giving a real
  // refresh every chance to have landed instead.
  await act(async () => {
    await Promise.resolve()
  })
  expect(window.__fakeApi?.gitTreeLogCalls().length ?? 0).toBe(before)
})

test("the pane's title becomes the repository's own name", async () => {
  await renderGitTree(HISTORY, '/home/ann/projects/tabs')

  // Same idea as a browser pane taking its page title: a tab reading "tabs"
  // is far more use than three reading "Git tree".
  await waitFor(() => {
    expect(JSON.stringify(useLayoutStore.getState().root)).toContain('"title":"tabs"')
  })
})

test('author and date columns are hidden by default', async () => {
  await renderGitTree()

  expect(screen.queryByTestId('git-tree-author')).not.toBeInTheDocument()
  expect(screen.queryByTestId('git-tree-date')).not.toBeInTheDocument()
})

test('the settings toggles show the author and date columns once enabled', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: {
      disabledContentTypes: [],
      contentTypes: { gitTree: { showAuthorColumn: true, showDateColumn: true } }
    }
  })
  await listReady()

  expect(screen.getAllByTestId('git-tree-author')).toHaveLength(4)
  expect(screen.getAllByTestId('git-tree-date')).toHaveLength(4)
  expect(rows()[0]).toHaveTextContent('Ann')
})

test('the branch-scope select offers the three filters and defaults to all branches', async () => {
  await renderGitTree()

  const select = screen.getByTestId('git-tree-branch-scope') as HTMLSelectElement
  expect(select.value).toBe('all')
  const options = within(select)
    .getAllByRole('option')
    .map((option) => (option as HTMLOptionElement).value)
  expect(options).toEqual(['current', 'local', 'all'])
})

test('choosing a branch scope re-reads the log with it and persists it to the pane', async () => {
  await renderGitTree()
  const user = userEvent.setup()

  await user.selectOptions(screen.getByTestId('git-tree-branch-scope'), 'local')

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogScopes().at(-1)).toBe('local')
  })
  expect(JSON.stringify(useLayoutStore.getState().root)).toContain('"branchScope":"local"')
})

test('a pane restored with a branch scope already chosen opens reading it', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
  const leaf = createLeaf(GIT_TREE_TYPE, { cwd: '/repo', branchScope: 'current' })
  renderApp({ root: leaf, settings: { disabledContentTypes: [] } })
  await listReady()

  expect((screen.getByTestId('git-tree-branch-scope') as HTMLSelectElement).value).toBe('current')
  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogScopes().at(-1)).toBe('current')
  })
})

/** Finds the working-tree row by its sentinel `data-hash=""`, the same way the app does. */
function workingTreeRow(): HTMLElement | undefined {
  return rows().find((row) => row.getAttribute('data-hash') === '')
}

test('uncommitted changes render as a dimmed row connected into the graph above HEAD', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasUncommittedChanges: true })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  await listReady()

  // A real fifth row now, not a separate decoration — same testid, same
  // gutter width as every other row (laneCount is a single shared value), and
  // an outgoing line down into HEAD's own dot below it.
  expect(rows()).toHaveLength(5)
  const workingTree = workingTreeRow()
  expect(workingTree).toBeDefined()
  expect(workingTree).toHaveTextContent('Uncommitted changes')
  expect(workingTree).toHaveClass('git-tree-row-phantom')
  expect(workingTree?.querySelector('.git-tree-hash')).toHaveTextContent('')
  const headRowWidth = rows()[1]!.querySelector('svg')?.getAttribute('width')
  expect(headRowWidth).toBe('24')
  expect(workingTree?.querySelector('svg')).toHaveAttribute('width', headRowWidth!)
  expect(workingTree?.querySelector('svg path')).toBeTruthy()

  // Selectable — an ordinary listbox option, not decoration.
  expect(workingTree).toHaveAttribute('role', 'option')
  // A dirty tree doesn't reroute the default selection away from real
  // history; the newest real commit is still what opens selected.
  expect(selectedRow()).toBe(rows()[1])
  expect(selectedRow()).toHaveTextContent('merge feature')
})

test('selecting the working-tree row shows its own changed files, like a commit', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasUncommittedChanges: true })
  window.__fakeApi?.setGitTreeWorkingTreeDetail({
    hash: '',
    parents: [MERGE],
    author: '',
    authorEmail: '',
    date: '',
    refs: [],
    message: 'Uncommitted changes',
    files: [{ path: 'src/a.ts', insertions: 4, deletions: 1 }],
    filesTruncated: false
  })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  await listReady()
  const user = userEvent.setup()

  await user.click(workingTreeRow()!)

  expect(selectedRow()).toBe(workingTreeRow())
  expect(await screen.findByTestId('git-tree-message')).toHaveTextContent('Uncommitted changes')
  // The file list, exactly the shape a real commit's detail uses.
  expect(screen.getByTestId('git-tree-file')).toHaveTextContent('src/a.ts')
  expect(screen.getByTestId('git-tree-file')).toHaveTextContent('+4')
  expect(screen.getByTestId('git-tree-file')).toHaveTextContent('−1')
  // No commit-only fields for something that isn't a commit — but the
  // parent is shown, naming what it's based on.
  expect(screen.queryByTestId('git-tree-detail-hash')).not.toBeInTheDocument()
  expect(screen.getByTestId('git-tree-detail')).toHaveTextContent('Parent')
  expect(screen.getByTestId('git-tree-detail')).toHaveTextContent(MERGE.slice(0, 7))
})

test('Cmd/Ctrl+R re-reads the working-tree detail, the one row whose detail changes', async () => {
  const workingTreeDetail = (path: string) => ({
    hash: '',
    parents: [MERGE],
    author: '',
    authorEmail: '',
    date: '',
    refs: [],
    message: 'Uncommitted changes',
    files: [{ path, insertions: 1, deletions: 0 }],
    filesTruncated: false
  })
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasUncommittedChanges: true })
  window.__fakeApi?.setGitTreeWorkingTreeDetail(workingTreeDetail('before.ts'))
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  await listReady()
  await userEvent.setup().click(workingTreeRow()!)
  await waitFor(() => expect(screen.getByTestId('git-tree-file')).toHaveTextContent('before.ts'))

  // Its hash is always empty, so nothing about the selection changes across
  // a refresh — only the files behind it.
  window.__fakeApi?.setGitTreeWorkingTreeDetail(workingTreeDetail('after.ts'))
  await act(async () => {
    window.__fakeApi?.fireShortcut('refresh-pane')
  })

  await waitFor(() => expect(screen.getByTestId('git-tree-file')).toHaveTextContent('after.ts'))
  // And the re-read kept it selected rather than falling back to HEAD.
  expect(selectedRow()).toBe(workingTreeRow())
})

test('Home reaches the working-tree row, and arrow keys walk into and out of it', async () => {
  window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasUncommittedChanges: true })
  renderApp({
    root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
    settings: { disabledContentTypes: [] }
  })
  await listReady()
  const user = userEvent.setup()
  await user.click(screen.getByTestId('git-tree-list'))

  await user.keyboard('{Home}')
  expect(selectedRow()).toBe(workingTreeRow())

  await user.keyboard('{ArrowDown}')
  expect(selectedRow()).toBe(rows()[1])
  expect(selectedRow()).toHaveTextContent('merge feature')
})

test('no working-tree row when the working tree is clean', async () => {
  await renderGitTree()

  expect(workingTreeRow()).toBeUndefined()
  expect(rows()).toHaveLength(4)
})

/**
 * Checking out a commit or branch from the commit list.
 *
 * The fresh `branchesAtCommit(hash)` read that drives the whole decision is
 * scripted per test via `setGitTreeBranchesAtCommit` — an unset hash answers
 * with every list empty, i.e. "no branch at all", so a test only states what
 * it actually needs. `HISTORY`'s own `refs` (its `%D`-derived decorations,
 * asserted elsewhere in this file) are never consulted for this — that is
 * the point of the fresh read (see git.ts's own comment).
 */
describe('checking out a commit or branch', () => {
  // A safety net, not the plan: every test above is written to leave no
  // dialog open and no gate held, but a test that fails mid-way (an assertion
  // throwing before its own cleanup runs) would otherwise leave the modal
  // shell's single-instance store, or the fake's checkout gate, poisoned for
  // every later test in this file — turning one failure into a cascade of
  // unrelated ones. Cheap and unconditional, so it costs nothing when a test
  // already cleaned up after itself.
  afterEach(() => {
    useModalStore.getState().close()
    useContextMenuStore.getState().close()
    window.__fakeApi?.setGitTreeCheckoutGate(false)
    window.__fakeApi?.releaseGitTreeCheckout()
    window.__fakeApi?.setGitTreeCheckoutFailure(undefined)
    window.__fakeApi?.setGitTreeBranchesAtCommitRejection(undefined)
  })

  test('right-click opens a context menu with Checkout then Copy SHA-1, and selects the row it opens on', async () => {
    await renderGitTree()

    fireEvent.contextMenu(rows()[2]!, { clientX: 10, clientY: 10 })

    const menu = screen.getByTestId('context-menu')
    expect(
      within(menu)
        .getAllByRole('menuitem')
        .map((item) => item.textContent)
    ).toEqual(['Checkout', 'Copy SHA-1'])
    // Selects the same way a plain click would, so the detail panel below
    // shows the commit the menu (and any dialog it leads to) is acting on —
    // asserted on the panel's actual content, not just the row highlight:
    // the detail fetch is its own debounced effect (see GitTreeRenderer's
    // 100ms timer), so a screenshot taken before it settles can show a
    // selected row beside a still-empty "Select a commit." panel even though
    // the wiring is correct.
    expect(selectedRow()).toBe(rows()[2])
    await waitFor(() => {
      expect(screen.getByTestId('git-tree-message')).toHaveTextContent('on main')
    })
  })

  test('neither trigger does anything on the synthetic uncommitted-changes row', async () => {
    window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo', hasUncommittedChanges: true })
    renderApp({
      root: createLeaf(GIT_TREE_TYPE, { cwd: '/repo' }),
      settings: { disabledContentTypes: [] }
    })
    await listReady()
    const before = window.__fakeApi?.gitTreeBranchesAtCommitCalls().length ?? 0

    fireEvent.contextMenu(workingTreeRow()!, { clientX: 10, clientY: 10 })
    // No menu at all — Copy SHA-1 has no hash to copy here either.
    expect(screen.queryByTestId('context-menu')).not.toBeInTheDocument()

    fireEvent.doubleClick(workingTreeRow()!)
    expect(window.__fakeApi?.gitTreeBranchesAtCommitCalls().length).toBe(before)
  })

  test('right-click → Copy SHA-1 copies the full hash of the row right-clicked, not the one selected before', async () => {
    await renderGitTree()
    const before = window.__fakeApi?.gitTreeBranchesAtCommitCalls().length ?? 0
    const user = userEvent.setup()
    await user.click(rows()[1]!) // ON_FEATURE
    expect(selectedRow()).toBe(rows()[1])

    fireEvent.contextMenu(rows()[2]!, { clientX: 10, clientY: 10 }) // ON_MAIN
    await user.click(screen.getByRole('menuitem', { name: 'Copy SHA-1' }))

    // Exactly the one string, and exactly the hash — nothing around it.
    expect(window.__fakeApi?.copiedText()).toEqual([ON_MAIN])
    expect(screen.queryByTestId('context-menu')).not.toBeInTheDocument()
    // Copying is not a checkout.
    expect(window.__fakeApi?.gitTreeBranchesAtCommitCalls().length).toBe(before)
  })

  test('one local branch at the commit: checks out immediately with no dialog, and the pane refreshes to the new HEAD', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })

    fireEvent.doubleClick(rows()[1]!) // ON_FEATURE, "on feature"

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'branch',
        name: 'feature'
      })
    })
    expect(screen.queryByTestId('git-tree-checkout-choose-dialog')).not.toBeInTheDocument()
    expect(screen.queryByTestId('git-tree-checkout-detach-dialog')).not.toBeInTheDocument()

    // Refreshed without a manual Cmd/Ctrl+R: the header's HEAD label follows
    // the fake's own self-mutated head after a successful checkout.
    await waitFor(() => {
      expect(screen.getByTestId('git-tree-head')).toHaveTextContent('feature')
    })
  })

  test('right-click → Checkout behaves the same as double-click for the one-branch case', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    const user = userEvent.setup()

    fireEvent.contextMenu(rows()[1]!, { clientX: 10, clientY: 10 })
    await user.click(screen.getByRole('menuitem', { name: 'Checkout' }))

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'branch',
        name: 'feature'
      })
    })
  })

  test('several local branches at the commit: opens a choose dialog naming the commit, defaulted to the first in refname order', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_MAIN, { local: ['main', 'stable'] })
    const user = userEvent.setup()

    fireEvent.doubleClick(rows()[2]!) // ON_MAIN, "on main"

    const dialog = await screen.findByTestId('git-tree-checkout-choose-dialog')
    expect(dialog).toHaveTextContent('on main')
    const select = within(dialog).getByTestId('dialog-choose-select') as HTMLSelectElement
    expect(select.value).toBe('main')
    const optionValues = within(select)
      .getAllByRole('option')
      .map((option) => (option as HTMLOptionElement).value)
    expect(optionValues).toEqual(['main', 'stable'])

    // Close it — the modal shell is a single app-wide singleton (only one may
    // be open at a time), so leaving this one open would silently refuse
    // every dialog a later test in this file tries to open.
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }))
  })

  test('picking a branch in the choose dialog checks it out; Cancel leaves the repo untouched', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_MAIN, { local: ['main', 'stable'] })
    const user = userEvent.setup()
    const before = window.__fakeApi?.gitTreeCheckoutCalls().length ?? 0

    fireEvent.doubleClick(rows()[2]!)
    let dialog = await screen.findByTestId('git-tree-checkout-choose-dialog')
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }))

    expect(screen.queryByTestId('git-tree-checkout-choose-dialog')).not.toBeInTheDocument()
    expect(window.__fakeApi?.gitTreeCheckoutCalls().length).toBe(before)

    fireEvent.doubleClick(rows()[2]!)
    dialog = await screen.findByTestId('git-tree-checkout-choose-dialog')
    await user.selectOptions(within(dialog).getByTestId('dialog-choose-select'), 'stable')
    await user.click(within(dialog).getByRole('button', { name: 'Checkout' }))

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'branch',
        name: 'stable'
      })
    })
  })

  test('a lone remote-tracking branch is offered only when there is no local branch, and creates a tracking branch', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, {
      remotes: ['origin/feature-x']
    })

    fireEvent.doubleClick(rows()[1]!)

    // No prompt — a single remote candidate checks out the same as a single
    // local branch would.
    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'remote-branch',
        remote: 'origin',
        name: 'feature-x',
        ref: 'origin/feature-x'
      })
    })
  })

  test('no branch at all: opens a detached-HEAD confirm naming the commit; Cancel leaves the repo untouched', async () => {
    await renderGitTree()
    const user = userEvent.setup()
    const before = window.__fakeApi?.gitTreeCheckoutCalls().length ?? 0

    fireEvent.doubleClick(rows()[3]!) // ROOT, "root commit" — no branchesAtCommit answer set

    const dialog = await screen.findByTestId('git-tree-checkout-detach-dialog')
    expect(dialog).toHaveTextContent('root commit')
    expect(dialog).toHaveTextContent('detached')

    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }))

    expect(screen.queryByTestId('git-tree-checkout-detach-dialog')).not.toBeInTheDocument()
    expect(window.__fakeApi?.gitTreeCheckoutCalls().length).toBe(before)
  })

  test('confirming the detached-HEAD dialog checks out the bare commit, and the HEAD label reads detached', async () => {
    await renderGitTree()
    const user = userEvent.setup()

    fireEvent.doubleClick(rows()[3]!)
    const dialog = await screen.findByTestId('git-tree-checkout-detach-dialog')
    await user.click(within(dialog).getByRole('button', { name: 'Checkout' }))

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'commit',
        hash: ROOT
      })
    })
    await waitFor(() => {
      expect(screen.getByTestId('git-tree-head')).toHaveTextContent(
        `detached at ${ROOT.slice(0, 7)}`
      )
    })
  })

  test('a second checkout trigger while one is in flight is ignored outright — no second branchesAtCommit read either', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    // Calls accumulate across this whole file (see its own top comment on
    // why) — every assertion below is a delta off a captured baseline,
    // never an absolute count.
    const checkoutCallsBefore = window.__fakeApi?.gitTreeCheckoutCalls().length ?? 0
    window.__fakeApi?.setGitTreeCheckoutGate(true)

    fireEvent.doubleClick(rows()[1]!)
    await waitFor(() =>
      expect(window.__fakeApi?.gitTreeCheckoutCalls().length).toBe(checkoutCallsBefore + 1)
    )
    const branchesCallsBefore = window.__fakeApi?.gitTreeBranchesAtCommitCalls().length

    // Dropped synchronously by the in-flight guard, before it would even
    // re-read refs — a rapid second trigger must not race the first's
    // still-pending `git switch` over git's own index.lock.
    fireEvent.doubleClick(rows()[1]!)
    expect(window.__fakeApi?.gitTreeCheckoutCalls().length).toBe(checkoutCallsBefore + 1)
    expect(window.__fakeApi?.gitTreeBranchesAtCommitCalls().length).toBe(branchesCallsBefore)

    window.__fakeApi?.releaseGitTreeCheckout()
    await waitFor(() => {
      expect(screen.getByTestId('git-tree-head')).toHaveTextContent('feature')
    })
    // A later trigger, once the first has actually finished, works again.
    window.__fakeApi?.setGitTreeCheckoutGate(false)
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_MAIN, { local: ['main'] })
    fireEvent.doubleClick(rows()[2]!)
    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls().length).toBe(checkoutCallsBefore + 2)
    })
  })

  test('a failed checkout shows the full refusal text in a one-button alert, and still refreshes', async () => {
    await renderGitTree()
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    window.__fakeApi?.setGitTreeCheckoutFailure(
      { kind: 'failed', message: 'error: local changes would be overwritten' },
      'error: Your local changes to the following files would be overwritten by checkout:\n\tconflict.txt\nPlease commit your changes or stash them before you switch branches.'
    )
    const user = userEvent.setup()
    const logCallsBefore = window.__fakeApi?.gitTreeLogCalls().length ?? 0

    fireEvent.doubleClick(rows()[1]!)

    const dialog = await screen.findByTestId('git-tree-checkout-failed-dialog')
    // The full multi-line stderr, not just classify()'s one-line summary —
    // the file name and the "commit or stash" guidance would be lost by that.
    expect(dialog).toHaveTextContent('conflict.txt')
    expect(dialog).toHaveTextContent('Please commit your changes or stash them')
    expect(dialog.querySelectorAll('button')).toHaveLength(1)

    await user.click(within(dialog).getByRole('button', { name: 'OK' }))
    expect(screen.queryByTestId('git-tree-checkout-failed-dialog')).not.toBeInTheDocument()

    // Still refreshes on a failure — confirms nothing changed rather than
    // leaving the pane showing whatever it last happened to show.
    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeLogCalls().length).toBeGreaterThan(logCallsBefore)
    })

    // Leave the fake succeeding again for any test that runs after this one.
    window.__fakeApi?.setGitTreeCheckoutFailure(undefined)
  })

  test('an IPC rejection mid-checkout still surfaces the alert instead of failing silently, and a later checkout still works', async () => {
    await renderGitTree()
    // Not a `GitFailure` value — the IPC hop itself rejecting (main
    // reloading mid-call, say), which main's "never rejects" can't cover and
    // the bridge folds into one (see gitTreeBridge's invokeResult).
    window.__fakeApi?.setGitTreeBranchesAtCommitRejection(new Error('invoke failed'))
    const user = userEvent.setup()

    fireEvent.doubleClick(rows()[1]!)

    const dialog = await screen.findByTestId('git-tree-checkout-failed-dialog')
    expect(dialog).toHaveTextContent('invoke failed')
    await user.click(within(dialog).getByRole('button', { name: 'OK' }))
    expect(screen.queryByTestId('git-tree-checkout-failed-dialog')).not.toBeInTheDocument()

    // The in-flight guard was released after the failure — a later
    // checkout on the same pane still works rather than being stuck
    // refusing forever.
    window.__fakeApi?.setGitTreeBranchesAtCommitRejection(undefined)
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    fireEvent.doubleClick(rows()[1]!)

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'branch',
        name: 'feature'
      })
    })
  })

  test('checking out in one pane refreshes another git tree pane pointed at the exact same directory', async () => {
    window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    const leafA = createLeaf(GIT_TREE_TYPE, { cwd: '/repo' })
    const leafB = createLeaf(GIT_TREE_TYPE, { cwd: '/repo' })
    renderApp({
      root: createSplit('horizontal', [leafA, leafB]),
      settings: { disabledContentTypes: [] }
    })

    const lists = await screen.findAllByTestId('git-tree-list')
    expect(lists).toHaveLength(2)
    await waitFor(() => expect(screen.getAllByTestId('git-tree-head')).toHaveLength(2))

    const rowsInFirstPane = within(lists[0]!).getAllByTestId('git-tree-row')
    const featureRow = rowsInFirstPane.find((row) => row.getAttribute('data-hash') === ON_FEATURE)
    if (!featureRow) throw new Error('feature row not found in first pane')
    fireEvent.doubleClick(featureRow)

    await waitFor(() => {
      const heads = screen.getAllByTestId('git-tree-head')
      expect(heads[0]).toHaveTextContent('feature')
      expect(heads[1]).toHaveTextContent('feature')
    })
  })

  test("a git tree pane pointed at a different directory is not refreshed by another pane's checkout", async () => {
    window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
    window.__fakeApi?.setGitTreeBranchesAtCommit(ON_FEATURE, { local: ['feature'] })
    const leafA = createLeaf(GIT_TREE_TYPE, { cwd: '/repo' })
    const leafB = createLeaf(GIT_TREE_TYPE, { cwd: '/other-repo' })
    renderApp({
      root: createSplit('horizontal', [leafA, leafB]),
      settings: { disabledContentTypes: [] }
    })

    const lists = await screen.findAllByTestId('git-tree-list')
    expect(lists).toHaveLength(2)
    const otherRepoCallsBefore = (window.__fakeApi?.gitTreeLogCalls() ?? []).filter(
      (dir) => dir === '/other-repo'
    ).length

    const rowsInFirstPane = within(lists[0]!).getAllByTestId('git-tree-row')
    const featureRow = rowsInFirstPane.find((row) => row.getAttribute('data-hash') === ON_FEATURE)
    if (!featureRow) throw new Error('feature row not found in first pane')
    fireEvent.doubleClick(featureRow)

    await waitFor(() => {
      expect(window.__fakeApi?.gitTreeCheckoutCalls()).toContainEqual({
        kind: 'branch',
        name: 'feature'
      })
    })
    // Give the (absent) cross-pane refresh a turn it would need to have taken.
    await Promise.resolve()
    const otherRepoCallsAfter = (window.__fakeApi?.gitTreeLogCalls() ?? []).filter(
      (dir) => dir === '/other-repo'
    ).length
    expect(otherRepoCallsAfter).toBe(otherRepoCallsBefore)
  })
})

describe('the divider between history and details', () => {
  /** A pane pointed at /repo, opened with `config` on top — how a test stands in for a split saved by an earlier session. */
  async function renderPane(config: Record<string, unknown> = {}): Promise<string> {
    window.__fakeApi?.setGitTreeLog(HISTORY, { root: '/repo' })
    const leaf = createLeaf(GIT_TREE_TYPE, { cwd: '/repo', ...config })
    renderApp({ root: leaf, settings: { disabledContentTypes: [] } })
    await listReady()
    return leaf.id
  }

  function savedConfig(paneId: string): Record<string, unknown> {
    const node = findNode(useLayoutStore.getState().root, paneId)
    if (node?.type !== GIT_TREE_TYPE) throw new Error('git tree pane not found')
    return (node as LeafContent).config
  }

  function divider(): HTMLElement {
    return screen.getByTestId('git-tree-divider')
  }

  /** The detail panel's share of the body, as the renderer publishes it to CSS. */
  function detailBasis(): string {
    return divider().parentElement?.style.getPropertyValue('--git-detail-basis') ?? ''
  }

  /**
   * jsdom lays nothing out, so the two rects the divider measures on a press
   * are stubbed: a 500px body, with the divider's top edge `detailHeight`
   * above its bottom.
   */
  function layOut(detailHeight: number): void {
    const el = divider()
    const body = el.parentElement
    if (!body) throw new Error('divider has no body')
    body.getBoundingClientRect = () => new DOMRect(0, 0, 400, 500)
    el.getBoundingClientRect = () => new DOMRect(0, 500 - detailHeight, 400, 0)
  }

  function press(clientY: number): void {
    fireEvent.pointerDown(divider(), { pointerId: 1, button: 0, buttons: 1, clientY })
  }

  function move(clientY: number, buttons = 1): void {
    fireEvent.pointerMove(divider(), { pointerId: 1, buttons, clientY })
  }

  function release(clientY: number): void {
    fireEvent.pointerUp(divider(), { pointerId: 1, button: 0, buttons: 0, clientY })
  }

  test('an untouched pane keeps the 60/40 it always had, details open', async () => {
    const paneId = await renderPane()

    expect(detailBasis()).toBe('40%')
    expect(divider()).not.toHaveAttribute('data-collapsed')
    expect(screen.getByTestId('git-tree-detail')).toBeInTheDocument()
    expect(savedConfig(paneId)).not.toHaveProperty('detailFraction')
  })

  test('a saved split is what the pane opens with', async () => {
    await renderPane({ detailFraction: 0.25 })

    expect(detailBasis()).toBe('25%')
  })

  test('a saved collapse shows only the history, and reads no detail it would not show', async () => {
    const readsBefore = window.__fakeApi?.gitTreeDetailReads().length ?? 0
    await renderPane({ detailCollapsed: true })

    expect(divider()).toHaveAttribute('data-collapsed', 'true')
    expect(screen.queryByTestId('git-tree-detail')).not.toBeInTheDocument()
    // Past the detail read's 100ms debounce, and across a selection change.
    fireEvent.keyDown(screen.getByTestId('git-tree-list'), { key: 'ArrowDown' })
    await new Promise((resolve) => setTimeout(resolve, 200))
    expect(window.__fakeApi?.gitTreeDetailReads().length ?? 0).toBe(readsBefore)
  })

  test('dragging it previews every move, and saves the split on release', async () => {
    const paneId = await renderPane()
    layOut(200)

    press(300)
    move(200)
    // 100px up from 200px of details in a 500px body.
    expect(detailBasis()).toBe('60%')
    // Only the release is worth a layout save.
    expect(savedConfig(paneId)).not.toHaveProperty('detailFraction')

    release(200)
    expect(savedConfig(paneId)).toMatchObject({ detailFraction: 0.6, detailCollapsed: false })
    expect(detailBasis()).toBe('60%')
  })

  test('dragging it to the bottom collapses the details, and back up reopens them on the selected commit', async () => {
    const paneId = await renderPane()
    layOut(200)

    press(300)
    move(490)
    release(490)
    expect(screen.queryByTestId('git-tree-detail')).not.toBeInTheDocument()
    expect(divider()).toHaveAttribute('data-collapsed', 'true')
    expect(savedConfig(paneId)).toMatchObject({ detailCollapsed: true })

    // Collapsed, the divider is an 8px bar along the body's bottom.
    layOut(8)
    press(496)
    move(296)
    release(296)
    expect(divider()).not.toHaveAttribute('data-collapsed')
    expect(savedConfig(paneId)).toMatchObject({ detailFraction: 0.416, detailCollapsed: false })
    // The detail read resumes with the panel.
    expect(await screen.findByTestId('git-tree-message')).toHaveTextContent('merge feature')
  })

  test('a press that moves nothing saves nothing', async () => {
    const paneId = await renderPane()
    layOut(200)

    press(300)
    release(300)

    expect(savedConfig(paneId)).not.toHaveProperty('detailFraction')
    expect(savedConfig(paneId)).not.toHaveProperty('detailCollapsed')
  })

  test('a release it never saw ends the drag where it was last shown', async () => {
    const paneId = await renderPane()
    layOut(200)

    press(300)
    move(250)
    // A move with the button up: the release landed somewhere this window
    // never heard from (a browser pane's guest, say).
    move(250, 0)
    expect(savedConfig(paneId)).toMatchObject({ detailFraction: 0.5 })

    // The drag is over, so a later held move is no longer a resize.
    move(100)
    expect(detailBasis()).toBe('50%')
  })

  test('a press a split separator already claimed is left to it', async () => {
    const paneId = await renderPane()
    layOut(200)
    // What react-resizable-panels does for a press inside its own band: claim
    // it from a document capture listener, before any React handler runs.
    const claim = (event: Event): void => event.preventDefault()
    document.addEventListener('pointerdown', claim, true)
    try {
      press(300)
      move(200)
      release(200)
    } finally {
      document.removeEventListener('pointerdown', claim, true)
    }

    expect(detailBasis()).toBe('40%')
    expect(savedConfig(paneId)).not.toHaveProperty('detailFraction')
  })
})
