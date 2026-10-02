import type { Debugger, WebContents } from 'electron'

/**
 * A refcounted CDP (`webContents.debugger`) session manager, one session per
 * guest `WebContents`, shared by every feature in this package that needs the
 * Chrome DevTools Protocol.
 *
 * ## Why refcounted, and why shared
 *
 * Electron allows exactly **one** debugger client per `WebContents` — a second
 * `attach()` throws `"Debugger is already attached to the target"` (measured).
 * So two features cannot each own their own session: `save-resource` attaches
 * transiently to pull a `blob:` resource's bytes (`Page.getResourceContent`,
 * the only route that beats a page's `connect-src 'self'` CSP), while opt-in
 * network body capture holds a *persistent* `Network.enable`. A transient user
 * detaching would tear the persistent one down. This manager refcounts leases
 * so the session lives exactly as long as at least one lease holds it, and the
 * `attach`/`detach` happen only at the 0↔1 edges.
 *
 * ## Guest-id churn
 *
 * Keyed by the guest object, not its id: a structural reparent of the
 * `<webview>` destroys the guest and builds a new one (see
 * browserGuestRegistry.ts), so a session is per-guest-lifetime. Each entry
 * evicts itself on the guest's `destroyed` event — the same self-managing shape
 * as the guest wiring in main/index.ts. A caller that still holds a lease when
 * the guest dies gets rejections from `send`, never a throw into Electron.
 *
 * Nothing here enables a CDP domain on its own — a lease enables what it needs
 * (`Page.enable`, `Network.enable`) and the domains simply coexist on the one
 * session. Detach at the last release resets them all, which is why a lease
 * need not disable its own domains before releasing.
 */

interface Session {
  guest: WebContents
  debug: Debugger
  refs: number
  /** Fan-out for `Debugger` `message` events, so many leases can observe one session. */
  listeners: Set<(method: string, params: unknown) => void>
  onMessage: (event: unknown, method: string, params: unknown) => void
  onDestroyed: () => void
}

const sessions = new Map<number, Session>()

/**
 * A hold on a guest's shared CDP session. `send` issues one CDP command;
 * `onEvent` subscribes to the session's `message` stream (what persistent
 * network-body capture rides); `release` drops this hold — idempotent, and the
 * session detaches once the last hold is gone.
 */
export interface DebuggerLease {
  send(method: string, params?: Record<string, unknown>): Promise<unknown>
  onEvent(listener: (method: string, params: unknown) => void): () => void
  release(): void
}

/**
 * Acquires a lease on `guest`'s CDP session, attaching it if this is the first
 * lease. Rejects (rather than throwing) if the guest is gone or the attach
 * fails — a page with DevTools already open on it is the expected such case,
 * and the verb degrades to an error rather than crashing.
 */
export async function acquireGuestDebugger(guest: WebContents): Promise<DebuggerLease> {
  if (guest.isDestroyed()) throw new Error('the browser pane is gone')

  let session = sessions.get(guest.id)
  if (!session) {
    const debug = guest.debugger
    const listeners = new Set<(method: string, params: unknown) => void>()
    const onMessage = (_event: unknown, method: string, params: unknown): void => {
      for (const listener of listeners) listener(method, params)
    }
    const created: Session = {
      guest,
      debug,
      refs: 0,
      listeners,
      onMessage,
      onDestroyed: () => forget(guest.id)
    }
    debug.on('message', onMessage)
    guest.once('destroyed', created.onDestroyed)
    try {
      // Already attached is a real possibility if DevTools is open on the guest;
      // surface it as a rejection the verb can report, not an uncaught throw.
      debug.attach('1.3')
    } catch (error) {
      debug.removeListener('message', onMessage)
      guest.removeListener('destroyed', created.onDestroyed)
      throw new Error(`could not attach a debugger to the pane: ${String(error)}`)
    }
    sessions.set(guest.id, created)
    session = created
  }

  session.refs++
  let released = false
  const lease: DebuggerLease = {
    send(method, params) {
      const live = sessions.get(guest.id)
      if (!live || live.debug !== session?.debug) {
        return Promise.reject(new Error('the browser pane is gone'))
      }
      return live.debug.sendCommand(method, params)
    },
    onEvent(listener) {
      session?.listeners.add(listener)
      return () => session?.listeners.delete(listener)
    },
    release() {
      if (released) return
      released = true
      const live = sessions.get(guest.id)
      if (!live) return
      live.refs--
      if (live.refs <= 0) teardown(live)
    }
  }
  return lease
}

/** Detaches and drops a session whose refcount hit zero. */
function teardown(session: Session): void {
  sessions.delete(session.guest.id)
  session.debug.removeListener('message', session.onMessage)
  session.guest.removeListener('destroyed', session.onDestroyed)
  session.listeners.clear()
  try {
    if (session.debug.isAttached()) session.debug.detach()
  } catch {
    // A guest torn down under us detaches itself; nothing left to do.
  }
}

/** Drops a session because its guest was destroyed — the detach already happened with it. */
function forget(guestId: number): void {
  const session = sessions.get(guestId)
  if (!session) return
  sessions.delete(guestId)
  session.debug.removeListener('message', session.onMessage)
  session.listeners.clear()
}

/**
 * e2e reset: detaches every live session and empties the map, so a debugger a
 * test left attached cannot leak into the next (see browser/main/index.ts's
 * resetForTests, and src/main/e2e.ts). Mutable main-process state, so it must
 * reset like the guest registry beside it.
 */
export function resetGuestDebuggersForTests(): void {
  for (const session of sessions.values()) {
    session.debug.removeListener('message', session.onMessage)
    session.guest.removeListener('destroyed', session.onDestroyed)
    session.listeners.clear()
    try {
      if (!session.guest.isDestroyed() && session.debug.isAttached()) session.debug.detach()
    } catch {
      // Best-effort; a gone guest is already detached.
    }
  }
  sessions.clear()
}
