import { readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import type { Locator, Page } from '@playwright/test'
import type { ElectronApplication } from 'playwright'
import { expectNoDragFrom } from './helpers/drag'
import { type Box, requireBox } from './helpers/geometry'
import {
  createEmptyRepo,
  createPlainDirectory,
  createRepoForConflictingCheckout,
  createRepoWithBranches,
  createRepoWithMerge,
  createRepoWithTwoBranchesAtOneCommit,
  git,
  gitOutput,
  removeTestRepos
} from './helpers/gitRepo'
import { expect, test, withApp } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import {
  closeInactiveRootTab,
  closePane,
  createViaPalette,
  headerOf,
  initialPane,
  paneOf
} from './helpers/pane'
import { mergeSettings, openSettingsTab } from './helpers/settings'
import { alive, openTerminal, typeAndEnter } from './helpers/terminal'

/**
 * The git tree pane against real repositories.
 *
 * This tier owns exactly what only it can answer: that the app's own `git`
 * invocations produce the graph they claim to, across the commit shapes that
 * behave differently (a merge, a root commit, a binary-free numstat), that a
 * directory survives a relaunch, and the geometry of the divider between the
 * history and the details — a question only a real layout engine answers,
 * since the Chromium tier registers stub content instead. What the rows *say*,
 * how the selection moves and how each failure reads are renderer questions
 * and live in
 * src/plugins/gitTree/renderer/__tests__/gitTree.test.tsx, driven against a
 * scripted bridge — repeating them here would only be slower.
 *
 * Repositories are built per test in a temp dir with every hash input pinned
 * (see helpers/gitRepo.ts) and dropped in afterAll.
 *
 * The cross-type cwd inheritance tests at the bottom are here for the same
 * reason: `config.cwd` on a terminal leaf is a stale snapshot from before every
 * `cd` the user typed (CLAUDE.md is emphatic), so a test that doesn't drive a
 * real shell into a real directory proves nothing about inheritance — it only
 * proves a config key was copied. Those are the only tests in this file that
 * open a terminal, and each closes its own before finishing.
 */

test.afterAll(() => {
  removeTestRepos()
})

/** Fills the pane's own empty slot with a git tree, straight from the empty-pane toolbar. */
async function openGitTree(page: Page): Promise<Locator> {
  await initialPane(page).getByTestId('empty-pane-new-git-tree-button').click()
  const pane = page.getByTestId('git-tree')
  await expect(pane).toBeVisible()
  return pane
}

/**
 * The enclosing pane's own header — where the path bar, browse button, HEAD
 * label and branch-scope select all live now (moved out of the git-tree body
 * via GitTreeHeaderTitle, the same way BrowserHeaderTitle moved the
 * browser's toolbar).
 */
function headerOfGitTree(gitTree: Locator): Locator {
  return headerOf(paneOf(gitTree))
}

/** Points an open pane at `dir` through its path bar — the real control, and the one a picker only fills in. */
async function pointAt(pane: Locator, dir: string): Promise<void> {
  const pathInput = headerOfGitTree(pane).getByTestId('git-tree-path-input')
  await pathInput.fill(dir)
  await pathInput.press('Enter')
}

/** The common setup: a merge-bearing repo, a fresh git tree pane pointed at it. */
async function openGitTreeOn(
  page: Page,
  repo = createRepoWithMerge()
): Promise<{ repo: string; pane: Locator }> {
  const pane = await openGitTree(page)
  await pointAt(pane, repo)
  return { repo, pane }
}

test('a fresh pane lands on a real repository rather than on an error', async ({ page }) => {
  const pane = await openGitTree(page)

  // A pane is created with no directory at all and adopts one from main (the
  // app's own cwd when that is a repository, else home). Under the harness
  // that is this checkout, so the honest assertion is that it found *a* repo
  // and read real commits out of it — not which.
  await expect(headerOfGitTree(pane).getByTestId('git-tree-path-input')).not.toHaveValue('')
  await expect(pane.getByTestId('git-tree-row').first()).toBeVisible()
})

test('renders a real merge as a two-lane graph, newest first', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  const rows = pane.getByTestId('git-tree-row')
  await expect(rows).toHaveCount(4)
  // Ascending commit dates, so --date-order fixes this sequence exactly.
  await expect(rows.nth(0)).toContainText('merge feature')
  await expect(rows.nth(1)).toContainText('on main')
  await expect(rows.nth(2)).toContainText('on feature')
  await expect(rows.nth(3)).toContainText('root commit')

  // The whole point of drawing a graph: git's own %P parent lists, through
  // lane assignment, produce a gutter two lanes (2 x 12px) wide. A parse that
  // silently dropped parents would render four unconnected tips and be wider;
  // one that dropped the second parent of the merge would be exactly one lane.
  await expect(rows.nth(0).locator('svg')).toHaveAttribute('width', '24')

  // Branch tips are decorated, and HEAD is split out of `HEAD -> main`.
  await expect(rows.nth(0).getByTestId('git-tree-ref')).toHaveText(['HEAD', 'main'])
  await expect(rows.nth(2).getByTestId('git-tree-ref')).toHaveText(['feature'])
})

