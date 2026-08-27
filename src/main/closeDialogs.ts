import { BrowserWindow, dialog, type WebContents } from 'electron'
import type { CloseBlocker } from './closeBlockers'
import { collectCloseBlockers, listQuitBlockersSync } from './closeBlockers'
import { e2eHidden } from './e2eHidden'

/**
 * The two "you would be destroying live work" confirmations — closing a
 * pane/tab, and quitting — as the pair they are.
 *
 * They ask the same question of the same registry (closeBlockers.ts collects;
 * this asks) and differ in exactly two ways: where the list of blockers comes
 * from, and whether the dialog can await — so the copy, the button set and
 * the E2E_HIDDEN suppression live here once.
 *
 * ## Why both are suppressed under E2E_HIDDEN
 *
 * A `dialog.showMessageBox` with no parent window renders on screen even
 * though the main window is never shown, and it is a native OS dialog —
 * Playwright drives a renderer over CDP and can neither see nor click one. So
 * an un-suppressed dialog does not fail a test, it *hangs* the worker until
 * its timeout: the quit path blocks shutdown, and the pane path blocks a
 * pending `ipcMain.handle` promise forever.
 *
 * That is not hypothetical. Every terminal a test opens is a real `$SHELL -l`
 * sourcing the developer's own dotfiles, so an async prompt segment or a
 * completion daemon can hold the tty's foreground process group for a moment
 * and trip the check exactly like a genuinely running command would. Same
 * class of suppression as the AppKit and CrashReporter prompts in
 * e2e/helpers/global-setup.ts, and CLAUDE.md's before-quit gotcha has the full
 * story. It is a backstop, not licence: a test that opens a terminal as
 * incidental setup should still close it (see e2e/helpers/terminal.ts).
 *
 * Both functions test the flag *before* collecting blockers, not alongside the
 * emptiness check. Collecting means one `ps` per live terminal — synchronously,
 * from inside `before-quit`, on the quit path — for an answer the flag then
 * discards; and that same handler already forks an `lsof` per terminal for the
 * cwd refresh, which is the fork count CLAUDE.md's shutdown-hang gotcha is
 * about. Skipping it is the cheaper *and* the safer order.
 */

/**
 * Lists what's still running so the user knows what they'd be killing, not
 * just that *something* is running.
 */
function runningProcessesCopy(running: CloseBlocker[]): { message: string; detail: string } {
  const message =
    running.length === 1
      ? 'A process is still running'
      : `${running.length} processes are still running`
  const list = running.map((r) => `• ${r.command ?? 'a process'}`).join('\n')
  const detail = `${list}\n\nClosing will end ${running.length === 1 ? 'it' : 'them'} immediately.`
  return { message, detail }
}

/** The shared shape: Cancel is both the default and the escape route, so a stray Return or Escape never destroys anything. */
function dialogOptions(running: CloseBlocker[], proceedLabel: string) {
  return {
    type: 'warning' as const,
    buttons: ['Cancel', proceedLabel],
    defaultId: 0,
    cancelId: 0,
    ...runningProcessesCopy(running)
  }
}

/**
 * Whether closing the panes holding `ids` may go ahead: true immediately when
 * nothing under them is doing live work, otherwise the user's answer.
 *
 * `sender` is the renderer that asked, so the dialog is parented to its window
 * — a sheet on the window being acted on rather than a free-floating alert.
 */
export async function confirmClosingPanes(ids: string[], sender: WebContents): Promise<boolean> {
  if (e2eHidden) return true
  const running = await collectCloseBlockers(ids)
  if (running.length === 0) return true
  const window = BrowserWindow.fromWebContents(sender)
  const options = dialogOptions(running, 'Close Anyway')
  try {
    const result = window
      ? await dialog.showMessageBox(window, options)
      : await dialog.showMessageBox(options)
    return result.response === 1
  } catch (error) {
    // A failed dialog must answer, not reject — the renderer awaits this over
    // IPC and treats a rejection as an unhandled one. Refusing the close is
    // the safe direction: don't destroy work the user couldn't be asked about.
    console.error('[tabs] close confirmation dialog failed; not closing:', error)
    return false
  }
}

/**
 * Whether quitting may go ahead. Synchronous throughout, and not by
 * preference: it runs inside `before-quit`, where the textbook
 * preventDefault + await + re-quit() pattern made shutdown hang and made the
 * *next* launch hang behind an invisible AppKit prompt. See CLAUDE.md's
 * before-quit gotcha before making anything on this path asynchronous.
 */
export function confirmQuitSync(): boolean {
  if (e2eHidden) return true
  const running = listQuitBlockersSync()
  if (running.length === 0) return true
  try {
    return dialog.showMessageBoxSync(dialogOptions(running, 'Quit Anyway')) === 1
  } catch (error) {
    // Every other statement on the before-quit path is individually quiet; a
    // throw here can reach node-addon-api's unsafe rethrow and abort the
    // process. A dialog that failed must never be able to block a quit.
    console.error('[tabs] quit confirmation dialog failed; quitting anyway:', error)
    return true
  }
}
