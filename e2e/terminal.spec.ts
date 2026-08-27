import { mkdtempSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import path from 'node:path'
import type { Locator, Page } from '@playwright/test'
import type { ElectronApplication } from 'playwright'
import { REATTACH_GRACE_MS } from '../src/shared/reattach'
import { grabAndHover } from './helpers/drag'
import { type Box, centerOf, requireBox } from './helpers/geometry'
import { expect, test, withApp } from './helpers/launch'
import { clickMenuItem } from './helpers/menu'
import { clickPaneRoot, closePane, initialPane, openNewTab, splitHorizontal } from './helpers/pane'
import { openSettingsTab } from './helpers/settings'
import { alive, openTerminal, terminalWithPid, typeAndEnter } from './helpers/terminal'

/** Polls `process.kill(pid, 0)` from this (test-runner) process directly. */
function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

test('opening a terminal drops into a real, interactive login shell', async ({ page }) => {
  const term = await openTerminal(initialPane(page))

  await typeAndEnter(term, 'echo hello-from-terminal')
  await expect(term).toContainText('hello-from-terminal')

  // A bare/non-login spawn wouldn't have $HOME sourced from the real user
  // environment the same way; assert the shell's actual $HOME matches this
  // machine's, proving real shell-config/environment sourcing occurred.
  await typeAndEnter(term, 'echo $HOME')
  await expect(term).toContainText(homedir())
})

/**
 * The terminal pane's stylesheet lives with its renderer
 * (src/plugins/terminal/renderer/terminal.css), not in global.css, so only a window that
 * renders terminals loads it.
 *
 * The .xterm-viewport assertion is the one that earns its keep. xterm.css
 * hardcodes that background to #000, and the override exists so the strip past
 * the last row/column shows the pane's configured background instead of black
 * (see CLAUDE.md). It is the only moved rule that competes with a foreign
 * stylesheet, and it wins on specificity rather than order — so this is what
 * catches a bundler ever ordering these two chunks the other way round.
 */
test('the pane window loads the terminal pane stylesheet, over xterm.css', async ({ page }) => {
  const term = await openTerminal(initialPane(page))

  await expect(term).toHaveCSS('padding', '4px 0px 0px 8px')
  // rgba(0, 0, 0, 0) is transparent — i.e. not xterm.css's #000.
  await expect(term.locator('.xterm-viewport')).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
})

test('a terminal pane advertises truecolor and its own identity to the programs it runs', async ({
  page
}) => {
  const term = await openTerminal(initialPane(page))

  // TERM and COLORTERM are what chalk/supports-color/Ink read to choose a
  // colour depth, and a program that reads "16 colours" quantises its own
  // 24-bit escapes before xterm.js ever sees them — unrecoverable downstream.
  // TERM_PROGRAM names the embedding terminal; programs key real behavior
  // off it (Claude Code picks its notification channel from it), and a dev
  // launch from another terminal would otherwise leak *that* terminal's
  // identity into every pane. Asserted through the real shell rather than
  // against the spawn options because that's where each can silently go
  // wrong: node-pty derives TERM from its `name` option (overwriting the
  // inherited one), COLORTERM isn't inherited at all by a Finder-launched
  // GUI app, and TERM_PROGRAM is inherited exactly when it shouldn't be. The
  // echoed command line carries the variables unexpanded, so only real shell
  // output can match.
  await typeAndEnter(term, 'echo "colour:$TERM:$COLORTERM:$TERM_PROGRAM"')
  await expect(term).toContainText('colour:xterm-256color:truecolor:Tabs')

  await closePane(initialPane(page))
})

test('a live OSC title escape sequence updates the pane header', async ({ page }) => {
  const header = page.getByTestId('pane-header')
  const term = await openTerminal(initialPane(page))

  // The trailing sleep holds this title in place — some shell configs
  // (prompt themes, PROMPT_COMMAND hooks) emit their own OSC title on every
  // new prompt, which would otherwise immediately overwrite this one the
  // instant the command finishes and the shell redraws its prompt.
  await typeAndEnter(term, "printf '\\033]0;live-title\\007'; sleep 5")

  await expect(header).toContainText('live-title')
})

/**
 * Parses the last `stty size` ("rows cols") output line out of the
 * terminal's rendered text. Anchored to a whole line so it can't
 * accidentally match unrelated digit pairs elsewhere on screen (e.g. a
 * shell-startup banner's date/time text).
 */
function lastSttySizeCols(text: string): number | null {
  const matches = [...text.matchAll(/^(\d+) (\d+)$/gm)]
  const last = matches.at(-1)
  return last ? Number(last[2]) : null
}

test('resizing the pane resizes the pty (verified via a real tty size query)', async ({ page }) => {
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')

  await typeAndEnter(term, 'stty size')
  await expect.poll(async () => lastSttySizeCols(await term.innerText())).not.toBeNull()
  const colsBefore = lastSttySizeCols(await term.innerText())
  if (colsBefore === null) throw new Error('could not read stty size output')

  // Halving the window's width forces the pty to a narrower column count —
  // real pty dimensions, not just the visual xterm.js element's CSS size.
  // The split also duplicates the terminal into the new pane, so scope back
  // to the original process by pid once there are two on screen.
  await splitHorizontal(initialPane(page))
  // give the ResizeObserver a moment to fire and the resize IPC round-trip to land.
  await page.waitForTimeout(300)

  const original = terminalWithPid(page, pid)
  await typeAndEnter(original, 'stty size')
  await expect
    .poll(async () => lastSttySizeCols(await original.innerText()))
    .toBeLessThan(colsBefore)
})

test('switching tabs away and back never resizes the pty', async ({ page, electronApp }) => {
  // Regression test: hiding a tab (display:none) used to make the
  // ResizeObserver→fit() path misread the unlaid-out container as a ~100px
  // box and squeeze the terminal — and the pty via SIGWINCH — to ~11×6,
  // letting any running TUI mangle its own screen while hidden. A WINCH
  // trap in the real shell records every pty resize as a WINCHED line.
  const term = await openTerminal(initialPane(page))
  const pid = await term.getAttribute('data-pty-pid')
  const original = terminalWithPid(page, pid)

  // Group the terminal into tabs first and let the resulting legitimate
  // resize land (the tab bar shrinks the pane), so the trap below observes
  // pure tab *switching* only.
  await openNewTab(initialPane(page))
  // Wait for the new tab to actually commit before clicking back: the click's
  // own locator (`first()`) resolves fine against the *old* one-tab DOM, so
  // Playwright's auto-waiting can't save it — a click landing in the gap
  // before React commits the new tab is processed against stale props and
  // its activation is lost to the new terminal's own mount/focus, leaving
  // the wrong tab active. Measured, not theoretical: without this the click
  // raced the commit and lost on most runs.
  await expect(page.locator('[role="tab"]')).toHaveCount(2)
  await page.locator('[role="tab"]').first().click()
  await page.waitForTimeout(300)
  await typeAndEnter(original, "trap 'echo WINCHED $(stty size)' WINCH")

  // Hide the terminal behind the other tab, then come back to it.
  await page.locator('[role="tab"]').nth(1).click()
  await page.waitForTimeout(300)
  await page.locator('[role="tab"]').first().click()
  await page.waitForTimeout(300)

  // A no-op command flushes trap output shells defer until the next prompt.
  // Match "WINCHED <rows>" rather than the bare marker: the echoed trap
  // command itself is on screen and contains the word.
  await typeAndEnter(original, ':')
  await expect(original).not.toContainText(/WINCHED \d/)

  // Prove the detector actually works in this environment: a real window
  // resize must reach the shell as SIGWINCH and print a WINCHED line.
  await electronApp.evaluate(({ BrowserWindow }) => {
    const win = BrowserWindow.getAllWindows()[0]!
    const [width, height] = win.getSize()
    win.setSize(width! - 160, height!)
  })
  await expect(original).toContainText(/WINCHED \d/)
})

test("closing a terminal's tab kills the underlying process", async ({ page, electronApp }) => {
  // Root's own tab bar is always there (see ensureTabsRoot in tree.ts) — no
  // need to manufacture one: closing its own (only) tab is a real tab close.
  const term = await openTerminal(initialPane(page))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  expect(pid).toBeGreaterThan(0)

  await expect.poll(() => alive(electronApp, pid)).toBe(true)

  await page.getByRole('tab', { name: 'Tabs' }).getByLabel('Close Tabs').click()
  await expect(page.getByTestId('terminal')).toHaveCount(0)

  // Disposal is debounced (see terminalRegistry.ts) to survive drag-and-drop
  // moves without restarting the shell; a real close has no follow-up mount,
  // so it should still actually die shortly after.
  await expect.poll(() => alive(electronApp, pid), { timeout: 3000 }).toBe(false)
})

test('moving a terminal tab to another pane keeps its process alive (reattach, not restart)', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  await openNewTab(panes.nth(1))

  // Root's own wrapper stays pane 0; converting pane 1 inserted its tab's
  // content pane at index 2, pushing the second split pane to index 3.
  const term = await openTerminal(panes.nth(2))
  const pidBefore = await term.getAttribute('data-pty-pid')

  // Content on screen before the drag, to prove the remount it triggers
  // doesn't wipe the visible xterm.js buffer, not just the process.
  await typeAndEnter(term, 'echo before-move-marker')
  await expect(term).toContainText('before-move-marker')

  await openNewTab(panes.nth(3))

  // Root's own tablist (0) is untouched; the two nested groups created above
  // are the source and destination for the drag.
  const sourceTab = page.getByRole('tablist').nth(1).getByRole('tab').nth(0)
  const targetTab = page.getByRole('tablist').nth(2).getByRole('tab').nth(0)
  const to = await requireBox(targetTab)

  await grabAndHover(sourceTab, to.x + to.width * 0.75, to.y + to.height / 2)
  await page.mouse.up()

  // The move remounts the terminal's component, reattaching to the same
  // underlying pid and reusing the same xterm.js instance — its scrollback
  // from before the move should still be visible, not a blank reattached view.
  const movedTerm = page.getByTestId('terminal')
  await expect(movedTerm).toHaveAttribute('data-pty-pid', pidBefore ?? '')
  await expect(movedTerm).toContainText('before-move-marker')

  expect(await alive(electronApp, Number(pidBefore))).toBe(true)
})

