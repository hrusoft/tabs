import {
  asRecord,
  type ContentTypeSettingsDescriptor
} from '../../../shared/content/settingsDescriptor'

/** The git tree content type's slice of Settings.contentTypes. */
export interface GitTreeSettings {
  /** Whether an active git tree pane re-reads its log when it (or the window) regains focus. See GitTreeRenderer.tsx. */
  autoRefreshOnFocus: boolean
  /** Whether the commit list shows an author column. Off by default — the graph, hash and message are the only always-shown columns. */
  showAuthorColumn: boolean
  /** Whether the commit list shows a date column. Off by default, same reasoning as showAuthorColumn. */
  showDateColumn: boolean
}

export const DEFAULT_GIT_TREE_SETTINGS: GitTreeSettings = {
  autoRefreshOnFocus: false,
  showAuthorColumn: false,
  showDateColumn: false
}

/** Total merge of a persisted git tree blob over the defaults — see the descriptor contract. */
export function mergeGitTreeSettings(persisted: unknown): GitTreeSettings {
  return { ...DEFAULT_GIT_TREE_SETTINGS, ...asRecord(persisted) } as GitTreeSettings
}

export const gitTreeSettingsDescriptor: ContentTypeSettingsDescriptor<GitTreeSettings> = {
  // Restated rather than imported from ./manifest.ts — that file imports this
  // one to build the descriptor it declares, and the reverse edge would be an
  // ESM cycle (a TDZ throw at import time, i.e. the app failing to boot). See
  // the identical restatement on terminalSettingsDescriptor.
  type: 'gitTree',
  defaults: DEFAULT_GIT_TREE_SETTINGS,
  merge: mergeGitTreeSettings
}
