/**
 * The git tree package's bridge vocabulary: the method names its main entry
 * registers and its renderer client calls. Channel strings are derived by the
 * generic bridge (`plugin:gitTree:…`, see shared/plugin/bridge.ts), so the
 * two halves agree by construction. No events — every exchange here is
 * renderer-initiated request/response.
 */
export const GitTreeMethod = {
  log: 'log',
  commit: 'commit',
  defaultDirectory: 'defaultDirectory',
  chooseDirectory: 'chooseDirectory'
} as const
