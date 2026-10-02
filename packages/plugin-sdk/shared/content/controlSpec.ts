import type { JsonSchema } from '../jsonSchema'

/**
 * How one CLI flag becomes one field of a verb's wire request — the
 * declarative table `tabs-ctl` used to hand-roll per verb (`buildRequest`'s
 * `COMMANDS` table) and main's envelope coercion now reads instead (see
 * src/main/controlEnvelope.ts). A flag's own name is its key in
 * `ControlVerbSpec.flags`; everything else here is how to turn what the
 * caller typed into a wire value.
 */
export interface FlagSpec {
  /** The wire field this flag maps to, if it differs from the flag's own name (e.g. `max-length` → `maxLength`). */
  wire?: string
  /** Reject the call when this flag is absent. */
  required?: boolean
  /**
   * How the caller's string value is coerced: `string` (default, passed
   * through), `number`, `boolean` (a bare flag, or `--flag=false` to invert
   * it — see `value` below), `json` (parsed, refused if malformed), `csv`
   * (split on commas), or `path` (resolved against the caller's `cwd`, which
   * the envelope carries for exactly this — see `PluginControlRequest`'s
   * doc). A `path` flag's bare/`true` form still means "generate one", the
   * same two-form contract every path-taking verb has always had.
   */
  type?: 'string' | 'number' | 'boolean' | 'json' | 'csv' | 'path'
  /** Allowed values, checked after coercion. */
  enum?: readonly string[]
  /** Numeric floor, rejected below it. Only for floors the app doesn't already clamp (documented app-side clamps, like waitFor's `timeout`, carry none). */
  min?: number
  /** Applied when the flag is absent. */
  default?: unknown
  /** The literal wire value a *present* boolean flag maps to, when it isn't `true` (capture-bodies' `--off` → `enabled: false`). */
  value?: unknown
  /** A short stand-in for this flag's value in `describe`'s usage line (`--out <path>`), when the flag name alone reads badly. */
  placeholder?: string
  /** One line, surfaced by the `describe` verb — what an agent reads to learn what this flag is for. */
  doc?: string
}

/**
 * One verb's complete, runtime-readable description: what to call it from
 * the CLI, how its flags become a wire request, what that request must look
 * like structurally, and what it answers with. A package's manifest declares
 * one of these per verb it adds to the protocol (`ContentTypeManifest.controlVerbs`);
 * core's own six live in `src/shared/coreControlSpec.ts`.
 *
 * This is what makes the protocol's surface — every command, its flags, its
 * wire shape — readable off the running app rather than off a hand-written
 * CLI script: `capabilities`/`describe` (src/main/externalControl.ts) serve
 * these directly, and `tabs-ctl` ships with none of this knowledge at all
 * (see resources/skills/tabs/scripts/tabs-ctl).
 */
export interface ControlVerbSpec {
  /** The wire verb name — must equal `wire.properties.type.const`, checked by the reconciliation test. */
  verb: string
  /** The CLI command name (kebab-case), e.g. `read-page` for the `readPage` verb. */
  command: string
  /** One line: what this command does, shown in `describe`'s compact index. */
  summary: string
  /** This command's flags, keyed by flag name. Absent for a verb that takes only the implicit `--pane`. */
  flags?: Record<string, FlagSpec>
  /**
   * Composes several flags into one wire field the flag table can't express
   * on its own — today, exactly one strategy exists: `'elementTarget'`,
   * which builds the wire `target` field from `--ref`, `--x`/`--y`, or
   * `--role`/`--name`/`--selector`/`--nth` (mutually exclusive), matching
   * `ElementTarget` in packages/plugin-browser/shared/externalControl.ts. A
   * second compose shape, if one is ever needed, gets its own tag rather
   * than a generic DSL — there is exactly one instance of this problem
   * today, and generalizing it now would be speculative.
   */
  targetCompose?: 'elementTarget'
  /**
   * JSON Schema for the assembled wire request, checked once by core before
   * dispatch (src/main/externalControl.ts) — the structural half of
   * validation; flag-level coercion (required/enum/min/type) runs first and
   * produces the friendlier, flag-named messages (see controlEnvelope.ts).
   * Deliberately excludes `paneId`: the app fills it in from the caller's
   * environment, and a batch sub-request has it overwritten regardless — the
   * reconciliation test refuses a schema that names it.
   */
  wire: JsonSchema
  /**
   * The result shape, for `describe`'s documentation only — never validated
   * against an actual response. A loose shorthand (a string names a
   * primitive type, `[X]` an array of `X`, a plain object nests), the same
   * one `describe`'s formatter has always used.
   */
  result?: Record<string, unknown>
  /** Whether this verb may appear inside a `batch`. Defaults to true — see `MainControlVerb.batchable`'s doc for why a verb opts out. */
  batchable?: boolean
}
