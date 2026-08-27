import type { SplitContent, TabsContent } from '@shared/model/types'
import { EMPTY_TYPE } from '@shared/model/types'
import { contentRegistry } from '../core/registry/registry'
import { EmptyPaneRenderer } from './empty/EmptyPaneRenderer'
import { SplitRenderer } from './split/SplitRenderer'
import { TabsRenderer } from './tabs/TabsRenderer'

/**
 * The content types that are layout structure rather than content: they hold
 * other nodes (tabs, split) or stand in for the absence of any (empty).
 *
 * Separated from registerBuiltins so the non-Electron test tiers can register
 * exactly these and then substitute a stub for terminal and browser — see
 * testing/registerTestContent.ts. Sharing the real thing matters: registration
 * order is the pane-header button order, and a `displayName` here is asserted
 * against in the jsdom tier, so a hand-copied second list would let both
 * non-Electron tiers stay green against a layout the app doesn't have.
 *
 * Safe to import from a test tier, unlike registerBuiltins: none of these
 * three pulls in xterm or the Electron-only `<webview>` tag.
 */
export function registerStructuralContent(): void {
  contentRegistry.register<TabsContent>({
    type: 'tabs',
    displayName: 'Tab group',
    Component: TabsRenderer
  })
  contentRegistry.register<SplitContent>({
    type: 'split',
    displayName: 'Split',
    Component: SplitRenderer
  })
  contentRegistry.register({
    type: EMPTY_TYPE,
    displayName: 'Empty pane',
    Component: EmptyPaneRenderer
  })
}
