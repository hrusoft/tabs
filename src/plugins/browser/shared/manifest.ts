import type { ContentTypeManifest } from '../../../shared/content/registry'
import { browserSettingsDescriptor } from './settings'

/**
 * The browser package's manifest — its process-agnostic identity and the
 * declarations the discovery gates reconcile (see shared/content/registry.ts
 * for the format, src/plugins/index.ts for how packages are found).
 *
 * `controlVerbs` restates the names in this package's request union
 * (./externalControl.ts) deliberately: the manifest is the declaration, the
 * union is the wire typing, the activation is the behavior, and the
 * reconciliation gate holds all three to each other — so this list is the one
 * a reader (or a future loader) can trust without executing anything. These
 * are the verbs this package *adds to the protocol*; the four core verbs its
 * renderer also answers (activatePane, closePane, listOwnedPanes,
 * getPaneInfo) are core's wire types and deliberately absent — which module
 * answers a verb is a separate question from which union declares it.
 */
export const BROWSER_TYPE = 'browser'

export const manifest = {
  type: BROWSER_TYPE,
  displayName: 'Browser',
  canDisable: true,
  entries: ['main', 'renderer', 'settings', 'testing'],
  settings: browserSettingsDescriptor,
  controlVerbs: [
    'createBrowserPane',
    'navigate',
    'reload',
    'goBack',
    'goForward',
    'screenshot',
    'getPageText',
    'readPage',
    'find',
    'click',
    'hover',
    'type',
    'key',
    'scroll',
    'readConsoleMessages',
    'executeJavaScript',
    'formInput',
    'readNetworkRequests',
    'captureNetworkBodies',
    'waitFor',
    'assert',
    'saveResource'
  ]
} as const satisfies ContentTypeManifest
