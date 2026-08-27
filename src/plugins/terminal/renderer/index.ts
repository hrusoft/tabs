import type { RendererPluginContext } from '../../../renderer/src/plugin/api'
import { terminalCtx } from './pluginContext'
import { terminalContentDef } from './terminalContentDef'
import { installTerminalSettingsAccess } from './terminalSettingsAccess'

/**
 * Everything the terminal package contributes to a pane window, activated
 * against the renderer plugin API — the terminal's side of the same seam
 * the browser's renderer entry describes. Only a renderer today; it claims no
 * external-control verbs.
 *
 * The context lands in the package's holder before anything else, so every
 * module here may assume it: nothing in this package reads core directly, and
 * what the terminal can do to the window is exactly what the context offers.
 *
 * Like terminalContentDef itself, this must not be imported outside
 * registerBuiltins: it pulls in TerminalRenderer, and with it xterm and its
 * CSS side-effect import.
 */
export function activate(ctx: RendererPluginContext): void {
  terminalCtx.set(ctx)
  installTerminalSettingsAccess(ctx.settings)
  ctx.registerContent(terminalContentDef)
}
