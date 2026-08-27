import type { WebContents } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { onRendererMessage } from './ipcListeners'
import { applyMenu } from './menu'
import { setShortcutCaptureOwner, shortcutCaptureOwner } from './shortcutCapture'

/**
 * Shortcut *capture* mode: while the Settings window is waiting for the user
 * to press a new combination, every customizable menu accelerator is stripped
 * off the application menu.
 *
 * This exists because of the ordering that makes native accelerators useful in
 * the first place: macOS matches a menu item's key equivalent before the
 * keystroke is delivered to any web contents, so a renderer keydown listener
 * can never see a combination the menu already claims. Without suspension the
 * recorder would be unable to observe ⌘T, ⌘W, ⌘K or ⌘, — precisely the
 * combinations a user is most likely to want to reassign — while happily
 * recording everything else, which reads as "the app ignores some keys".
 *
 * The state is a single arming webContents id rather than a boolean so it can
 * be released automatically when that window goes away: leaving capture armed
 * would leave the whole app with no accelerators at all, and the window that
 * could turn it back off no longer exists. The id itself lives in
 * shortcutCapture.ts — the one-value module that keeps menu.ts (which reads
 * it while building) and this file (which writes it, then rebuilds the menu)
 * from importing each other.
 */

/** webContents already wired for auto-release, so repeated arming can't stack listeners. */
const watched = new Set<number>()

function watchForDestroy(sender: WebContents): void {
  if (watched.has(sender.id)) return
  watched.add(sender.id)
  sender.once('destroyed', () => {
    watched.delete(sender.id)
    if (shortcutCaptureOwner() !== sender.id) return
    setShortcutCaptureOwner(null)
    applyMenu()
  })
}

/** Wires the renderer's arm/disarm messages. */
export function registerShortcutsIpc(): void {
  onRendererMessage(IpcChannel.shortcutsSetCapture, (event, active: boolean) => {
    const senderId = event.sender.id
    if (active) {
      if (shortcutCaptureOwner() === senderId) return
      setShortcutCaptureOwner(senderId)
      watchForDestroy(event.sender)
    } else {
      // Only the window that armed capture may disarm it, so a stale disarm
      // from a window that already lost the race can't unsuspend the menu
      // while another one is still recording.
      if (shortcutCaptureOwner() !== senderId) return
      setShortcutCaptureOwner(null)
    }
    applyMenu()
  })
}

/**
 * e2e only: releases capture and puts the menu back. Part of main/e2e.ts's
 * reset — capture mode is mutable main-process state, so without this a test
 * that failed mid-capture would leave every later test in the file running
 * against an accelerator-less menu.
 */
export function resetShortcutsForTests(): void {
  setShortcutCaptureOwner(null)
  applyMenu()
}
