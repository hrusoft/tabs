import type { WebContents } from 'electron'
import { browserMainCtx } from './pluginContext'

/**
 * The one way a guest wiring reports back to the window hosting it — both of
 * this package's wirings (guestActivation.ts, guestNavKeys.ts) emit through
 * here, so the two rules every such send shares are stated once:
 *
 * The embedder is the right target because a `<webview>` always lives in the
 * main window — floating panes are DOM overlays, not separate windows — so
 * `guest.hostWebContents` is the window a guest has to tell about anything.
 *
 * The isDestroyed guard is part of the send, not a caller's precaution (the
 * pty callbacks in terminal.ts carry the same one): the wirings send from
 * inside Electron event callbacks that keep firing during window teardown,
 * and a send on a destroyed WebContents throws where no JS caller can catch
 * it.
 */
export function sendToEmbedder(guest: WebContents, event: string, payload: unknown): void {
  const host = guest.hostWebContents
  if (host && !host.isDestroyed()) browserMainCtx.get().ipc.emit(host, event, payload)
}