test('quitting the app kills every remaining terminal process, not just closed ones', async ({
  userDataDir
}) => {
  // Launches its own app rather than taking the shared one: quitting is this
  // test's subject, and the rest of the file expects the shared app to still
  // be running afterwards so it can be reset (see helpers/launch.ts).
  const pid = await withApp(userDataDir, async (_app, page) => {
    const term = await openTerminal(initialPane(page))
    const shellPid = Number(await term.getAttribute('data-pty-pid'))
    expect(isAlive(shellPid)).toBe(true)

    // Quit without closing the tab first: main/index.ts's `before-quit` handler
    // is what must dispose it, not the tab-close path exercised elsewhere —
    // the close withApp performs on the way out is that quit.
    return shellPid
  })

  await expect.poll(() => isAlive(pid), { timeout: 3000 }).toBe(false)
})

test('opening a new tab on a live terminal promotes it into a group without killing it', async ({
  page,
  electronApp
}) => {
  // A split child has no tab-group parent of its own, unlike root's own tab
  // content — that's what still exercises the "wrap into a fresh group" path
  // in openContent (tree.ts) rather than adding a sibling tab to root.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  const term = await openTerminal(panes.nth(1))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  expect(pid).toBeGreaterThan(0)

  // Content on screen before the promotion, to prove the remount it triggers
  // doesn't wipe the visible xterm.js buffer, not just the process.
  await typeAndEnter(term, 'echo before-promote-marker')
  await expect(term).toContainText('before-promote-marker')

  // Root's own tablist, plus the split with no tab bar of its own yet.
  await expect(page.getByRole('tablist')).toHaveCount(1)

  await openNewTab(panes.nth(1))

  // It became tab 1 of a new, nested group, titled for what it holds, with a
  // fresh terminal — mirroring the origin's type — opened beside it and
  // taking focus.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const tabs = page.getByRole('tablist').nth(1).getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await expect(page.getByRole('tab', { name: 'Terminal' })).toHaveCount(2)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')

  // Same process: promotion relocates the original node, it doesn't replace
  // it — scope back to it by pid now that a second terminal exists too.
  const original = terminalWithPid(page, pid)
  await expect(original).toHaveCount(1)

  // The new tab's terminal is a distinct, independently live shell.
  const promoted = page.getByTestId('terminal').nth(1)
  await expect(promoted).toHaveAttribute('data-pty-pid', /^\d+$/)
  const promotedPid = Number(await promoted.getAttribute('data-pty-pid'))
  expect(promotedPid).not.toBe(pid)

  // Promotion remounts the terminal, scheduling a disposal that the remount
  // must cancel. Outliving REATTACH_GRACE_MS (reattachRegistry.ts) is what
  // makes this a real check rather than a vacuous one.
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, pid)).toBe(true)

  // Still a working session, not merely a live pid — and the scrollback from
  // before the promotion is still visible, not a blank reattached view.
  await tabs.nth(0).click()
  await expect(original).toBeVisible()
  await expect(original).toContainText('before-promote-marker')
  await typeAndEnter(original, 'echo survived-the-promote')
  await expect(original).toContainText('survived-the-promote')
})