test('reads the branch HEAD is on', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toHaveText('main')
})

test('shows a real commit’s files, with counts from git itself', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  await pane.getByTestId('git-tree-row').nth(1).click()

  const detail = pane.getByTestId('git-tree-detail')
  await expect(detail).toContainText('on main')
  await expect(detail).toContainText('Ann Example <ann@example.com>')
  // Two lines added to one new file — a real `git show --numstat` result, not
  // a shape the fake could have invented.
  await expect(pane.getByTestId('git-tree-file')).toHaveCount(1)
  await expect(pane.getByTestId('git-tree-file')).toContainText('main.txt')
  await expect(pane.getByTestId('git-tree-file')).toContainText('+2')
})

/**
 * The commit shape a plain `git show --numstat` prints *nothing* for, because
 * git declines to pick a side of a merge without being told which. Covered
 * here rather than in jsdom because the whole question is what the real
 * command does.
 */
test('a merge commit still lists the files it brought in', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  await pane.getByTestId('git-tree-row').nth(0).click()

  await expect(pane.getByTestId('git-tree-detail')).toContainText('merge feature')
  // Against the first parent, so this is what the merge added: the feature
  // branch's file.
  await expect(pane.getByTestId('git-tree-file')).toHaveCount(1)
  await expect(pane.getByTestId('git-tree-file')).toContainText('feature.txt')
})

/** The other shape with no ordinary parent to diff against. */
test('a root commit lists its files rather than coming back empty', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  await pane.getByTestId('git-tree-row').nth(3).click()

  await expect(pane.getByTestId('git-tree-detail')).toContainText('root commit')
  await expect(pane.getByTestId('git-tree-file')).toContainText('root.txt')
})

test('arrow keys walk real commits and swap the detail panel', async ({ page }) => {
  const { pane } = await openGitTreeOn(page)

  await pane.getByTestId('git-tree-list').click()
  await pane.getByTestId('git-tree-list').press('ArrowDown')
  await pane.getByTestId('git-tree-list').press('ArrowDown')

  await expect(pane.getByTestId('git-tree-row').nth(2)).toHaveAttribute('aria-selected', 'true')
  await expect(pane.getByTestId('git-tree-detail')).toContainText('on feature')
})

test('a directory that is not a repository says so, and stays usable', async ({ page }) => {
  const plain = createPlainDirectory()
  const repo = createRepoWithMerge()
  const pane = await openGitTree(page)

  await pointAt(pane, plain)
  await expect(pane.getByTestId('git-tree-empty')).toContainText('No git repository at')

  // Not a dead end: the same path bar takes it somewhere real.
  await pointAt(pane, repo)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
})

test('a repository with no commits is told apart from a non-repository', async ({ page }) => {
  const empty = createEmptyRepo()
  const pane = await openGitTree(page)

  await pointAt(pane, empty)

  // The distinction exists because `rev-parse --show-toplevel` succeeds in a
  // freshly `git init`ed directory and only `log` fails — which is a fact
  // about real git, so only this tier can prove the two are told apart.
  await expect(pane.getByTestId('git-tree-empty')).toContainText('has no commits yet')
  await expect(pane.getByTestId('git-tree-empty')).not.toContainText('No git repository at')
})

test('a directory that does not exist says so, not that git is missing', async ({ page }) => {
  const missing = `${createPlainDirectory()}-does-not-exist`
  const pane = await openGitTree(page)

  await pointAt(pane, missing)

  // execFile's ENOENT is ambiguous between "no git binary" and "no such cwd" —
  // only real git run against a real missing path proves the two are told apart.
  await expect(pane.getByTestId('git-tree-empty')).toContainText('No directory at')
  await expect(pane.getByTestId('git-tree-empty')).not.toContainText('isn’t installed')
})

/**
 * The browse button, driven for real — and the point is that it *cannot* hang.
 *
 * The main-process handler's first line answers "cancelled" under E2E_HIDDEN,
 * because a native `showOpenDialog` renders even for a window that was never
 * shown and Playwright can neither see nor click one. Without that bail this
 * test would not fail, it would time out with the dialog on screen; with it,
 * pressing the button is a no-op and the pane keeps reading what it was.
 */
