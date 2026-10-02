import { resolve as resolvePath } from 'node:path'
import { controlSpecForCommand } from '../shared/controlSpecRegistry'
import type { ControlRequest } from '../shared/externalControl'

/**
 * Turns a dumb CLI's `{command, args}` envelope into a typed `ControlRequest`
 * — the server-side twin of what `tabs-ctl`'s own `buildRequest` used to do
 * before the CLI became dumb (resources/skills/tabs/scripts/tabs-ctl no
 * longer has any of this: it sends flags as raw strings/booleans and lets
 * the app do everything named here). `src/main/externalControl.ts` calls
 * this once per envelope, before the wire-schema check and dispatch every
 * request already gets.
 *
 * Unlike the CLI's old version, messages here are not required to be
 * byte-identical to what `buildRequest` used to produce — they're written to
 * be clear and to name the flag, not to match a frozen wire contract. The
 * two sentences `PANE_GONE_ERROR`/`PANE_NOT_MOUNTED_ERROR` quote verbatim in
 * SKILL.md are handler errors, not flag-coercion ones, and are untouched by
 * this file.
 */

const TARGET_FLAG_NAMES = ['ref', 'x', 'y', 'role', 'name', 'selector', 'nth'] as const

/** Every flag name a command accepts, including the implicit target flags a `targetCompose` command takes. */
function knownFlagsFor(spec: ReturnType<typeof controlSpecForCommand>): Set<string> {
  const names = Object.keys(spec?.flags ?? {})
  if (spec?.targetCompose === 'elementTarget') names.push(...TARGET_FLAG_NAMES)
  return new Set(names)
}

/**
 * Builds the wire `target` field from `--ref` / `--x`+`--y` /
 * `--role`/`--name`/`--selector`[`--nth`] — the one flag composition this
 * protocol needs (see `ControlVerbSpec.targetCompose`'s doc for why there is
 * exactly one). The three forms are mutually exclusive; `--nth` only makes
 * sense with the semantic form.
 */
function composeElementTarget(
  args: Record<string, unknown>
): { target: Record<string, unknown> } | { error: string } {
  // None of the target-compose flags are `boolean`- or `path`-typed, so a
  // bare one (parseArgs turns a flag given no value into `true`) always means
  // the caller forgot the value — the same rule the generic per-flag loop
  // enforces for every other flag, restated here since these flags bypass
  // that loop entirely (see composedFlagNames in buildRequestFromEnvelope).
  // Caught before role/name/selector's own check below (a `typeof !==
  // 'string'` guard, which already refuses `true` the same way) so every
  // target flag gets one consistent message, and before --ref/--x/--y ever
  // reach `String()`/`Number()`, which would otherwise coerce `true` into
  // `"true"` or `1` instead of refusing it.
  for (const flag of ['ref', 'x', 'y', 'nth'] as const) {
    if (args[flag] === true) return { error: `--${flag} needs a value` }
  }

  const hasRef = args.ref !== undefined
  const hasCoord = args.x !== undefined || args.y !== undefined
  const semanticFlags = (['role', 'name', 'selector'] as const).filter(
    (flag) => args[flag] !== undefined
  )
  const forms = [
    hasRef ? '--ref' : null,
    hasCoord ? '--x/--y' : null,
    semanticFlags.length > 0 ? semanticFlags.map((flag) => `--${flag}`).join('/') : null
  ].filter((form): form is string => form !== null)
  if (forms.length > 1) {
    return { error: `${forms.join(' and ')} are different target forms — pass only one` }
  }
  if (args.nth !== undefined && semanticFlags.length === 0) {
    return { error: '--nth only applies to --role/--name/--selector targeting' }
  }

  if (hasRef) return { target: { ref: String(args.ref) } }

  if (hasCoord) {
    if (args.x === undefined || args.y === undefined) {
      return { error: 'a coordinate target needs both --x and --y' }
    }
    const x = Number(args.x)
    const y = Number(args.y)
    if (Number.isNaN(x) || Number.isNaN(y)) {
      return { error: `--x and --y must be numbers (got ${args.x}, ${args.y})` }
    }
    return { target: { x, y } }
  }

  if (semanticFlags.length > 0) {
    const target: Record<string, unknown> = {}
    for (const flag of semanticFlags) {
      if (typeof args[flag] !== 'string') return { error: `--${flag} needs a value` }
      target[flag] = args[flag]
    }
    if (args.nth !== undefined) {
      const nth = Number(args.nth)
      if (!Number.isInteger(nth) || nth < 0) {
        return { error: `--nth must be a non-negative integer (got ${args.nth})` }
      }
      target.nth = nth
    }
    return { target }
  }

  return { error: '--role/--name/--selector, --ref, or both --x and --y is required' }
}