test('closing the tab beside a promoted terminal collapses it back to a bare pane without killing it', async ({
  page,
  electronApp
}) => {
  // A split child, not root's own tab content — closing the second tab of a
  // *nested* group collapses the group away entirely (normalizeTabs in
  // tree.ts); root's own tablist never can, per the ensureTabsRoot invariant.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  const term = await openTerminal(panes.nth(1))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  expect(pid).toBeGreaterThan(0)

  await openNewTab(panes.nth(1))
  // Root's own tablist, plus the new nested one just created.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const tabs = page.getByRole('tablist').nth(1).getByRole('tab')
  await expect(tabs).toHaveCount(2)

  // Scope back to the original terminal by pid now that the new tab beside
  // it holds a second, independent one (same type as the origin).
  const original = terminalWithPid(page, pid)
  const second = page.getByTestId('terminal').nth(1)
  const secondPid = Number(await second.getAttribute('data-pty-pid'))

  // Content on screen before the collapse, to prove the remount it triggers
  // doesn't wipe the visible xterm.js buffer, not just the process.
  await tabs.nth(0).click()
  await typeAndEnter(original, 'echo before-collapse-marker')
  await expect(original).toContainText('before-collapse-marker')

  // Close the second tab, leaving the original terminal as the group's only tab.
  await tabs.nth(1).getByLabel('Close Terminal').click()

  // The mirror of the promotion above: the nested group's slot is replaced by
  // the terminal's own content directly, so its tab bar is gone — root's own
  // tablist is all that's left.
  await expect(page.getByRole('tablist')).toHaveCount(1)
  await expect(original).toHaveAttribute('data-pty-pid', String(pid))

  // Collapsing remounts the terminal (same as promotion did), scheduling a
  // disposal that the remount must cancel; outliving REATTACH_GRACE_MS
  // (reattachRegistry.ts) is what makes this a real check rather than a
  // vacuous one.
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, pid)).toBe(true)
  // The closed tab's own terminal process is cleaned up too, not orphaned.
  await expect.poll(() => isAlive(secondPid), { timeout: 3000 }).toBe(false)

  // Still a working session, not merely a live pid — and the scrollback from
  // before the collapse is still visible, not a blank reattached view.
  await expect(original).toBeVisible()
  await expect(original).toContainText('before-collapse-marker')
  await typeAndEnter(original, 'echo survived-the-collapse')
  await expect(original).toContainText('survived-the-collapse')
})

