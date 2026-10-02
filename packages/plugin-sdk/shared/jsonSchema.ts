/**
 * A small, process-agnostic JSON Schema evaluator over exactly the subset the
 * external-control protocol needs: object/string/number/boolean/array,
 * `properties`/`required`/`additionalProperties`, `enum`/`const`/`minimum`,
 * a shallow `items`, and `oneOf`/`anyOf` (used by `ControlVerbSpec.wire` for
 * the element-target union — see `ElementTarget` in
 * packages/plugin-browser/shared/externalControl.ts).
 *
 * Deliberately no library: this is not a general-purpose validator, only what
 * a verb's `wire` schema (src/shared/content/controlSpec.ts) actually uses —
 * a handful of combinators over plain data, not the full JSON Schema spec
 * (no `$ref`, no `patternProperties`, no numeric multipleOf, etc.). Adding a
 * feature here should mean the protocol genuinely needs it, not "JSON Schema
 * has one."
 */
export interface JsonSchema {
  type?: 'object' | 'string' | 'number' | 'boolean' | 'array'
  properties?: Record<string, JsonSchema>
  required?: readonly string[]
  /** Refuses a property not named in `properties` — the closed-object check every wire schema uses. */
  additionalProperties?: boolean
  enum?: readonly string[]
  const?: string
  minimum?: number
  /** Every element must match this schema — shallow, since nothing in this protocol nests arrays of arrays. */
  items?: JsonSchema
  /** Exactly one branch must match — the shape `ElementTarget` needs (ref | coordinate | semantic). */
  oneOf?: readonly JsonSchema[]
  /** At least one branch must match — used inside a `oneOf` branch for "at least one of role/name/selector". */
  anyOf?: readonly JsonSchema[]
}

/** JSON's own type vocabulary, distinguishing array from object (`typeof` alone conflates them) and null from object. */
function jsonTypeOf(value: unknown): string {
  if (Array.isArray(value)) return 'array'
  if (value === null) return 'null'
  return typeof value
}

/**
 * Validates `value` against `schema`, returning the first violation as a
 * plain-language message naming `path`, or null when it validates.
 *
 * Checks run in a fixed order — const/enum, type, numeric bounds, object
 * shape, array items, then the combinators — so two runs against the same
 * invalid value always report the same thing, which is what makes error
 * messages from this function reproducible in a test.
 */
export function validateJsonSchema(
  value: unknown,
  schema: JsonSchema,
  path = 'value'
): string | null {
  if (schema.const !== undefined && value !== schema.const) {
    return `${path} must be ${JSON.stringify(schema.const)} (got ${JSON.stringify(value)})`
  }
  if (schema.enum && !schema.enum.includes(value as string)) {
    return `${path} must be one of ${schema.enum.join(', ')} (got ${JSON.stringify(value)})`
  }
  if (schema.type && jsonTypeOf(value) !== schema.type) {
    return `${path} must be a ${schema.type} (got ${jsonTypeOf(value)})`
  }
  if (schema.type === 'number' && schema.minimum !== undefined) {
    const num = value as number
    if (num < schema.minimum) return `${path} must be at least ${schema.minimum} (got ${num})`
  }
  if (schema.type === 'object') {
    const obj = value as Record<string, unknown>
    for (const key of schema.required ?? []) {
      if (!(key in obj)) return `${path} is missing required field "${key}"`
    }
    if (schema.additionalProperties === false) {
      const known = new Set(Object.keys(schema.properties ?? {}))
      for (const key of Object.keys(obj)) {
        if (!known.has(key)) return `${path} has an unexpected field "${key}"`
      }
    }
    for (const [key, propSchema] of Object.entries(schema.properties ?? {})) {
      if (key in obj) {
        const error = validateJsonSchema(obj[key], propSchema, `${path}.${key}`)
        if (error) return error
      }
    }
  }
  if (schema.type === 'array' && schema.items) {
    for (const [index, item] of (value as unknown[]).entries()) {
      const error = validateJsonSchema(item, schema.items, `${path}[${index}]`)
      if (error) return error
    }
  }
  if (schema.oneOf) {
    const matches = schema.oneOf.filter(
      (branch) => validateJsonSchema(value, branch, path) === null
    )
    if (matches.length !== 1) {
      return `${path} must match exactly one of its allowed shapes (matched ${matches.length})`
    }
  }
  if (schema.anyOf) {
    const matched = schema.anyOf.some((branch) => validateJsonSchema(value, branch, path) === null)
    if (!matched) return `${path} must match at least one of its allowed shapes`
  }
  return null
}
