import type { LeafContent } from '@shared/model/types'
import { HeaderButton, type PaneCapabilities } from '../../../renderer/src/plugin/api'
import { terminalCtx } from './pluginContext'

function ClearScrollbackIcon() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {/* Three scrollback rows tapering off, swept by a small wipe mark —
          deliberately distinct from core's ClearPaneIcon (an eraser): that
          one destroys the pane's content, this one only its scrollback. */}
      <path d="M2 3h9M2 6.5h6.5M2 10h4" fill="none" stroke="currentColor" strokeLinecap="round" />
      <path
        d="M10.5 11.5l3 3M13.5 11.5l-3 3"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
      />
    </svg>
  )
}

/**
 * The terminal's own ContentRendererDef.HeaderControl. Calls the exact same
 * `clear` Cmd/Ctrl+K invokes — the one TerminalRenderer registers on this
 * pane's core handle (`extension: { clear }`), read back through this
 * package's own context the way browserControl.ts reads the browser's — so
 * it shares that shortcut's alt-buffer safety for free rather than
 * reimplementing it.
 *
 * Not PaneHeaderControls' own "Clear pane" button (PANE_BUTTON.clear /
 * layoutStore's clearPane) — that destroys the pane's content entirely.
 * This clears only the terminal's scrollback, leaving the pane and the
 * running shell alone.
 */
export function ClearScrollbackControl({ leaf }: { leaf: LeafContent }) {
  const clearScrollback = (): void => {
    const extension = terminalCtx.get().panes.getHandle(leaf.id)?.extension as
      | Partial<PaneCapabilities>
      | undefined
    extension?.clear?.()
  }
  return (
    <HeaderButton
      testId="pane-terminal-clear-scrollback-button"
      label="Clear scrollback"
      onPress={clearScrollback}
    >
      <ClearScrollbackIcon />
    </HeaderButton>
  )
}