test("splitting a sibling pane doesn't wipe an unrelated terminal's scrollback", async ({
  page
}) => {
  // Two empty panes in one horizontal split.
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')

  // A terminal lives in the first pane, untouched by anything that happens
  // to its sibling below.
  const term = await openTerminal(panes.nth(1))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  expect(pid).toBeGreaterThan(0)
  await typeAndEnter(term, 'echo before-sibling-split-marker')
  await expect(term).toContainText('before-sibling-split-marker')

  // Splitting the *other* pane in the same direction splices a third child
  // into the shared split (see splitContent in tree.ts) rather than nesting
  // a new one — SplitRenderer keys its <Group> on the join of every child id,
  // so this changes that key and remounts every pane in the split, including
  // the untouched terminal's.
  await splitHorizontal(panes.nth(2))
  // Root's own wrapper, plus the split's now-three children.
  await expect(panes).toHaveCount(4)

  await expect(term).toHaveAttribute('data-pty-pid', String(pid))
  await expect(term).toContainText('before-sibling-split-marker')
  expect(isAlive(pid)).toBe(true)
})

test('opening a terminal on a live terminal gives two tabs running two shells', async ({
  page
}) => {
  const first = await openTerminal(initialPane(page))
  const firstPid = Number(await first.getAttribute('data-pty-pid'))

  await clickPaneRoot(initialPane(page), 'pane-new-terminal-button')

  const terms = page.getByTestId('terminal')
  await expect(terms).toHaveCount(2)
  // Root's own original tab keeps the title it was created with ("Tabs") —
  // replacing its content in place never retitles it (see openContent's
  // empty-target branch in tree.ts) — so only the new sibling tab reads
  // "Terminal".
  await expect(page.getByRole('tab', { name: 'Terminal' })).toHaveCount(1)
  await expect(terms.nth(1)).toHaveAttribute('data-pty-pid', /^\d+$/)

  // Two distinct shells, both alive: the first was moved aside, not reused
  // and not killed.
  const secondPid = Number(await terms.nth(1).getAttribute('data-pty-pid'))
  expect(secondPid).not.toBe(firstPid)
  expect(isAlive(firstPid)).toBe(true)
  expect(isAlive(secondPid)).toBe(true)
})