test('the browse button cannot block the app, and cancelling changes nothing', async ({ page }) => {
  const { repo, pane } = await openGitTreeOn(page)

  await headerOfGitTree(pane).getByTestId('git-tree-browse-button').click()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-path-input')).toHaveValue(repo)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
})

/**
 * The path bar, browse button and branch-scope select now sit inside
 * `.pane-header`'s own drag-arming row for the first time (they used to live
 * in the pane body's own `.git-tree-toolbar`, which had no such pointerdown
 * handler at all) — the same real, shipping counterpart the browser's
 * HeaderTitle got in issue #13. The header's own press exclusion for
 * interactive elements (Pane's `onHeaderPointerDown`) is what keeps a click
 * there from also starting a pane drag.
 */
test("a git tree pane's header controls do not start a pane drag", async ({ page }) => {
  const { pane } = await openGitTreeOn(page)
  const header = headerOfGitTree(pane)

  for (const testId of ['git-tree-path-input', 'git-tree-browse-button', 'git-tree-branch-scope']) {
    await expectNoDragFrom(header.getByTestId(testId))
  }
})

/**
 * Commits an empty change into `repo` from a real shell, opened as a new tab
 * alongside `pane`'s own git tree content (the same command-palette path the
 * cross-type inheritance tests below use) and left open — closing it would
 * collapse the two-tab group back down to a lone tab (`withTabRemoved` in
 * tree.ts), which remounts the surviving content and would refetch on its
 * own, confounding what these tests mean to isolate. Returns the terminal's
 * pid so the caller can close it, and its own commitment to closing it,
 * after every assertion that cares about the *not-yet-collapsed* shape.
 */
async function commitBehindItsBack(
  electronApp: ElectronApplication,
  page: Page,
  pane: Locator,
  repo: string
): Promise<number> {
  await createViaPalette(electronApp, page, pane, 'pane-new-terminal-button')
  const term = page.getByTestId('terminal')
  await expect(term).toBeVisible()
  const pid = Number(await term.getAttribute('data-pty-pid'))
  // Not openTerminal's "wait for ~": this terminal inherited the git tree
  // pane's own cwd (already pointed at `repo`), so its prompt never shows the
  // home directory — the repo's own name is the readiness signal instead,
  // same as the cross-type inheritance tests below.
  await expect(term).toContainText(basename(repo), { timeout: 20_000 })
  await typeAndEnter(
    term,
    'git -c user.name=Ann -c user.email=ann@example.com commit -q --allow-empty -m "new commit"'
  )
  await typeAndEnter(term, 'echo committed')
  await expect(term).toContainText('committed')
  return pid
}

/** Switches back to git tree's own tab — the original, so it's first in the strip — without closing the terminal beside it. */
async function backToGitTree(page: Page): Promise<void> {
  await page.getByRole('tab').first().click()
}

