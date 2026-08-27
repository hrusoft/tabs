import { createLeaf } from '@shared/model/factories'
import type { LeafContent } from '@shared/model/types'
import type { ContentRendererDef } from '../../../renderer/src/plugin/api'
import { TERMINAL_TYPE, manifest as terminalManifest } from '../shared/manifest'
import { terminalCtx } from './pluginContext'
import { TerminalIcon } from './TerminalIcon'
import { TerminalRenderer } from './TerminalRenderer'
import { terminalBridge } from './terminalBridge'
import { getTerminalSettings } from './terminalSettingsAccess'

/**
 * The terminal's content-registry contribution — registered by this package's
 * `activate`, whose call chain (registerBuiltins → renderer/index.ts) must stay
 * this module's only route in: it pulls in TerminalRenderer, and with it xterm
 * and its CSS side-effect import.
 *
 * Identity comes from the shared census rather than being restated here, so
 * this def, the main-process module and the Settings page cannot disagree about
 * what a terminal is called (see shared/content/registry.ts).
 */
export const terminalContentDef: ContentRendererDef<LeafContent> = {
  type: terminalManifest.type,
  displayName: terminalManifest.displayName,
  Component: TerminalRenderer,
  mayBlockClose: true,
  createAction: {
    testId: 'pane-new-terminal-button',
    label: 'New terminal',
    Icon: TerminalIcon,
    createContent: () => createLeaf(TERMINAL_TYPE, { cwd: '~' })
  },
  /**
   * A new terminal should open where the pane it came from *is*, not where
   * that pane started — and, since this hook belongs to the type being
   * created, "the pane it came from" need not be a terminal at all. Splitting
   * a terminal still lands in that shell's live directory; pressing New
   * terminal on a git tree pane now lands in that repository, and this file
   * knows nothing about git trees to make it happen.
   *
   * `exposedCwdOf` is what makes that true — it asks the origin's own type
   * (see content/exposedCwd.ts). Reading `originLeaf.config.cwd` directly
   * would be wrong even for a terminal origin: a pty's config is a stale
   * snapshot from before every `cd` the user has typed.
   *
   * Still gated by `inheritCwdOnNewPane`, which is this type's own setting and
   * governs when a *terminal* inherits — a question that stays this type's to
   * answer however many other types learn to expose a directory. Falls back to
   * the seeded `~` when inheritance is off or the origin offers nothing (a
   * blank pane, a dead pty, an unsupported platform).
   */
  async deriveConfig(originLeaf) {
    if (!getTerminalSettings().inheritCwdOnNewPane) return
    const cwd = await terminalCtx.get().exposedCwdOf(originLeaf)
    return cwd ? { cwd } : undefined
  },
  /**
   * Where this shell actually is, for a pane of another type created from it —
   * the answer a git tree pane opens on.
   *
   * Deliberately *not* gated by `inheritCwdOnNewPane`: that setting is about
   * when a terminal inherits a directory, not about whether a terminal will
   * tell anyone where it is. Letting it suppress this would make one type's
   * preference silently govern another type's behaviour, which is the coupling
   * this capability exists to avoid.
   *
   * Answers undefined for a leaf that is not a live pty — a restored-but-never
   * -mounted terminal, or one whose shell has exited — which callers treat as
   * "nothing to inherit" rather than as an error.
   */
  exposeCwd: (leaf) => terminalBridge.getCwd(leaf.id)
}