test('switching away from a terminal tab and back keeps the same live session, not a fresh one', async ({
  page
}) => {
  // Root's own new-tab button adds a sibling tab directly and activates it
  // (addTab in tree.ts), hiding root's original (empty) tab — so the
  // terminal opens straight into the new, currently-visible one. Switching
  // back to the original tab is the "just hide it" path, not a structural
  // close/move.
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  const term = await openTerminal(panes.nth(2))
  const pid = await term.getAttribute('data-pty-pid')

  await typeAndEnter(term, 'echo before-switch-marker')
  await expect(term).toContainText('before-switch-marker')
  // A background job whose output only lands after we've switched away —
  // proving output isn't missed while the tab is inactive (hidden, not torn
  // down and its data subscription severed).
  await typeAndEnter(term, '(sleep 1; echo output-while-away) &')

  const pidStr = pid ?? ''
  const original = terminalWithPid(page, pidStr)
  const tabs = page.getByRole('tablist').getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await expect(page.getByTestId('terminal')).toHaveCount(1)

  // Switch to root's original (empty) tab, hiding the terminal's.
  await tabs.first().click()
  await expect(original).not.toBeVisible()

  await page.waitForTimeout(1500)

  await tabs.last().click()
  await expect(original).toBeVisible()

  // Same OS process the whole time — no restart.
  await expect(original).toHaveAttribute('data-pty-pid', pidStr)
  expect(isAlive(Number(pid))).toBe(true)
  await expect(original).toContainText('before-switch-marker')
  await expect(original).toContainText('output-while-away')
})

