/**
 * What a content type contributes to the persisted Settings shape — the
 * shared-side sibling of the renderer's contentRegistry and the main
 * process's close-blocker registry. It lives here rather than in either
 * process because main's loadSettings runs synchronously before any window
 * exists, so a type's defaults and merge must be importable with no DOM,
 * React, or Electron dependency. Today the descriptors are a static list
 * (CONTENT_TYPE_SETTINGS in settings.ts); a plugin loader could populate
 * that list dynamically without this interface changing.
 */
export interface ContentTypeSettingsDescriptor<T = unknown> {
  /** Matches ContentNode.type / the contentRegistry key. */
  type: string
  /** Blob a fresh install starts with. A shared singleton — never mutate it. */
  defaults: T
  /**
   * Total merge of whatever was persisted over the defaults: must accept any
   * unknown value (undefined, null, a string, an array, a partial object)
   * without throwing, and always return a complete T. Throwing here silently
   * wipes the user's whole settings file — `migrate` below carries the full
   * causal chain once, for both hooks.
   */
  merge: (persisted: unknown) => T
  /**
   * Hoists this type's settings out of an older file shape, before `merge`
   * runs. Called with the whole parsed root and whatever this type's
   * namespaced blob currently holds — often nothing, on a file written before
   * `contentTypes` existed.
   *
   * Returns the blob to merge plus `consumed`: the root keys this type has
   * taken ownership of, which core then strips so they stop riding through
   * into the top level of Settings. The two come back together so they cannot
   * drift apart — a key hoisted but not declared would be persisted forever at
   * both levels, and one declared but not hoisted would be silently dropped.
   * Name every key the type owns, whether or not this particular file had one:
   * `consumed` means "mine", not "found".
   *
   * Convention, matching migrateSettings' own doc: fill only namespaced keys
   * that are ABSENT, so a namespaced value always beats a legacy one.
   *
   * MUST BE TOTAL, exactly like `merge` above — and the consequence is worth
   * spelling out rather than leaving as "don't throw". `loadSettings`
   * (main/settings.ts) wraps only the file read and the JSON parse, so a throw
   * from here escapes into that catch, which answers by returning
   * DEFAULT_SETTINGS *wholesale*: a hand-tuned 20-swatch terminal palette
   * replaced by the shipped one, no error shown to anyone, and the next
   * debounced save writes that wipe over the user's file. Nothing recovers it.
   * So take every value out of the root through `asRecord` (or a `typeof`
   * check) rather than trusting its shape — the file may have been
   * hand-edited, truncated mid-write, or produced by a version that never
   * shipped.
   */
  migrate?: (
    legacyRoot: Record<string, unknown>,
    blob: unknown
  ) => { blob: unknown; consumed: readonly string[] }
  /**
   * Keys forced onto this type's blob in the *baseline* settings an e2e run
   * starts from (see e2eSettingsBaseline in main/settings.ts) — for a shipping
   * default the suite structurally cannot work against.
   *
   * Declared by the type rather than named in main's settings module, which is
   * the one place that has to stay blob-agnostic: it runs before any window
   * exists and every type's settings pass through it. Baseline only, never
   * applied to a write, so an explicit `settings:set` from a test still wins
   * and can cover the shipping behavior.
   */
  testBaseline?: Partial<T>
}

/**
 * `value` as a plain-object record, or {} for anything else. The guard for
 * writing a total merge: spreading a non-object isn't a throw, but it isn't
 * safe either (spreading a string explodes it into index keys; null and
 * arrays have their own surprises), so every slot a merge reads out of
 * persisted data should pass through here first.
 */
export function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}
