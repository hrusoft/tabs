import { resolvePluginEntries } from '@shared/plugin/entries'
import { contentRegistry } from '../core/registry/registry'
import type { RendererPluginContext } from '../plugin/api'
import { createRendererPluginContext } from '../plugin/context'
import { registerStructuralContent } from './registerStructural'

/**
 * The pane window's activation point: every package's renderer entry,
 * discovered by glob and reconciled against the manifests
 * (shared/plugin/entries.ts), each activated against a context bound to its
 * type (plugin/context.ts). No package is named here — adding one is a folder
 * plus a PLUGIN_PACKAGES line, and this file never changes.
 *
 * Activation order is PLUGIN_PACKAGES order, and it is a UI contract: the
 * registry's iteration order drives the order creation actions appear in
 * (structure first, then terminal before browser) — the empty-pane toolbar's
 * row of buttons and the Cmd+P command palette's list, so reordering the
 * list silently reorders both.
 *
 * This glob is the only route into a package's renderer graph, and it must
 * stay per-boundary: these entries pull in xterm and the `<webview>` tag, so
 * nothing outside a pane-tree window may import this file (the census and the
 * other boundaries each glob their own entry kind instead — see
 * shared/content/registry.ts).
 */
const rendererEntries = import.meta.glob<{ activate: (ctx: RendererPluginContext) => void }>(
  '../../../plugins/*/renderer/index.ts',
  { eager: true }
)

export function registerBuiltins(): void {
  if (contentRegistry.has('tabs')) return
  registerStructuralContent()
  for (const [type, entry] of resolvePluginEntries('renderer', rendererEntries)) {
    entry.activate(createRendererPluginContext(type))
  }
}
