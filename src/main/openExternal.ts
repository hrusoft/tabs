import { shell } from 'electron'
import { isSafeExternalUrl } from '../shared/url'

/**
 * The single funnel from anywhere in the app to the OS's default handler.
 * Every URL that gets here is attacker-influenceable in principle — raw pty
 * output for a terminal link, page content for a webview popup — and
 * shell.openExternal would happily launch a `file:` path or a registered
 * custom scheme, so the protocol is checked first and a rejected URL is
 * silently dropped.
 *
 * The `catch` is not decoration: `shell.openExternal` returns a promise that
 * rejects when the OS can't open the URL, and an unhandled rejection in the
 * main process is fatal — the same native "A JavaScript error occurred in the
 * main process" modal the persistence writers guard against (see persist.ts).
 * Every caller here is fire-and-forget, so there is no one else to handle it.
 *
 * Its own module rather than a private helper in index.ts because content
 * modules need it too: the browser's guest popup policy routes through here
 * (see src/plugins/browser/main/index.ts), as do the host window's own
 * popups and the terminal's link-click IPC. A content module reaching into
 * index.ts would be the wrong direction entirely.
 */
export function openExternalUrl(url: string): void {
  if (!isSafeExternalUrl(url)) return
  shell.openExternal(url).catch((error) => {
    console.error('[tabs] failed to open a URL externally:', error)
  })
}