export interface EnvelopeBuildResult {
  request?: ControlRequest
  error?: string
}

/**
 * `command`/`args` are exactly what a caller sent (untyped wire input, like
 * everything else this socket receives); `paneId` is this caller's own pane
 * (from its environment, never the caller's own claim over the wire — see
 * PluginControlRequest's doc) and `cwd` is the caller's own working
 * directory, used only to resolve `path`-typed flags.
 */
export function buildRequestFromEnvelope(
  command: string,
  args: Record<string, unknown>,
  paneId: string,
  cwd: string
): EnvelopeBuildResult {
  const spec = controlSpecForCommand(command)
  if (!spec) {
    return { error: `unknown command: ${command || '(none)'} — run capabilities to list them` }
  }

  const known = knownFlagsFor(spec)
  for (const flag of Object.keys(args)) {
    if (!known.has(flag)) {
      const valid = [...known].map((f) => `--${f}`).join(', ') || '(none)'
      return { error: `unknown flag --${flag} for ${command}; accepts: ${valid}` }
    }
  }

  // The target-compose flags (ref/x/y/role/name/selector/nth) are declared in
  // `spec.flags` only so `describe` documents them — `composeElementTarget`
  // below is their sole authority for both validation and coercion. Running
  // them through the generic per-flag loop too would double-validate them
  // with a different (looser) numeric check, and — worse — write each one as
  // a stray top-level wire field alongside the composed `target`, which the
  // wire schema's `additionalProperties: false` would then refuse outright.
  const composedFlagNames: readonly string[] =
    spec.targetCompose === 'elementTarget' ? TARGET_FLAG_NAMES : []

  const request: Record<string, unknown> = { type: spec.verb, paneId }
  for (const [flag, def] of Object.entries(spec.flags ?? {})) {
    if (composedFlagNames.includes(flag)) continue
    const raw = args[flag] === undefined ? def.default : args[flag]
    if (raw === undefined) {
      if (def.required) {
        return { error: `--${flag} is required${def.type === 'json' ? ' (JSON)' : ''}` }
      }
      continue
    }
    // `parseArgs` (tabs-ctl) turns a flag given no value into `true` — a
    // bare `--flag` at the end of argv, or immediately followed by another
    // flag. That's the right wire value for a `boolean` flag (that's what a
    // bare boolean switch means) and for a `path` flag (bare means "generate
    // one" — see the `path` branch below). For every other type it means the
    // caller forgot the value, and letting it through silently corrupted the
    // request instead: `Number(true)` is `1` (a bare `--timeout` sent
    // `timeoutMs: 1`, not "no timeout"), and a bare `--ref`/`--x`/`--y`/
    // `--nth` — handled below, in composeElementTarget — did the same for a
    // target. Refuse it here, once, for every flag type that needs a real
    // value.
    if (raw === true && def.type !== 'boolean' && def.type !== 'path') {
      return { error: `--${flag} needs a value` }
    }
    if (def.enum && !def.enum.includes(raw as string)) {
      return { error: `--${flag} must be one of ${def.enum.join(', ')} (got ${raw})` }
    }

    const key = def.wire ?? flag
    if (def.type === 'number') {
      const value = Number(raw)
      if (Number.isNaN(value)) return { error: `--${flag} must be a number (got ${raw})` }
      if (def.min !== undefined && value < def.min) {
        return { error: `--${flag} must be at least ${def.min} (got ${raw})` }
      }
      request[key] = value
    } else if (def.type === 'boolean') {
      // `value` lets a flag *invert* onto the wire (capture-bodies --off →
      // enabled: false); the wire default stays "flag absent, field absent".
      request[key] = def.value !== undefined ? def.value : true
    } else if (def.type === 'csv') {
      request[key] = String(raw).split(',').filter(Boolean)
    } else if (def.type === 'json') {
      try {
        request[key] = JSON.parse(raw as string)
      } catch (error) {
        return { error: `--${flag} is not valid JSON: ${(error as Error).message}` }
      }
    } else if (def.type === 'path') {
      // Bare `--out` (no value) parses as `true` client-side, which means
      // "generate one" and must ride the wire as `true`, not a string — the
      // same two-form contract every path-taking verb has always had. A real
      // value is resolved against the caller's own cwd, never main's.
      request[key] = raw === true ? true : resolvePath(cwd, String(raw))
    } else {
      request[key] = raw
    }
  }

  if (spec.targetCompose === 'elementTarget') {
    const composed = composeElementTarget(args)
    if ('error' in composed) return composed
    request.target = composed.target
  }

  return { request: request as ControlRequest }
}
