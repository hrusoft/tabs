import type { ContentTypeManifest } from '../../../shared/content/registry'
import { gitTreeSettingsDescriptor } from './settings'

/**
 * The git tree package's manifest — its process-agnostic identity and the
 * declarations the discovery gates reconcile (see shared/content/registry.ts
 * for the format, src/plugins/index.ts for how packages are found).
 *
 * Declares one setting (auto-refresh-on-focus, see ./settings.ts) — small
 * enough that it's still true nothing about the commit list itself is a
 * preference (the page size is a constant, the graph has no options). No
 * `controlVerbs`: this type answers nothing on the external-control socket.
 */
export const GIT_TREE_TYPE = 'gitTree'

export const manifest = {
  type: GIT_TREE_TYPE,
  displayName: 'Git tree',
  canDisable: true,
  entries: ['main', 'renderer', 'settings', 'testing'],
  settings: gitTreeSettingsDescriptor
} as const satisfies ContentTypeManifest
