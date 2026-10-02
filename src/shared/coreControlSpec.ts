import type { ControlVerbSpec } from '@tabs/plugin-sdk/shared/content/controlSpec'
import { MAX_BATCH_SIZE } from './controlLimits'

/**
 * Core's own six external-control verbs, described the same way a plugin
 * describes its own (see `ControlVerbSpec`) — so `capabilities`/`describe`
 * can serve a `core` capability from the exact same machinery as every
 * content type's, rather than a hand-written special case.
 *
 * Deliberately not part of any manifest: core is not a content type and has
 * no `packages/plugin-<name>/shared/manifest.ts` of its own. `src/main/externalControl.ts`
 * reads this list directly, beside `CORE_CONTROL_REQUEST_MARKER`.
 */

const PANE_FLAG = { wire: 'targetPaneId', required: true, doc: 'A pane id you own.' }

/**
 * Core's own numeric constants, served in `describe --capability core`'s
 * output — the `maxBatchRequests` key of the pre-plugin-owned-protocol CLI's
 * own `LIMITS` object (resources/skills/tabs/scripts/tabs-ctl, before this
 * ticket); every other key of that object was a browser constant and now
 * lives in `ContentTypeManifest.limits` on the browser's own manifest.
 */
export const CORE_LIMITS: Record<string, number> = {
  maxBatchRequests: MAX_BATCH_SIZE
}

export const CORE_CONTROL_VERB_SPECS: ControlVerbSpec[] = [
  {
    verb: 'ping',
    command: 'ping',
    summary: 'Check that the control socket is reachable.',
    wire: {
      type: 'object',
      properties: { type: { const: 'ping' } },
      required: ['type'],
      additionalProperties: false
    }
  },
  {
    verb: 'activatePane',
    command: 'activate-pane',
    summary:
      'Bring a pane you own to the front of its tab group without capturing it. screenshot does this itself when needed.',
    flags: { pane: PANE_FLAG },
    wire: {
      type: 'object',
      properties: { type: { const: 'activatePane' }, targetPaneId: { type: 'string' } },
      required: ['type', 'targetPaneId'],
      additionalProperties: false
    }
  },
  {
    verb: 'closePane',
    command: 'close-pane',
    summary: 'Close a pane you own and give up ownership of it.',
    flags: { pane: PANE_FLAG },
    wire: {
      type: 'object',
      properties: { type: { const: 'closePane' }, targetPaneId: { type: 'string' } },
      required: ['type', 'targetPaneId'],
      additionalProperties: false
    }
  },
  {
    verb: 'listOwnedPanes',
    command: 'list-panes',
    summary: 'List the panes you created. Never includes the user’s own panes.',
    wire: {
      type: 'object',
      properties: { type: { const: 'listOwnedPanes' } },
      required: ['type'],
      additionalProperties: false
    },
    result: { panes: [{ paneId: 'string', type: 'string', title: 'string' }] }
  },
  {
    verb: 'getPaneInfo',
    command: 'pane-info',
    summary: 'Live state of a pane you own — the fields depend on its content type.',
    flags: { pane: PANE_FLAG },
    wire: {
      type: 'object',
      properties: { type: { const: 'getPaneInfo' }, targetPaneId: { type: 'string' } },
      required: ['type', 'targetPaneId'],
      additionalProperties: false
    },
    result: { paneId: 'string', type: 'string', title: 'string' }
  },
  {
    verb: 'batch',
    command: 'batch',
    summary:
      'Run several requests in order as one transcript. Stops at the first failure unless --continue-on-error.',
    flags: {
      // Raw wire requests, not flags: a batch's whole point is sending
      // several at once, so this is the one command whose payload is the
      // protocol itself rather than a friendlier wrapper over it. `describe
      // --command <name>` prints each sub-verb's own wire shape.
      requests: {
        type: 'json',
        required: true,
        doc: 'A JSON array of wire requests — see describe --capability <name> for each verb’s wire shape.'
      },
      'continue-on-error': {
        wire: 'continueOnError',
        type: 'boolean',
        doc: 'Run every step even after one fails; failures stay visible per step.'
      }
    },
    wire: {
      type: 'object',
      properties: {
        type: { const: 'batch' },
        requests: { type: 'array' },
        continueOnError: { type: 'boolean' }
      },
      required: ['type', 'requests'],
      additionalProperties: false
    },
    batchable: false,
    result: { steps: ['object'], stoppedAt: 'number' }
  },
  {
    verb: 'capabilities',
    command: 'capabilities',
    summary: 'One line per command, grouped by capability (core plus every content type).',
    wire: {
      type: 'object',
      properties: { type: { const: 'capabilities' } },
      required: ['type'],
      additionalProperties: false
    },
    result: {
      capabilities: [
        { id: 'string', displayName: 'string', enabled: 'boolean', commands: ['string'] }
      ]
    }
  },
  {
    verb: 'describe',
    command: 'describe',
    summary:
      'Full command reference for one capability — flags, wire schema, result shape, and its guide.',
    flags: {
      capability: {
        required: true,
        doc: 'A capability id from capabilities — "core", or a content type like "browser".'
      }
    },
    wire: {
      type: 'object',
      properties: { type: { const: 'describe' }, capability: { type: 'string' } },
      required: ['type', 'capability'],
      additionalProperties: false
    },
    result: {
      capability: 'string',
      guide: 'string',
      limits: 'object',
      commands: [
        {
          command: 'string',
          summary: 'string',
          usage: 'string',
          flags: 'object',
          wire: 'object',
          result: 'object'
        }
      ]
    }
  }
]