test('Cmd/Ctrl+R re-reads the pane after a commit lands behind its back', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  // The commit landed through a terminal, which is exactly what git.ts's
  // fresh shell-out per call means the git tree pane has no way to notice on
  // its own — see TODO/feature-git-tree-refresh-action.md. `openGitTree`
  // fills root's own initial pane in place, so that pane (not the `git-tree`
  // content locator, which is scoped inside it) is what the command palette
  // targets.
  const pid = await commitBehindItsBack(electronApp, page, initialPane(page), repo)
  await backToGitTree(page)

  await clickMenuItem(electronApp, 'Refresh', page)

  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(5)
  await expect(gitTree.getByTestId('git-tree-row').first()).toContainText('new commit')

  await page.getByRole('tab').last().click()
  await page.locator('.tab.tab-active .tab-close').click()
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

test('auto-refresh-on-focus re-reads a git tree pane when it becomes active again, once enabled', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const settingsPage = await openSettingsTab(electronApp, page, 'gitTree')
  await settingsPage.getByTestId('settings-auto-refresh-checkbox').check()

  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  const pid = await commitBehindItsBack(electronApp, page, initialPane(page), repo)

  // No Refresh click: switching back to git tree's own tab, with the window
  // focused (which the harness always reports — see the bell spec's header
  // comment), is the whole trigger.
  await backToGitTree(page)

  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(5)
  await expect(gitTree.getByTestId('git-tree-row').first()).toContainText('new commit')

  await page.getByRole('tab').last().click()
  await page.locator('.tab.tab-active .tab-close').click()
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

test('...and does not, with the setting off', async ({ page, electronApp }) => {
  await mergeSettings(electronApp, { contentTypes: { gitTree: { autoRefreshOnFocus: false } } })
  const repo = createRepoWithMerge()
  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  const pid = await commitBehindItsBack(electronApp, page, initialPane(page), repo)
  await backToGitTree(page)

  // Nothing to wait for succeeding, so prove the negative by giving a real
  // refresh every chance to have landed instead.
  await page.waitForTimeout(500)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  await page.getByRole('tab').last().click()
  await page.locator('.tab.tab-active .tab-close').click()
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

/**
 * Cross-type cwd inheritance, in the only tier that can tell it from a config
 * copy: a real `$SHELL -l` that has actually `cd`'d somewhere.
 *
 * `config.cwd` on that terminal leaf still says whatever it said at creation —
 * the shell's own `cd` never writes back to it — so a git tree that opened on
 * the *typed* directory can only have got there by asking the terminal's type
 * for its live one (exposeCwd → main's getTerminalCwd → the OS). Nothing about
 * this is observable with a fake bridge, which is why jsdom covers the wiring
 * and not this.
 */
test('a git tree created from a terminal opens on the directory that shell is in, not the one it started in', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const term = await openTerminal(initialPane(page))
  const pid = Number(await term.getAttribute('data-pty-pid'))

  // The `cd` is the whole point: after this the terminal's own config.cwd is
  // stale, and only a live lookup can find where the shell actually is.
  await typeAndEnter(term, `cd ${repo}`)
  await typeAndEnter(term, 'pwd')
  await expect(term).toContainText(repo)

  await createViaPalette(electronApp, page, initialPane(page), 'pane-new-git-tree-button')

  const pane = page.getByTestId('git-tree')
  await expect(pane).toBeVisible()
  await expect(headerOfGitTree(pane).getByTestId('git-tree-path-input')).toHaveValue(repo)
  // ...and it really read that repository, rather than merely displaying its
  // path: this is the graph built earlier in this file.
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
  await expect(pane.getByTestId('git-tree-row').nth(0)).toContainText('merge feature')

  // Tidy the real shell rather than leaving it for the shared app's quit. The
  // terminal is root's original tab, backgrounded by the git tree just added.
  await closeInactiveRootTab(page)
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

/**
 * The symmetry, and the clearest evidence the capability is genuinely
 * cross-type rather than a terminal→gitTree special case wearing a general
 * name: here the git tree is the one *exposing* a directory and the terminal
 * is the one reading it, through the same two hooks in the opposite roles.
 */
test('a terminal created from a git tree pane starts in that repository', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  // Stated, not inherited: this is the terminal's own gate on inheriting, and
  // it governs this direction exactly as it governs a terminal-to-terminal
  // split.
  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await settingsPage.getByTestId('settings-inherit-cwd-checkbox').check()

  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  await createViaPalette(electronApp, page, initialPane(page), 'pane-new-terminal-button')

  const term = page.getByTestId('terminal')
  await expect(term).toBeVisible()
  await expect(term).toHaveAttribute('data-pty-pid', /^\d+$/)
  const pid = Number(await term.getAttribute('data-pty-pid'))

  // Deliberately NOT openTerminal's "wait for `~` in the prompt": that helper
  // waits for a shell sitting in the *home* directory, which is precisely what
  // this test asserts does not happen. The repo's own name appearing in the
  // prompt is both the readiness signal and the first half of the evidence.
  await expect(term).toContainText(basename(repo), { timeout: 20_000 })

  // The second half, and the unambiguous one — a prompt could in principle
  // show a name from anywhere.
  await typeAndEnter(term, 'pwd')
  await expect(term).toContainText(repo)

  // Tidy the real shell. It is the *active* tab here (it was created last), so
  // close the git tree behind it first and then this pane itself.
  await closeInactiveRootTab(page)
  await closePane(initialPane(page))
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

test("...and stays at its own default when the terminal's inheritance setting is off", async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await settingsPage.getByTestId('settings-inherit-cwd-checkbox').uncheck()

  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  await createViaPalette(electronApp, page, initialPane(page), 'pane-new-terminal-button')

  const term = page.getByTestId('terminal')
  await expect(term).toHaveAttribute('data-pty-pid', /^\d+$/)
  const pid = Number(await term.getAttribute('data-pty-pid'))
  await expect(term).toContainText('~', { timeout: 20_000 })

  await typeAndEnter(term, 'pwd')
  await expect(term).toContainText(homedir())
  await expect(term).not.toContainText(repo)

  await closeInactiveRootTab(page)
  await closePane(initialPane(page))
  await expect.poll(() => alive(electronApp, pid), { timeout: 5000 }).toBe(false)
})

/**
 * How long a self-launched app's first read may take to list its rows. The
 * relaunch tests below are the only ones here that wait on a *cold* app —
 * fresh userData, first `git` spawns in a new process — and under a
 * contended full-suite run that first list has been measured missing at the
 * default 5s (roughly one run in five, always at this first wait, never after
 * the relaunch), while passing every time on a warm machine. Sized like
 * helpers/terminal.ts's shell-prompt wait, for the same contention; a read
 * that truly never lands still fails, just later.
 */
const COLD_APP_FIRST_READ_MS = 20_000

/**
 * The directory is the pane's whole subject, so it has to persist — self
 * launched, because a relaunch is the subject.
 */
test('the repository a pane is reading survives a relaunch', async ({ userDataDir }) => {
  const repo = createRepoWithMerge()

  await withApp(userDataDir, async (_app, page1) => {
    const pane = await openGitTree(page1)
    await pointAt(pane, repo)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4, {
      timeout: COLD_APP_FIRST_READ_MS
    })
  })

  await withApp(userDataDir, async (_app, page2) => {
    const pane = page2.getByTestId('git-tree')
    await expect(pane).toBeVisible()
    // Restored pointing at the same repository, not back at the default one.
    await expect(headerOfGitTree(pane).getByTestId('git-tree-path-input')).toHaveValue(repo)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
  })
})

/**
 * The body's parts, measured. The divider is zero-height while the details
 * are open (an 8px bar once collapsed), so its box's top edge *is* the
 * boundary; the body is its parent.
 */
async function measureSplit(pane: Locator): Promise<{
  body: Box
  list: Box
  divider: Box
  detail: Box | null
}> {
  const divider = pane.getByTestId('git-tree-divider')
  const detail = pane.getByTestId('git-tree-detail')
  return {
    body: await requireBox(divider.locator('..')),
    list: await requireBox(pane.getByTestId('git-tree-list')),
    divider: await requireBox(divider),
    // Counted first: `boundingBox` waits for an element to appear, and a
    // collapsed pane has no detail panel to wait for.
    detail: (await detail.count()) > 0 ? await detail.boundingBox() : null
  }
}

/**
 * Drags the divider from its top edge to `toY`, with a real press, held moves
 * and release. Only ever within a pane that has no browser guest in it — a
 * held-button move onto a live guest can hang CDP (see `expectNoDragFrom`).
 */
async function dragDividerTo(page: Page, pane: Locator, toY: number): Promise<void> {
  const box = await requireBox(pane.getByTestId('git-tree-divider'))
  const x = box.x + box.width / 2
  // Two pixels into a collapsed bar; exactly the boundary for an open one,
  // which the hit strip straddles.
  const fromY = box.y + Math.min(box.height, 2)
  await page.mouse.move(x, fromY)
  await page.mouse.down()
  await page.mouse.move(x, toY, { steps: 8 })
  await page.mouse.up()
}

/**
 * Geometry is this tier's to measure: jsdom lays nothing out, and the
 * Chromium tier registers stub content rather than the git tree. Everything
 * about *what* a drag saves is pinned in gitTree.test.tsx.
 */
test.describe('the divider between history and details', () => {
  test('an untouched pane splits 60/40, as it always has', async ({ page }) => {
    const { pane } = await openGitTreeOn(page)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)

    const { body, list, divider, detail } = await measureSplit(pane)
    if (!detail) throw new Error('details not shown')
    expect(Math.abs(list.height - body.height * 0.6)).toBeLessThanOrEqual(1)
    expect(Math.abs(detail.height - body.height * 0.4)).toBeLessThanOrEqual(1)
    // Takes no room of its own: the list ends where the details begin.
    expect(divider.height).toBe(0)
    expect(Math.abs(list.y + list.height - detail.y)).toBeLessThanOrEqual(1)
  })

  test('dragging it moves the boundary with the pointer', async ({ page }) => {
    const { pane } = await openGitTreeOn(page)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
    const before = await measureSplit(pane)
    if (!before.detail) throw new Error('details not shown')

    await dragDividerTo(page, pane, before.divider.y - 100)

    const after = await measureSplit(pane)
    if (!after.detail) throw new Error('details not shown')
    expect(Math.abs(after.detail.height - (before.detail.height + 100))).toBeLessThanOrEqual(2)
    expect(Math.abs(after.list.height - (before.list.height - 100))).toBeLessThanOrEqual(2)
  })

  test('dragged to the bottom it collapses the details into a bar, and dragged back up reopens them', async ({
    page
  }) => {
    const { pane } = await openGitTreeOn(page)
    await expect(pane.getByTestId('git-tree-message')).toContainText('merge feature')
    const open = await measureSplit(pane)
    const bodyBottom = open.body.y + open.body.height

    await dragDividerTo(page, pane, bodyBottom - 5)

    await expect(pane.getByTestId('git-tree-detail')).toHaveCount(0)
    await expect(pane.getByTestId('git-tree-divider')).toHaveAttribute('data-collapsed', 'true')
    const collapsed = await measureSplit(pane)
    // The bar sits on the body's bottom edge, and the history has the rest.
    expect(
      Math.abs(collapsed.divider.y + collapsed.divider.height - bodyBottom)
    ).toBeLessThanOrEqual(1)
    expect(collapsed.divider.height).toBeLessThan(12)
    expect(
      Math.abs(collapsed.list.height - (collapsed.body.height - collapsed.divider.height))
    ).toBeLessThanOrEqual(1)

    await dragDividerTo(page, pane, bodyBottom - 200)

    await expect(pane.getByTestId('git-tree-divider')).not.toHaveAttribute('data-collapsed')
    // Reopened on the commit that was selected all along, read afresh.
    await expect(pane.getByTestId('git-tree-message')).toContainText('merge feature')
    const reopened = await measureSplit(pane)
    if (!reopened.detail) throw new Error('details not shown')
    expect(Math.abs(reopened.detail.height - 200)).toBeLessThanOrEqual(3)
  })

  /** Self-launched, because a relaunch is the subject. */
  test('where it was left survives a relaunch', async ({ userDataDir }) => {
    const repo = createRepoWithMerge()
    let savedShare = 0

    await withApp(userDataDir, async (_app, page1) => {
      const pane = await openGitTree(page1)
      await pointAt(pane, repo)
      await expect(pane.getByTestId('git-tree-row')).toHaveCount(4, {
        timeout: COLD_APP_FIRST_READ_MS
      })
      const before = await measureSplit(pane)

      await dragDividerTo(page1, pane, before.divider.y - 120)

      const after = await measureSplit(pane)
      if (!after.detail) throw new Error('details not shown')
      savedShare = after.detail.height / after.body.height
      expect(savedShare).toBeGreaterThan(0.5)
    })

    await withApp(userDataDir, async (_app, page2) => {
      const pane = page2.getByTestId('git-tree')
      await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
      const restored = await measureSplit(pane)
      if (!restored.detail) throw new Error('details not shown')
      // A share rather than pixels, in case the window comes back another size.
      expect(Math.abs(restored.detail.height / restored.body.height - savedShare)).toBeLessThan(
        0.01
      )
    })
  })
})

test('the branch filter narrows and widens which commits are shown, against real refs', async ({
  page
}) => {
  const { pane } = await openGitTreeOn(page, createRepoWithBranches())
  const branchScope = headerOfGitTree(pane).getByTestId('git-tree-branch-scope')

  // Default is "All branches" — local and remote-tracking — matching what
  // the pane showed before this filter existed.
  await expect(branchScope).toHaveValue('all')
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(3)

  await branchScope.selectOption('current')
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(1)
  await expect(pane.getByTestId('git-tree-row')).toContainText('root commit')

  await branchScope.selectOption('local')
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(2)
  await expect(pane.getByTestId('git-tree-row')).toContainText(['on feature', 'root commit'])

  await branchScope.selectOption('all')
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(3)
  await expect(pane.getByTestId('git-tree-row')).toContainText([
    'on remote-only',
    'on feature',
    'root commit'
  ])
})

test('uncommitted changes appear as a row connected into the graph, and disappear once resolved', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const { pane } = await openGitTreeOn(page, repo)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
  // The sentinel every real row can never carry.
  await expect(pane.locator('[data-hash=""]')).toHaveCount(0)

  // A real unstaged change to a tracked file — made directly on disk, the
  // same way the fixture itself was built, rather than through a shell.
  const mainFile = join(repo, 'main.txt')
  const original = readFileSync(mainFile, 'utf8')
  writeFileSync(mainFile, `${original}a new line\n`)
  await clickMenuItem(electronApp, 'Refresh', page)

  const workingTreeRow = pane.locator('[data-hash=""]')
  await expect(workingTreeRow).toBeVisible()
  await expect(workingTreeRow).toContainText('Uncommitted changes')
  // A genuine fifth row — not a separate decoration — with the same gutter
  // width as the real graph immediately below it, i.e. actually connected
  // rather than floating on its own.
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(5)
  const [workingTreeSvgWidth, headSvgWidth] = await Promise.all([
    workingTreeRow.locator('svg').getAttribute('width'),
    pane.getByTestId('git-tree-row').nth(1).locator('svg').getAttribute('width')
  ])
  expect(workingTreeSvgWidth).toBe(headSvgWidth)

  writeFileSync(mainFile, original)
  await clickMenuItem(electronApp, 'Refresh', page)
  await expect(pane.locator('[data-hash=""]')).toHaveCount(0)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
})

test('selecting the uncommitted-changes row shows real changed files, with real counts', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const { pane } = await openGitTreeOn(page, repo)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)

  // A tracked file gains two lines, and a brand new untracked file appears
  // alongside it — both should show up with real counts, not placeholders,
  // exactly like a real commit's own file list.
  const mainFile = join(repo, 'main.txt')
  writeFileSync(mainFile, `${readFileSync(mainFile, 'utf8')}line three\nline four\n`)
  writeFileSync(join(repo, 'untracked.txt'), 'one\ntwo\nthree\n')
  await clickMenuItem(electronApp, 'Refresh', page)

  const workingTreeRow = pane.locator('[data-hash=""]')
  await expect(workingTreeRow).toBeVisible()
  await workingTreeRow.click()

  const detail = pane.getByTestId('git-tree-detail')
  await expect(detail).toContainText('Uncommitted changes')
  await expect(pane.getByTestId('git-tree-file')).toHaveCount(2)
  await expect(detail).toContainText('main.txt')
  await expect(detail).toContainText('+2')
  await expect(detail).toContainText('untracked.txt')
  await expect(detail).toContainText('+3')
  // Not a real commit, so no commit-only fields — but it does name what it's
  // based on, the same connection the graph shows visually.
  await expect(detail).not.toContainText('Commit')
  await expect(detail).toContainText('Parent')
})

