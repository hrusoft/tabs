import type { FitAddon } from '@xterm/addon-fit'
import type { Terminal } from '@xterm/xterm'
import { createReattachRegistry, REATTACH_GRACE_MS } from '../../../renderer/src/plugin/api'

/**
 * The client-side half of a terminal: the xterm.js instance and the DOM
 * element it was opened on. Kept alive outside React entirely so a remount
 * (drag-and-drop move, a tab promoting/collapsing into or out of a group, a
 * sibling split pane changing) can reattach to the same instance instead of
 * building a fresh, blank one — the mirror of how `src/plugins/terminal/main/terminal.ts` keeps
 * the underlying pty alive across the same remounts.
 */
interface TerminalInstance {
  term: Terminal
  fitAddon: FitAddon
  /** The element `term.open()` was called on — detached, not destroyed, across a remount. */
  container: HTMLDivElement
  /** Electron IPC listeners wired once at creation; torn down only on real disposal. */
  unsubscribeData: () => void
  unsubscribeExit: () => void
}

const registry = createReattachRegistry<TerminalInstance>(REATTACH_GRACE_MS)

export const acquireTerminal = registry.acquire
export const releaseTerminal = registry.release