test("splitting a terminal starts the new terminal in the origin's live cwd (inheritance on by default)", async ({
  page
}) => {
  const term = await openTerminal(initialPane(page))
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-cwd-'))

  await typeAndEnter(term, `cd ${dir}`)

  await splitHorizontal(initialPane(page))
  const newTerm = page.getByTestId('terminal').nth(1)
  await expect(newTerm).toHaveAttribute('data-pty-pid', /^\d+$/)
  await typeAndEnter(newTerm, 'pwd')
  await expect(newTerm).toContainText(dir)

  rmSync(dir, { recursive: true, force: true })
})

test("opening a new tab from a terminal starts the new terminal in the origin's live cwd", async ({
  page
}) => {
  const term = await openTerminal(initialPane(page))
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-cwd-'))

  await typeAndEnter(term, `cd ${dir}`)

  await openNewTab(initialPane(page))
  const newTerm = page.getByTestId('terminal').nth(1)
  await expect(newTerm).toHaveAttribute('data-pty-pid', /^\d+$/)
  await typeAndEnter(newTerm, 'pwd')
  await expect(newTerm).toContainText(dir)

  rmSync(dir, { recursive: true, force: true })
})

test("disabling cwd inheritance in settings keeps a new split at the terminal's default directory", async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await settingsPage.getByTestId('settings-inherit-cwd-checkbox').uncheck()

  const term = await openTerminal(initialPane(page))
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-cwd-'))
  await typeAndEnter(term, `cd ${dir}`)

  await splitHorizontal(initialPane(page))
  const newTerm = page.getByTestId('terminal').nth(1)
  await expect(newTerm).toHaveAttribute('data-pty-pid', /^\d+$/)
  await typeAndEnter(newTerm, 'pwd')
  await expect(newTerm).toContainText(homedir())
  await expect(newTerm).not.toContainText(dir)

  rmSync(dir, { recursive: true, force: true })
})

/**
 * @xterm/addon-webgl's canvas carries no distinguishing class or attribute
 * (unlike the DOM renderer's `.xterm-link-layer` canvas), so the only
 * reliable way to detect it is to check which canvas already holds a live
 * webgl2 rendering context — a canvas's context type is fixed for its
 * lifetime, so this doesn't disturb whichever renderer is actually active.
 */
function hasWebglCanvas(terminal: Locator): Promise<boolean> {
  return terminal.evaluate((el) =>
    Array.from(el.querySelectorAll('canvas')).some((canvas) => canvas.getContext('webgl2') !== null)
  )
}

test('enabling WebGL rendering in settings renders the terminal onto a WebGL canvas', async ({
  page,
  electronApp
}) => {
  const defaultTerm = await openTerminal(initialPane(page))
  expect(await hasWebglCanvas(defaultTerm)).toBe(false)

  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await settingsPage.getByTestId('settings-webgl-rendering-checkbox').check()

  await openNewTab(initialPane(page))
  const newTerm = page.getByTestId('terminal').nth(1)
  await expect(newTerm).toHaveAttribute('data-pty-pid', /^\d+$/)
  await expect.poll(() => hasWebglCanvas(newTerm)).toBe(true)
})

test('lowering scrollback to zero in settings blocks scrolling on an already-open terminal live', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  // Comfortably more than a screenful, so there's real scrollback to scroll
  // into and not merely a screen to wipe (same margin as the Clear Buffer
  // test below).
  await typeAndEnter(term, "printf 'filler-%s\\n' $(seq 1 400)")
  await expect(term).toContainText('filler-400')

  // With the 1000-line default, scrolling up moves the newest line off
  // screen — there's real history above the current view.
  await scrollUp(term)
  await expect(term).not.toContainText('filler-400')

  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')
  await settingsPage.getByTestId('settings-terminal-scrollback-input').fill('0')

  // Back to the bottom, then try to scroll up again.
  await scrollDown(term)
  await expect(term).toContainText('filler-400')
  await scrollUp(term)

  // Applied live, with no need to reopen the pane (see TerminalRenderer's
  // scrollback effect) — 0 disables scrollback entirely, so there's nothing
  // above the current screen to scroll into and the newest line never
  // leaves view this time, unlike the first scroll above.
  await expect(term).toContainText('filler-400')
})