test('a repository with no commits but a staged file shows a selectable working-tree row, not the no-commits notice', async ({
  page
}) => {
  const empty = createEmptyRepo()
  writeFileSync(join(empty, 'staged.txt'), 'staged\n')
  git(empty, ['add', '-A'])

  const { pane } = await openGitTreeOn(page, empty)

  await expect(pane.getByTestId('git-tree-empty')).not.toBeVisible()
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(1)
  const workingTreeRow = pane.getByTestId('git-tree-row').first()
  await expect(workingTreeRow).toHaveAttribute('data-hash', '')
  await expect(workingTreeRow).toContainText('Uncommitted changes')

  await workingTreeRow.click()
  await expect(pane.getByTestId('git-tree-file')).toContainText('staged.txt')
  await expect(pane.getByTestId('git-tree-file')).toContainText('+1')
})

test('configurable columns: author and date stay hidden until turned on in Settings', async ({
  page,
  electronApp
}) => {
  await mergeSettings(electronApp, {
    contentTypes: { gitTree: { showAuthorColumn: false, showDateColumn: false } }
  })
  const { pane } = await openGitTreeOn(page)
  await expect(pane.getByTestId('git-tree-author')).toHaveCount(0)
  await expect(pane.getByTestId('git-tree-date')).toHaveCount(0)

  const settingsPage = await openSettingsTab(electronApp, page, 'gitTree')
  await settingsPage.getByTestId('settings-show-author-column-checkbox').check()
  await settingsPage.getByTestId('settings-show-date-column-checkbox').check()

  await expect(pane.getByTestId('git-tree-author').first()).toContainText('Ann Example')
  await expect(pane.getByTestId('git-tree-date').first()).toBeVisible()
})

