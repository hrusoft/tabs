import { describe, expect, it } from 'vitest'
import { PLUGIN_PACKAGES } from '../../../plugins/index'
import { CONTENT_TYPE_SETTINGS, DEFAULT_SETTINGS } from '../../settings'
import type { ContentTypeId } from '../registry'
import { CONTENT_TYPE_MANIFESTS } from '../registry'

/**
 * The census's own invariants — the ones nothing else can check.
 *
 * One exists because the alternative was an ESM cycle rather than because a
 * test is the nicer design: a type's settings descriptor cannot import its
 * manifest's `type` constant (see the terminal's shared/manifest.ts), so the
 * one restatement of the string inside a package is guarded here.
 */
describe('the content-type census', () => {
  it('is the manifests in PLUGIN_PACKAGES order, folder name as type id', () => {
    // The census itself throws at module evaluation on any list/folder
    // mismatch (see buildCensus); what this pins is the part a throw cannot:
    // that the order consumers observe really is the list's, since the
    // pane-header button order rides on it.
    expect(CONTENT_TYPE_MANIFESTS.map((manifest) => manifest.type)).toEqual([...PLUGIN_PACKAGES])
  })

  it('agrees with each settings descriptor about its own type string', () => {
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      if (!manifest.settings) continue
      expect(manifest.settings.type).toBe(manifest.type)
    }
  })

  it('derives CONTENT_TYPE_SETTINGS from exactly the manifests that declare one', () => {
    expect(CONTENT_TYPE_SETTINGS.map((descriptor) => descriptor.type)).toEqual(
      CONTENT_TYPE_MANIFESTS.filter((manifest) => manifest.settings).map(
        (manifest) => manifest.type
      )
    )
  })

  it('seeds a defaults blob for every type that declares settings', () => {
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      if (!manifest.settings) continue
      expect(DEFAULT_SETTINGS.contentTypes[manifest.type]).toBe(manifest.settings.defaults)
    }
  })

  /**
   * `ContentTypeId` derives from PLUGIN_PACKAGES (src/plugins/index.ts) and
   * stays a literal union only while that tuple keeps its `as const` — drop
   * it and the union collapses to `string`, at which point everything keyed
   * or narrowed by it silently degrades. Nothing else would notice — the app
   * builds and runs identically — so this is a type-level assertion with a
   * trivial runtime body: the failure it guards is a *typecheck* failure, and
   * `npm run typecheck` is what catches it.
   */
  it('keeps ContentTypeId a literal union derived from the one list', () => {
    // Collapses to `never` — making the assignment below an error — if T has
    // widened to `string`.
    type LiteralOnly<T extends string> = string extends T ? never : T

    // Written out rather than derived, deliberately and uniquely in this file:
    // deriving from the list would make the assertion true by construction and
    // check nothing. Adding a content type means editing this line, and the
    // runtime expectation below is what says so.
    const everyType: LiteralOnly<ContentTypeId>[] = ['terminal', 'browser', 'gitTree']

    // @ts-expect-error the list has no such type, which is the half that stops
    // anything keyed by ContentTypeId holding an entry nobody declared.
    const notAType: ContentTypeId = 'no-such-type'

    expect([...everyType].sort()).toEqual(
      CONTENT_TYPE_MANIFESTS.map((manifest) => manifest.type).sort()
    )
    expect(notAType).toBe('no-such-type')
  })
})
