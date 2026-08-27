import type { RingLog, Sequenced } from '@shared/ringLog'
import { createRingLog } from '@shared/ringLog'
import type { WebviewTag } from 'electron'
import { createReattachRegistry, REATTACH_GRACE_MS } from '../../../renderer/src/plugin/api'

/**
 * The UI half of navigation handling: the mounted renderer's own state
 * setters (address bar text, back/forward enablement). Split from the
 * instance's listeners because their lifetimes differ — the listeners are
 * wired once and live as long as the instance, while the React component
 * owning this state is torn down and rebuilt on every structural remount,
 * and calling a previous mount's setters is a silent no-op (the address bar
 * would freeze on the page the pane was moved on). `BrowserRenderer` swaps
 * each mount's setters into `ui.current`; between mounts the slot is null
 * and the next mount re-seeds its UI from the webview directly.
 */
export interface BrowserUiSync {
  /** Reflects a navigation in the address bar (unless the user is mid-typing there). */
  syncAddressBar: (url: string) => void
  /** Recomputes back/forward button enablement from the webview's history. */
  syncNavState: () => void
  /**
   * A guest has attached under this pane's element. Lets the mount finish
   * anything it could only ask of a guest that exists yet — see
   * `focusGuest` in BrowserRenderer.tsx, whose whole job is that gap.
   */
  guestAttached: () => void
}

/**
 * The client-side half of a browser pane: the live `<webview>` element. Kept
 * alive outside React entirely so a quick remount (a drag-and-drop move, a
 * tab promoting/collapsing into or out of a group, a sibling split pane
 * changing) can reattach to the same instance instead of building a fresh
 * one — the same reasoning as `terminalRegistry.ts`, whose own doc sits on
 * `TerminalInstance` for the same reason.
 *
 * Unlike a terminal's xterm.js instance, this doesn't buy full state
 * continuity: Electron's `<webview>` tag reloads its guest page whenever the
 * element is disconnected and reconnected to the DOM (a known, still-open
 * Electron limitation, not a bug here — see electron/electron#9529), so a
 * genuine structural move still reloads the embedded page. It reloads back
 * to the *same* URL rather than going blank, since `BrowserRenderer` keeps
 * `node.config.url` in sync via `setLeafConfig` on every navigation and seeds
 * the webview's `src` from it — a graceful, bounded degradation rather than
 * lost state. This registry still earns its keep for the common case (a
 * quick unmount/remount within the grace period reattaches with no reload
 * at all) and by giving a resumed pane an immediate correct `src` instead of
 * a blank flash.
 */
export interface BrowserInstance {
  webview: WebviewTag
  /**
   * Console output captured from the guest, for `readConsoleMessages`. Lives
   * on the instance rather than in the React component so it survives a
   * remount, and is cleared on `did-navigate` — messages belong to a
   * document, and a page that reloads should not read as two pages' output
   * interleaved.
   */
  console: RingLog<ConsoleEntry>
  /**
   * Why the load currently in flight failed, or null. Recorded here rather
   * than only by whoever happens to be awaiting a load, because the guest
   * starts loading the instant it attaches — before external control can even
   * observe that a webview exists, let alone attach a listener (see
   * `handleCreateBrowserPane`). These listeners are wired before the element
   * is ever in the DOM, so they are the only ones that cannot miss it.
   * Cleared on `did-start-loading` so the record always describes the load in
   * flight rather than some earlier page's.
   */
  loadFailure: { current: string | null }
  /**
   * The last committed main-frame document's HTTP status, or null for a
   * non-HTTP document (about:blank, a failed-load error page). Recorded on
   * the instance for the same first-load reason as `loadFailure`, but with
   * the opposite lifetime: overwritten per committed document rather than
   * cleared per load, because `getURL()`/`getTitle()` also describe the last
   * committed document — the three stay one consistent snapshot for the
   * navigation verbs to report. An in-page navigation commits no new
   * document and deliberately carries the record forward.
   */
  documentStatus: { current: DocumentStatus | null }
  /** The mounted renderer's UI setters, swapped on every mount — see BrowserUiSync. */
  ui: { current: BrowserUiSync | null }
  /** Electron listeners wired once at creation; torn down only on real disposal. */
  unsubscribe: () => void
}

/** The HTTP answer behind a committed document — what `did-frame-navigate` reported for the main frame. */
export interface DocumentStatus {
  status: number
  statusText: string
}

/**
 * The reportable main-frame load error in a `did-fail-load` event, or null if
 * there isn't one. Sub-frame failures aren't the page failing, and -3 is
 * ERR_ABORTED — a navigation superseded by another, not a failure worth
 * reporting to a caller. Shared so this rule lives in one place rather than
 * once per listener that captures load failures.
 */
export function mainFrameLoadError(event: Electron.DidFailLoadEvent): string | null {
  if (!event.isMainFrame || event.errorCode === -3) return null
  return event.errorDescription || `error ${event.errorCode}`
}

/** One captured console message. `level` is the human-readable name of Electron's numeric level. */
export interface ConsoleEntry extends Sequenced {
  level: string
  text: string
  timestamp: number
  sourceURL?: string
  line?: number
}

/** How many messages are retained per pane before the oldest start dropping. */
const CONSOLE_CAPACITY = 200

/** `console-message` reports 0–3; the wire protocol uses the names, which are what a caller filters on. */
const CONSOLE_LEVELS = ['verbose', 'info', 'warning', 'error']

export function consoleLevelName(level: number): string {
  return CONSOLE_LEVELS[level] ?? 'info'
}

export function createConsoleLog(): RingLog<ConsoleEntry> {
  return createRingLog<ConsoleEntry>(CONSOLE_CAPACITY)
}

const registry = createReattachRegistry<BrowserInstance>(REATTACH_GRACE_MS)

export const acquireBrowser = registry.acquire
export const releaseBrowser = registry.release