// Checking out a commit or branch from the commit list, against real git.
// jsdom (gitTree.test.tsx) already owns the dialog wiring/single-flight/
// scripted-refusal questions against a fake bridge; this tier owns exactly
// what only real git can prove — that a checkout actually moves HEAD, that a
// remote-tracking-only commit really gets a tracking branch, and that a real
// dirty-tree refusal's full message reaches the alert.

test('right-click → Checkout switches to the row’s branch, with no prompt', async ({ page }) => {
  const repo = createRepoWithMerge()
  const { pane } = await openGitTreeOn(page, repo)
  const featureRow = pane.getByTestId('git-tree-row').filter({ hasText: 'on feature' })

  await featureRow.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Checkout' }).click()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toHaveText('feature')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('feature')
})

test('double-click does the same as choosing Checkout from the menu', async ({ page }) => {
  const repo = createRepoWithMerge()
  const { pane } = await openGitTreeOn(page, repo)
  const featureRow = pane.getByTestId('git-tree-row').filter({ hasText: 'on feature' })

  await featureRow.dblclick()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toHaveText('feature')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('feature')
})

test('several branches at one commit: a choose dialog names it; Cancel leaves HEAD untouched, picking one switches to it', async ({
  page
}) => {
  const repo = createRepoWithTwoBranchesAtOneCommit()
  const { pane } = await openGitTreeOn(page, repo)
  const sharedRow = pane.getByTestId('git-tree-row').filter({ hasText: 'shared tip' })

  await sharedRow.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Checkout' }).click()

  const dialog = page.getByTestId('git-tree-checkout-choose-dialog')
  await expect(dialog).toContainText('shared tip')
  const select = dialog.getByTestId('dialog-choose-select')
  // Deterministic, refname order — "main" before "stable".
  await expect(select).toHaveValue('main')

  await dialog.getByRole('button', { name: 'Cancel' }).click()
  await expect(dialog).toBeHidden()
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('main')

  await sharedRow.dblclick()
  const reopened = page.getByTestId('git-tree-checkout-choose-dialog')
  await reopened.getByTestId('dialog-choose-select').selectOption('stable')
  await reopened.getByRole('button', { name: 'Checkout' }).click()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toHaveText('stable')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('stable')
})

