import { createLeaf } from '@shared/model/factories'
import { EMPTY_TYPE } from '@shared/model/types'
import { act, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterAll, beforeAll, beforeEach, expect, test } from 'vitest'
import { contentRegistry } from '../../../../renderer/src/core/registry/registry'
import { useLayoutStore } from '../../../../renderer/src/core/store/layoutStore'
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
  await screen.findByTestId('git-tree-list')
  return leaf.id
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
  expect(await screen.findByTestId('git-tree-path-input')).toHaveValue('/default-repo')
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
  await screen.findByTestId('git-tree-list')
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
  await screen.findByTestId('git-tree-list')
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