/**
 * Replaces main's `shell.openExternal` with a recorder, so a link click can be
 * asserted without actually launching a browser on the machine running the
 * suite. Works because openExternalUrl (src/main/openExternal.ts) looks the method up
 * on the `shell` object at call time rather than capturing it.
 */
async function recordOpenExternal(electronApp: ElectronApplication): Promise<void> {
  await electronApp.evaluate(({ shell }) => {
    const opened: string[] = []
    ;(globalThis as unknown as { openedUrls: string[] }).openedUrls = opened
    shell.openExternal = async (url: string): Promise<void> => {
      opened.push(url)
    }
  })
}

function openedUrls(electronApp: ElectronApplication): Promise<string[]> {
  return electronApp.evaluate(() => (globalThis as unknown as { openedUrls: string[] }).openedUrls)
}

/**
 * Bounding box of the *last* rendered span containing `text`. Last, because
 * the command that printed a URL usually contains that same URL itself — the
 * echoed command line is above its own output on screen.
 */
async function lastSpanBox(term: Locator, text: string): Promise<Box> {
  const box = await term.evaluate((el, needle) => {
    const span = Array.from(el.querySelectorAll('.xterm-rows span'))
      .reverse()
      .find((candidate) => candidate.textContent?.includes(needle))
    if (!span) return null
    const { x, y, width, height } = span.getBoundingClientRect()
    return { x, y, width, height }
  }, text)
  if (!box) throw new Error(`no rendered span containing ${JSON.stringify(text)}`)
  return box
}

/**
 * Clicks the on-screen `text` of a link, optionally with Cmd/Meta held.
 *
 * xterm resolves what's under the cursor asynchronously — the link providers
 * reply on their own schedule after the mousemove — so the click has to wait
 * for the screen element to pick up `xterm-cursor-pointer`, which is xterm's
 * own signal that it now has a link under the pointer. Clicking earlier lands
 * on plain text.
 */
async function clickLinkText(
  page: Page,
  term: Locator,
  text: string,
  options: { modifier: boolean }
): Promise<void> {
  const box = await lastSpanBox(term, text)
  if (options.modifier) await page.keyboard.down('Meta')
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await expect(term.locator('.xterm-screen')).toHaveClass(/xterm-cursor-pointer/)
  await page.mouse.down()
  await page.mouse.up()
  if (options.modifier) await page.keyboard.up('Meta')
}

test('Cmd-clicking a link in a terminal opens it in the OS browser, with no dialog', async ({
  page,
  electronApp
}) => {
  await recordOpenExternal(electronApp)
  // xterm's built-in fallback for an unset linkHandler is a renderer-side
  // confirm() ("Do you want to navigate to ...?") that opens nothing. That's
  // the bug this test exists for, and Playwright can see renderer dialogs
  // (unlike the native ones E2E_HIDDEN suppresses), so record any that fire.
  const dialogs: string[] = []
  page.on('dialog', (dialog) => {
    dialogs.push(dialog.message())
    void dialog.dismiss()
  })

  const term = await openTerminal(initialPane(page))

  // A plain-text URL printed by an ordinary command (@xterm/addon-web-links).
  await typeAndEnter(term, 'echo https://example.com/plain')
  await expect(term).toContainText('https://example.com/plain')
  await clickLinkText(page, term, 'https://example.com/plain', { modifier: true })
  await expect.poll(() => openedUrls(electronApp)).toEqual(['https://example.com/plain'])

  // An OSC 8 hyperlink, where the visible text and the target differ — this
  // is the kind tools like gh and eza emit, and xterm core's own provider.
  await typeAndEnter(
    term,
    "printf '\\033]8;;https://example.com/osc\\033\\\\osc-link-text\\033]8;;\\033\\\\\\n'"
  )
  await expect(term).toContainText('osc-link-text')
  await clickLinkText(page, term, 'osc-link-text', { modifier: true })
  await expect
    .poll(() => openedUrls(electronApp))
    .toEqual(['https://example.com/plain', 'https://example.com/osc'])

  expect(dialogs).toEqual([])

  await closePane(initialPane(page))
})