test('no branch at the commit: a detached-HEAD confirm names it; Cancel leaves HEAD untouched, confirming detaches', async ({
  page
}) => {
  const repo = createRepoWithMerge()
  const { pane } = await openGitTreeOn(page, repo)
  const rootRow = pane.getByTestId('git-tree-row').filter({ hasText: 'root commit' })

  await rootRow.dblclick()
  const dialog = page.getByTestId('git-tree-checkout-detach-dialog')
  await expect(dialog).toContainText('root commit')
  await expect(dialog).toContainText('detached')

  await dialog.getByRole('button', { name: 'Cancel' }).click()
  await expect(dialog).toBeHidden()
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('main')

  await rootRow.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Checkout' }).click()
  await page
    .getByTestId('git-tree-checkout-detach-dialog')
    .getByRole('button', { name: 'Checkout' })
    .click()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toContainText('detached at')
  // A detached HEAD has no symbolic ref to resolve.
  expect(() => gitOutput(repo, ['symbolic-ref', '-q', 'HEAD'])).toThrow()
})

test('a commit reachable only through a remote-tracking ref checks out with no prompt, creating a real local tracking branch', async ({
  page
}) => {
  const repo = createRepoWithBranches()
  const { pane } = await openGitTreeOn(page, repo)
  const remoteRow = pane.getByTestId('git-tree-row').filter({ hasText: 'on remote-only' })

  await remoteRow.dblclick()

  await expect(headerOfGitTree(pane).getByTestId('git-tree-head')).toHaveText('remote-only')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('remote-only')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'remote-only@{u}'])).toBe(
    'origin/remote-only'
  )
})

