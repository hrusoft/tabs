import type { ContentTypeManifest } from '../../../shared/content/registry'
import { gitTreeSettingsDescriptor } from './settings'

/**
 * The git tree package's manifest — its process-agnostic identity and the
 * declarations the discovery gates reconcile (see shared/content/registry.ts
 * for the format, src/plugins/index.ts for how packages are found).
 *
 * Declares one settings blob (auto-refresh-on-focus, and the two column
 * visibility toggles, see ./settings.ts) — the page size stays a constant,
 * and the branch filter is per-pane state (`config.branchScope`) rather than
 * a setting here, since it's what a specific pane is pointed at, the same way
 * `config.cwd` is. No `controlVerbs`: this type answers nothing on the
 * external-control socket.
 */
export const GIT_TREE_TYPE = 'gitTree'

export const manifest = {
  type: GIT_TREE_TYPE,
  displayName: 'Git tree',
  canDisable: true,
  entries: ['main', 'renderer', 'settings', 'testing'],
  settings: gitTreeSettingsDescriptor
} as const satisfies ContentTypeManifest
