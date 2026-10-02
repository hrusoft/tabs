import type { ContentTypeManifest } from '@tabs/plugin-sdk/shared/content/manifest'
import { BROWSER_CONTROL_VERB_SPECS } from './controlSpec'
import {
  DEFAULT_PAGE_TEXT_MAX,
  EXECUTE_RESULT_MAX,
  NETWORK_BODY_HARD_MAX,
  NETWORK_BODY_MAX,
  NETWORK_LOG_CAPACITY,
  PAGE_TEXT_HARD_MAX,
  WAIT_DEFAULT_POLL_MS,
  WAIT_DEFAULT_TIMEOUT_MS,
  WAIT_IDLE_QUIET_MS,
  WAIT_MAX_TIMEOUT_MS
} from './externalControl'
// `?raw` (Vite's file-as-string import suffix) rather than import.meta.glob:
// this is a leaf asset a single, statically-known module reads, not a
// discovery boundary — the same idiom TerminalRenderer.tsx already uses for
// xterm.css. It typechecks under tsconfig.web.json via env.d.ts's
// `vite/client` reference; tsconfig.node.json needs its own ambient
// declaration for it, in src/shared/rawImports.d.ts.
import guide from './guide.md?raw'
import { browserSettingsDescriptor } from './settings'

/**
 * The browser package's manifest — its process-agnostic identity and the
 * declarations the discovery gates reconcile (see shared/content/registry.ts
 * for the format, src/plugins/index.ts for how packages are found).
 *
 * `controlVerbs` is this package's entire external-control surface — one
 * `ControlVerbSpec` per verb (shared/controlSpec.ts), not just a name: the
 * manifest is the declaration, the request union (./externalControl.ts) is
 * the wire typing, the activation is the behavior, and the reconciliation
 * gate holds all three to each other. These are the verbs this package *adds
 * to the protocol*; the four core verbs its renderer also answers
 * (activatePane, closePane, listOwnedPanes, getPaneInfo) are core's wire
 * types and deliberately absent — which module answers a verb is a separate
 * question from which union declares it.
 */
export const BROWSER_TYPE = 'browser'

export const manifest = {
  type: BROWSER_TYPE,
  displayName: 'Browser',
  canDisable: true,
  entries: ['main', 'renderer', 'settings', 'testing'],
  settings: browserSettingsDescriptor,
  controlVerbs: BROWSER_CONTROL_VERB_SPECS,
  guide,
  // Same key names as the pre-plugin-owned-protocol CLI's own LIMITS object
  // (resources/skills/tabs/scripts/tabs-ctl, before this ticket) — every flag
  // doc that states one of these numbers interpolates the same constant this
  // is built from, so `describe`'s structured `limits` and its prose can't
  // disagree.
  limits: {
    pageTextDefaultMax: DEFAULT_PAGE_TEXT_MAX,
    pageTextHardMax: PAGE_TEXT_HARD_MAX,
    waitDefaultTimeoutMs: WAIT_DEFAULT_TIMEOUT_MS,
    waitMaxTimeoutMs: WAIT_MAX_TIMEOUT_MS,
    waitIdleQuietMs: WAIT_IDLE_QUIET_MS,
    waitDefaultPollMs: WAIT_DEFAULT_POLL_MS,
    networkBodyMax: NETWORK_BODY_MAX,
    networkBodyHardMax: NETWORK_BODY_HARD_MAX,
    networkRequestCapacity: NETWORK_LOG_CAPACITY,
    executeResultMax: EXECUTE_RESULT_MAX
  }
} as const satisfies ContentTypeManifest
