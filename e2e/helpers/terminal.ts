import { expect, type Locator, type Page } from '@playwright/test'
import type { ElectronApplication } from 'playwright'
import { centerOf, requireBox } from './geometry'
import { clickPaneRoot } from './pane'

/**
 * Opens a terminal in `pane` via its own header controls, waiting until the
 * pty is genuinely up: create() resolves asynchronously over IPC (the pid
 * attribute lands once it does), and the real login shell's prompt landing
 * (vs. a blank pty) means it's safe to start typing.
 *
 * Close what you open: if the terminal is incidental setup (real content to
 * drag, focus, etc. — not the thing under test), close its pane/tab before
 * the test ends instead of leaving a live shell for the electronApp fixture's
 * `app.close()` to quit past. The shell is a real `$SHELL -l` sourcing your
 * actual dotfiles, so anything its startup does (an async prompt segment, a
 * completion daemon) can transiently look like a foreground process to
 * main/index.ts's before-quit check. E2E_HIDDEN auto-answers the resulting
 * native dialog as a backstop — it has no parent window, so it renders even
 * with the main window hidden, and Playwright can't click it — but don't
 * rely on that alone. The one deliberate exception is a test whose actual
 * subject IS a terminal surviving the quit/relaunch (terminal.spec.ts,
 * layout.spec.ts) — there, leaving it running is the point.
 */
export async function openTerminal(pane: Locator): Promise<Locator> {
  await clickPaneRoot(pane, 'pane-new-terminal-button')
  // Resolve the new terminal scoped to the pane it was opened in, so a
  // second/third terminal is unambiguous — then hand back a pid-anchored
  // locator, which keeps following this terminal across structural moves
  // (pane indices shift as splits collapse and tab groups form).
  const scoped = pane.getByTestId('terminal')
  await expect(scoped).toBeVisible()
  await expect(scoped).toHaveAttribute('data-pty-pid', /^\d+$/)
  const pid = await scoped.getAttribute('data-pty-pid')
  const term = terminalWithPid(pane.page(), pid ?? '')
  // Generous rather than tight: spec files run several at a time
  // (playwright.config.ts), and with that many Electron renderers competing
  // the prompt can take seconds to actually paint even though the shell
  // itself starts in well under a second. This resolves the moment the text
  // lands, so a quiet run pays nothing for the headroom — only a genuine
  // "the shell never came up" failure waits out the whole budget.
  await expect(term).toContainText('~', { timeout: 20_000 })
  return term
}

/** A pid-anchored terminal locator — keeps following one terminal across structural moves. Accepts null (getAttribute's shape); a null pid matches nothing. */
export function terminalWithPid(page: Page, pid: string | number | null): Locator {
  return page.locator(`[data-testid="terminal"][data-pty-pid="${pid}"]`)
}

/** Clicks into `term` to focus it, then types `text` and presses Enter. */
export async function typeAndEnter(term: Locator, text: string): Promise<void> {
  const page = term.page()
  const { x, y } = centerOf(await requireBox(term))
  await page.mouse.click(x, y)
  await page.keyboard.type(text)
  await page.keyboard.press('Enter')
}

/** Polls `process.kill(pid, 0)` inside the app's main process. */
export function alive(electronApp: ElectronApplication, pid: number): Promise<boolean> {
  return electronApp.evaluate((_electron, p) => {
    try {
      process.kill(p, 0)
      return true
    } catch {
      return false
    }
  }, pid)
}
