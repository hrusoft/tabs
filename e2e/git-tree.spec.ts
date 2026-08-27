import { homedir } from 'node:os'
import { basename } from 'node:path'
import type { Locator, Page } from '@playwright/test'
import {
  createEmptyRepo,
  createPlainDirectory,
  createRepoWithMerge,
  removeTestRepos
} from './helpers/gitRepo'
import { expect, test, withApp } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import {
  clickPaneRoot,
  closeInactiveRootTab,
  closePane,
  initialPane,
  openNewGitTree
} from './helpers/pane'
import { openSettingsTab } from './helpers/settings'
import { alive, openTerminal, typeAndEnter } from './helpers/terminal'

/**
 * The git tree pane against real repositories.
 *
 * This tier owns exactly what only it can answer: that the app's own `git`
 * invocations produce the graph they claim to, across the commit shapes that
 * behave differently (a merge, a root commit, a binary-free numstat), and that
 * a directory survives a relaunch. What the rows *say*, how the selection
 * moves and how each failure reads are renderer questions and live in
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

/** Points an open pane at `dir` through its path bar — the real control, and the one a picker only fills in. */
async function pointAt(pane: Locator, dir: string): Promise<void> {
  await pane.getByTestId('git-tree-path-input').fill(dir)
  await pane.getByTestId('git-tree-path-input').press('Enter')
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
  await expect(pane.getByTestId('git-tree-path-input')).not.toHaveValue('')
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

  await expect(pane.getByTestId('git-tree-head')).toHaveText('main')
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

  await pane.getByTestId('git-tree-browse-button').click()

  await expect(pane.getByTestId('git-tree-path-input')).toHaveValue(repo)
  await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
})

/**
 * Commits an empty change into `repo` from a real shell, opened as a new tab
 * alongside `pane`'s own git tree content (the same root-button path the
 * cross-type inheritance tests below use) and left open — closing it would
 * collapse the two-tab group back down to a lone tab (`withTabRemoved` in
 * tree.ts), which remounts the surviving content and would refetch on its
 * own, confounding what these tests mean to isolate. Returns the terminal's
 * pid so the caller can close it, and its own commitment to closing it,
 * after every assertion that cares about the *not-yet-collapsed* shape.
 */
async function commitBehindItsBack(page: Page, pane: Locator, repo: string): Promise<number> {
  await clickPaneRoot(pane, 'pane-new-terminal-button')
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
  // content locator, which is scoped inside it) is what the header button
  // acts on.
  const pid = await commitBehindItsBack(page, initialPane(page), repo)
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

  const pid = await commitBehindItsBack(page, initialPane(page), repo)

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

test('...and does not, with the setting at its off-by-default value', async ({
  page,
  electronApp
}) => {
  const repo = createRepoWithMerge()
  const gitTree = await openGitTree(page)
  await pointAt(gitTree, repo)
  await expect(gitTree.getByTestId('git-tree-row')).toHaveCount(4)

  const pid = await commitBehindItsBack(page, initialPane(page), repo)
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

  await openNewGitTree(initialPane(page))

  const pane = page.getByTestId('git-tree')
  await expect(pane).toBeVisible()
  await expect(pane.getByTestId('git-tree-path-input')).toHaveValue(repo)
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

  await clickPaneRoot(initialPane(page), 'pane-new-terminal-button')

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

  await clickPaneRoot(initialPane(page), 'pane-new-terminal-button')

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
 * The directory is the pane's whole subject, so it has to persist — self
 * launched, because a relaunch is the subject.
 */
test('the repository a pane is reading survives a relaunch', async ({ userDataDir }) => {
  const repo = createRepoWithMerge()

  await withApp(userDataDir, async (_app, page1) => {
    const pane = await openGitTree(page1)
    await pointAt(pane, repo)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
  })

  await withApp(userDataDir, async (_app, page2) => {
    const pane = page2.getByTestId('git-tree')
    await expect(pane).toBeVisible()
    // Restored pointing at the same repository, not back at the default one.
    await expect(pane.getByTestId('git-tree-path-input')).toHaveValue(repo)
    await expect(pane.getByTestId('git-tree-row')).toHaveCount(4)
  })
})
