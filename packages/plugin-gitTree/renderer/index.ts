import type { RendererPluginContext } from '@tabs/plugin-sdk/renderer/api'
import { gitTreeContentDef } from './gitTreeContentDef'
import { installGitTreeSettingsAccess } from './gitTreeSettingsAccess'
import { gitTreeCtx } from './pluginContext'

/**
 * Everything the git tree package contributes to a pane window, activated
 * against the renderer plugin API — the single line registerBuiltins needs
 * for this type.
 *
 * Registers the content def; claims no external-control verbs and feeds
 * nothing into core's spatial navigation. Gaining either later is an edit
 * here rather than in registerBuiltins, which is the point of core listing
 * types instead of listing their capabilities.
 */
export function activate(ctx: RendererPluginContext): void {
  gitTreeCtx.set(ctx)
  installGitTreeSettingsAccess(ctx.settings)
  ctx.registerContent(gitTreeContentDef)
}