/**
 * Scrolls `term` up into its scrollback. Only the visible screen is ever in
 * the DOM — and xterm 6 drives its viewport through its own scrollable element
 * rather than native overflow, so there's no scrollHeight to read either — so
 * "is there anything above the screen" can only be asked by scrolling up and
 * looking at what comes into view.
 */
function scrollUp(term: Locator): Promise<void> {
  return wheelOver(term, -100_000)
}

/** The other direction — back down to the live bottom of the screen. */
function scrollDown(term: Locator): Promise<void> {
  return wheelOver(term, 100_000)
}

async function wheelOver(term: Locator, deltaY: number): Promise<void> {
  const page = term.page()
  const { x, y } = centerOf(await requireBox(term))
  await page.mouse.move(x, y)
  await page.mouse.wheel(0, deltaY)
}

test('Cmd/Ctrl+K clears the terminal, scrollback included', async ({ page, electronApp }) => {
  const term = await openTerminal(initialPane(page))

  // Comfortably more than a screenful, so there's real scrollback to lose and
  // not merely a screen to wipe.
  await typeAndEnter(term, "printf 'filler-%s\\n' $(seq 1 200)")
  await expect(term).toContainText('filler-200')

  // Scrolling up reaches older output: the newest line leaves the screen.
  await scrollUp(term)
  await expect(term).not.toContainText('filler-200')
  await expect(term).toContainText('filler-')

  await clickMenuItem(electronApp, 'Clear Buffer', page)

  // The buffer collapses to the prompt line xterm's clear() keeps as its new
  // first line, so the screen goes empty even though it was scrolled up a
  // moment ago — and scrolling up now reaches nothing, which is the half a
  // shell-level `clear` doesn't do. (A screen-only clear passes the first
  // assertion and fails the second.)
  await expect(term).not.toContainText('filler-')
  await scrollUp(term)
  await expect(term).not.toContainText('filler-')

  await closePane(initialPane(page))
})

test('Cmd/Ctrl+K leaves a full-screen TUI on the alternate buffer alone', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))

  // Switches to the alternate buffer and paints it, the way vim/htop/less do
  // — driven by the escape sequence directly rather than by launching one, so
  // the test doesn't depend on which pager is installed or on the developer's
  // own $LESS (`-X` would keep it on the normal buffer entirely).
  await typeAndEnter(term, "printf '\\033[?1049h'; echo alt-screen-content")
  await expect(term).toContainText('alt-screen-content')

  await clickMenuItem(electronApp, 'Clear Buffer', page)

  // Round-trips through the shell before re-checking, so a clear that did
  // fire has had every chance to land — the screen still holds what the
  // "TUI" drew, because collapsing the alternate buffer under a program
  // that believes it owns the screen leaves it half-painted until it
  // repaints.
  await typeAndEnter(term, 'echo after-clear-attempt')
  await expect(term).toContainText('after-clear-attempt')
  await expect(term).toContainText('alt-screen-content')

  await typeAndEnter(term, "printf '\\033[?1049l'")
  await closePane(initialPane(page))
})

test('clicking a terminal link without the modifier held does not open anything', async ({
  page,
  electronApp
}) => {
  await recordOpenExternal(electronApp)
  const term = await openTerminal(initialPane(page))

  await typeAndEnter(term, 'echo https://example.com/plain')
  await expect(term).toContainText('https://example.com/plain')
  // A plain click is how a terminal pane gets focused — it must never launch
  // a browser just because a URL happened to be under the cursor.
  await clickLinkText(page, term, 'https://example.com/plain', { modifier: false })

  expect(await openedUrls(electronApp)).toEqual([])

  await closePane(initialPane(page))
})
