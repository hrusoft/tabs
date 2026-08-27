import type { RendererPluginContext } from '../../../renderer/src/plugin/api'
import { browserContentDef } from './browserContentDef'
import { registerBrowserControlVerbs } from './browserExternalControl'
import { installBrowserSettingsAccess } from './browserSettingsAccess'
import { installGuestActivation } from './guestActivation'
import { installGuestNavForwarding } from './guestNavKeys'
import { browserCtx } from './pluginContext'

/**
 * Everything the browser package contributes to a pane window, activated
 * against the renderer plugin API — the single line registerBuiltins needs
 * for this type.
 *
 * More than a renderer: a content type can also claim external-control verbs
 * and feed core's spatial navigation. Keeping that behind one entry point is
 * what lets core list types rather than list their capabilities, and gives a
 * future "is this type enabled?" decision exactly one call to skip.
 *
 * Both guest subscriptions are made with no matching teardown here, and that
 * is deliberate: activation happens once per window at module scope
 * (main.tsx, before the first render), while installSpatialNav rides a React
 * effect and is torn down and re-established by StrictMode's double mount.
 * Tying the guest's presses to that lifecycle only created a window in which
 * they were dropped.
 */
export function activate(ctx: RendererPluginContext): void {
  browserCtx.set(ctx)
  installBrowserSettingsAccess(ctx.settings)
  ctx.registerContent(browserContentDef)
  registerBrowserControlVerbs(ctx)
  installGuestNavForwarding(ctx.ipc, ctx.dispatchNavChord)
  installGuestActivation(ctx.ipc, ctx.layout.setActivePane)
}
