import { createReattachRegistry, REATTACH_GRACE_MS } from '@tabs/plugin-sdk/renderer/api'
import type { FitAddon } from '@xterm/addon-fit'
import type { SerializeAddon } from '@xterm/addon-serialize'
import type { Terminal } from '@xterm/xterm'

/**
 * The client-side half of a terminal: the xterm.js instance and the DOM
 * element it was opened on. Kept alive outside React entirely so a remount
 * (drag-and-drop move, a tab promoting/collapsing into or out of a group, a
 * sibling split pane changing) can reattach to the same instance instead of
 * building a fresh, blank one — the mirror of how `packages/plugin-terminal/main/terminal.ts` keeps
 * the underlying pty alive across the same remounts.
 */
export interface TerminalInstance {
  term: Terminal
  fitAddon: FitAddon
  /** Loaded with the instance, not lazily before a move: the addon must have seen the buffer render to serialize it. */
  serializeAddon: SerializeAddon
  /** The element `term.open()` was called on — detached, not destroyed, across a remount. */
  container: HTMLDivElement
  /** Electron IPC listeners wired once at creation; torn down only on real disposal. */
  unsubscribeData: () => void
  unsubscribeExit: () => void
}

const registry = createReattachRegistry<TerminalInstance>(REATTACH_GRACE_MS)

export const acquireTerminal = registry.acquire
export const releaseTerminal = registry.release
export const abandonTerminal = registry.abandon
