import type { ControlVerbSpec } from '@tabs/plugin-sdk/shared/content/controlSpec'

/**
 * Formats a `ControlVerbSpec` for the `describe`/`capabilities` verbs — the
 * server-side twin of what `tabs-ctl`'s own `describeOne`/`usageFor` used to
 * do before the CLI became dumb (see resources/skills/tabs/scripts/tabs-ctl).
 * Pure formatting over data the spec already carries; nothing here validates
 * or dispatches anything (see controlEnvelope.ts for that).
 */

/** `tabs-ctl <command> --flag <val> [--optional <val>] (target forms)` — what `capabilities`' index line and `describe`'s `usage` field both show. */
export function usageFor(spec: ControlVerbSpec): string {
  const parts = [`tabs-ctl ${spec.command}`]
  for (const [flag, def] of Object.entries(spec.flags ?? {})) {
    const stand = def.placeholder ?? (def.enum ? def.enum.join('|') : flag)
    const value = def.type === 'boolean' ? '' : ` <${stand}>`
    parts.push(def.required ? `--${flag}${value}` : `[--${flag}${value}]`)
  }
  if (spec.targetCompose === 'elementTarget') {
    parts.push('(--role/--name/--selector [--nth <n>] | --ref <ref> | --x <n> --y <n>)')
  }
  return parts.join(' ')
}

/** One line for `capabilities`' compact index: usage plus a one-line summary. */
export function indexLineFor(spec: ControlVerbSpec): string {
  return `${usageFor(spec)} — ${spec.summary}`
}

/** `describe`'s per-flag documentation: everything an agent needs to build a call, nothing it has to guess. */
function describeFlags(spec: ControlVerbSpec): Record<string, unknown> {
  const flags: Record<string, unknown> = {}
  for (const [flag, def] of Object.entries(spec.flags ?? {})) {
    flags[flag] = {
      required: def.required === true,
      ...(def.type ? { type: def.type } : {}),
      ...(def.enum ? { enum: def.enum } : {}),
      ...(def.min !== undefined ? { min: def.min } : {}),
      ...(def.default !== undefined ? { default: def.default } : {}),
      ...(def.doc ? { doc: def.doc } : {})
    }
  }
  return flags
}

/** `describe`'s full entry for one command: everything `describeFlags` plus the wire schema and result shape. */
export function describeCommand(spec: ControlVerbSpec): Record<string, unknown> {
  return {
    command: spec.command,
    summary: spec.summary,
    usage: usageFor(spec),
    flags: describeFlags(spec),
    ...(spec.targetCompose
      ? {
          target:
            'Pass any of --role/--name/--selector (matched in the page, failing if ambiguous; --nth <n> is a 0-based pick among the matches); or --ref from read-page/find; or both --x and --y (CSS pixels). The three forms do not mix.'
        }
      : {}),
    wire: spec.wire,
    ...(spec.result ? { result: spec.result } : {})
  }
}
