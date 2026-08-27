import type { MainPluginContext, MainPluginModule } from '../../../main/plugin/api'
import { terminalMainCtx } from './pluginContext'
import {
  disposeAllTerminals,
  getTerminalCwdSync,
  listTerminalIds,
  registerTerminalCloseBlockers,
  registerTerminalIpc
} from './terminal'

/** The terminal package's main-process entry. */
export function activate(ctx: MainPluginContext): MainPluginModule {
  terminalMainCtx.set(ctx)
  registerTerminalIpc()
  registerTerminalCloseBlockers()
  return {
    /**
     * Capture each live shell's real working directory into the layout about
     * to be persisted, then kill every pty so quitting never leaves orphans.
     *
     * The order is load-bearing and is the reason these two calls belong in
     * one function: the refresh asks the OS where each *live* pty currently is
     * (see getTerminalCwdSync), so disposing first would leave nothing to ask.
     * It used to be two adjacent lines in index.ts's before-quit handler,
     * where the dependency between them was invisible and a reorder would have
     * silently persisted stale directories.
     *
     * Both are synchronous, and deliberately so — see the onQuitSync contract
     * on MainPluginModule, and CLAUDE.md's before-quit gotcha for what the
     * async version cost. refreshLeafConfigs is a no-op unless
     * persistLayoutOnExit is on, which is what keeps the `lsof` probing off
     * the quit path entirely for users who have turned persistence off.
     *
     * `cwd` is named here rather than in core because it is this type's config
     * key: core patches whatever keys the probe hands back, and knows none of
     * them.
     */
    onQuitSync() {
      ctx.refreshLeafConfigs(listTerminalIds, (id) => {
        const cwd = getTerminalCwdSync(id)
        return cwd ? { cwd } : undefined
      })
      disposeAllTerminals()
    },
    resetForTests: disposeAllTerminals
  }
}