test('git’s own refusal reaches the user in full, and leaves the repo untouched', async ({
  page
}) => {
  const repo = createRepoForConflictingCheckout()
  writeFileSync(join(repo, 'conflict.txt'), 'uncommitted local edit\n')
  const { pane } = await openGitTreeOn(page, repo)
  const featureRow = pane.getByTestId('git-tree-row').filter({ hasText: 'on feature' })

  await featureRow.dblclick()

  const dialog = page.getByTestId('git-tree-checkout-failed-dialog')
  // The full multi-line stderr, not classify()'s one-line summary — the file
  // name and the "commit or stash" guidance would otherwise be lost.
  await expect(dialog).toContainText('conflict.txt')
  await expect(dialog).toContainText('Please commit your changes or stash them')
  await dialog.getByRole('button', { name: 'OK' }).click()

  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('main')
  expect(readFileSync(join(repo, 'conflict.txt'), 'utf8')).toBe('uncommitted local edit\n')
})

test('a second git tree pane on the same directory refreshes when the first one checks out', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  await openGitTreeOn(page, repo)
  // Splitting a git-tree pane creates another git-tree pane on the exact same
  // directory: createContentLike clones the origin's own type, and this
  // type's deriveConfig inherits cwd from its origin's exposeCwd — which for
  // a git-tree origin is simply its own configured directory.
  await clickMenuItem(electronApp, 'New Horizontal Split', page)

  const panes = page.getByTestId('git-tree')
  await expect(panes).toHaveCount(2)

  const featureRow = panes.nth(0).getByTestId('git-tree-row').filter({ hasText: 'on feature' })
  await featureRow.click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Checkout' }).click()

  await expect(headerOfGitTree(panes.nth(0)).getByTestId('git-tree-head')).toHaveText('feature')
  await expect(headerOfGitTree(panes.nth(1)).getByTestId('git-tree-head')).toHaveText('feature')
  expect(gitOutput(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).toBe('feature')
})
