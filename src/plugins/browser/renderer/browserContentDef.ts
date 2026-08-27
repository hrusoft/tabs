import { createLeaf } from '@shared/model/factories'
import type { LeafContent } from '@shared/model/types'
import type { ContentRendererDef } from '../../../renderer/src/plugin/api'
import { BROWSER_TYPE, manifest as browserManifest } from '../shared/manifest'
import { BrowserRenderer } from './BrowserRenderer'
import { BrowserIcon } from './browserIcons'

/**
 * The browser's content-registry contribution — registered by
 * registerBuiltins. New browser panes start blank; splitting or tabbing from
 * one copies its config as-is (no deriveConfig).
 *
 * Identity comes from the shared census, not from literals here — see
 * shared/content/registry.ts.
 */
export const browserContentDef: ContentRendererDef<LeafContent> = {
  type: browserManifest.type,
  displayName: browserManifest.displayName,
  Component: BrowserRenderer,
  createAction: {
    testId: 'pane-new-browser-button',
    label: 'New browser',
    Icon: BrowserIcon,
    createContent: () => createLeaf(BROWSER_TYPE, { url: 'about:blank' })
  }
}
