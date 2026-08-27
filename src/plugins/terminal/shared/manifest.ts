import type { ContentTypeManifest } from '../../../shared/content/registry'
import { terminalSettingsDescriptor } from './settings'

/**
 * The terminal package's manifest — its process-agnostic identity and the
 * declarations the discovery gates reconcile (see shared/content/registry.ts
 * for the format, src/plugins/index.ts for how packages are found).
 *
 * `TERMINAL_TYPE` is what every other terminal module takes its type string
 * from — the renderer's content def, the main entry, the Settings-window page
 * — so the string lives in one place inside the package.
 *
 * The dependency runs one way only: this file imports ./settings, never the
 * reverse. That is why `terminalSettingsDescriptor.type` restates the literal
 * instead of importing `TERMINAL_TYPE` — the reverse edge would be an ESM
 * cycle, and a const read during a partially-evaluated module is a TDZ throw at
 * import time, which for a settings module means the app failing to boot. That
 * single restatement is covered by the census test rather than by the
 * compiler.
 *
 * Declaring `settings` (the descriptor) and shipping the `settings` entry (the
 * Settings-window page) go together — the reconciliation gate holds the pair.
 */
export const TERMINAL_TYPE = 'terminal'

export const manifest = {
  type: TERMINAL_TYPE,
  displayName: 'Terminal',
  canDisable: true,
  entries: ['main', 'renderer', 'settings', 'testing'],
  settings: terminalSettingsDescriptor
} as const satisfies ContentTypeManifest
