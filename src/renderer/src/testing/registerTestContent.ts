import { createLeaf } from '@tabs/plugin-sdk/shared/model/factories'
import { createElement } from 'react'
import { installGuestActivation } from '../../../../packages/plugin-browser/renderer/guestActivation'
import { installGuestNavForwarding } from '../../../../packages/plugin-browser/renderer/guestNavKeys'
import { registerStructuralContent } from '../content/registerStructural'
import { dispatchNavChord } from '../content/spatialNav'
import { contentRegistry } from '../core/registry/registry'
import { useLayoutStore } from '../core/store/layoutStore'
import { createRendererPluginContext } from '../plugin/context'
import { stubContentDef } from './stubContent'

/**
 * The test tiers' stand-in for registerBuiltins: the same structural renderers
 * in the same order (shared outright, see registerStructural.ts), but with the
 * stub def where terminal and browser would be — deliberately NOT
 * registerBuiltins itself, whose import would pull in TerminalRenderer (xterm
 * and its CSS) and BrowserRenderer (the Electron-only `<webview>` tag).
 * Idempotent under the same guard registerBuiltins uses.
 *
 * The stub stands in for both of the browser's guest forwarders too. That is
 * real coverage, not bookkeeping: since core stopped subscribing to the guest
 * events itself, the browser's nav-key and guest-pointer-down events (over the
 * content bridge) are reached only through a content type's registration, and this is the cheapest
 * tier that can exercise those paths (drive them with `__fakeApi.emitNavKey` /
 * `emitGuestPointerDown`). Importing them here is safe where importing the
 * browser's renderer would not be — each is a few lines over the bridge and
 * pulls in no `<webview>`, which is why guestActivation.ts holds its own
 * suppression flag instead of importing it from the verb module. They take
 * their dependencies as parameters for exactly this tier's benefit: here
 * core's own dispatchNavChord/setActivePane are passed directly with a
 * browser-scoped ipc built on the spot (context creation is side-effect
 * free), where the browser package's activate passes its own context's —
 * same wiring, no activation needed.
 */
export function registerTestContent(): void {
  if (contentRegistry.has('tabs')) return
  registerStructuralContent()
  contentRegistry.register(stubContentDef)
  const browserIpc = createRendererPluginContext('browser').ipc
  installGuestNavForwarding(browserIpc, dispatchNavChord)
  installGuestActivation(browserIpc, (paneId) => useLayoutStore.getState().setActivePane(paneId))
}

/**
 * The native-vs-Electron visual comparison's git tree (native/Visual): the
 * real renderer and header title over the fake bridge seeded with `seed` — see the package's testing/visualCapture.ts.
 * Harness-only, and imported lazily, so no other page ever loads the git
 * tree's renderer or CSS.
 */
export async function registerGitTreeVisualCapture(seed: unknown): Promise<void> {
  const { activateVisualCapture } = await import(
    '../../../../packages/plugin-gitTree/testing/visualCapture'
  )
  activateVisualCapture(
    createRendererPluginContext('gitTree'),
    seed as Parameters<typeof activateVisualCapture>[1]
  )
}

/**
 * The native-vs-Electron visual comparison's browser (native/Visual): the
 * real header chrome around a solid-color stand-in for the page, one seed per
 * browser pane, and the creation action when asked for — see the package's testing/visualCapture.ts. Harness-only and
 * lazy, like the git tree's.
 */
export async function registerBrowserVisualCapture(capture: unknown): Promise<void> {
  const { activateVisualCapture } = await import(
    '../../../../packages/plugin-browser/testing/visualCapture'
  )
  activateVisualCapture(
    createRendererPluginContext('browser'),
    capture as Parameters<typeof activateVisualCapture>[1]
  )
}

/**
 * The native-vs-Electron visual comparison's long command palette
 * (native/Visual, the `palette-many` scenario): `count` extra creation-capable
 * stub types after the harness's own, named "Sample 2", "Sample 3", ..., each
 * with the stub's "\u25A3" glyph as its icon. Harness-only, like the two above.
 */
export function registerPaletteVisualTypes(count: number): void {
  for (let n = 2; n < 2 + count; n++) {
    const type = `sample-${n}`
    contentRegistry.register({
      type,
      displayName: `Sample ${n}`,
      Component: stubContentDef.Component,
      createAction: {
        testId: `pane-new-${type}-button`,
        label: `New sample ${n}`,
        Icon: () => createElement('span', { 'aria-hidden': 'true' }, '\u25A3'),
        createContent: () => createLeaf(type)
      }
    })
  }
}
