import type { ControlVerbSpec } from '@tabs/plugin-sdk/shared/content/controlSpec'
import { CONTENT_TYPE_MANIFESTS } from './content/registry'
import { CORE_CONTROL_VERB_SPECS } from './coreControlSpec'

/**
 * Every verb's `ControlVerbSpec`, core's own six plus every content type's
 * declared ones — the single source `capabilities`/`describe`
 * (src/main/externalControl.ts), main's envelope coercion
 * (src/main/controlEnvelope.ts) and the wire-schema check every typed request
 * gets before dispatch all read. Built once, from the same manifests
 * `CONTROL_REQUEST_TYPES` derives its name list from, so a spec and its name
 * cannot drift apart.
 */
export const ALL_CONTROL_VERB_SPECS: readonly ControlVerbSpec[] = [
  ...CORE_CONTROL_VERB_SPECS,
  ...CONTENT_TYPE_MANIFESTS.flatMap((manifest) => manifest.controlVerbs ?? [])
]

const byVerb = new Map(ALL_CONTROL_VERB_SPECS.map((spec) => [spec.verb, spec]))
const byCommand = new Map(ALL_CONTROL_VERB_SPECS.map((spec) => [spec.command, spec]))

/** The spec for a wire verb name, or undefined for one nothing declares. */
export function controlVerbSpecFor(verb: string): ControlVerbSpec | undefined {
  return byVerb.get(verb)
}

/** The spec for a CLI command name, or undefined for one nothing declares. */
export function controlSpecForCommand(command: string): ControlVerbSpec | undefined {
  return byCommand.get(command)
}
