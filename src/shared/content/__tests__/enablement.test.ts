import { describe, expect, it } from 'vitest'
import { DEFAULT_SETTINGS, migrateSettings } from '../../settings'
import {
  isContentTypeEnabled,
  sanitizeDisabledContentTypes,
  togglableContentTypes
} from '../enablement'
import { CONTENT_TYPE_MANIFESTS } from '../registry'

describe('isContentTypeEnabled', () => {
  it('treats a type absent from the list as enabled', () => {
    // The property that lets a content type ship later without every existing
    // settings.json having to name it.
    expect(isContentTypeEnabled([], 'terminal')).toBe(true)
    expect(isContentTypeEnabled(['browser'], 'terminal')).toBe(true)
  })

  it('treats a listed type as disabled', () => {
    expect(isContentTypeEnabled(['browser'], 'browser')).toBe(false)
  })

  it('honours the list for a type no census names', () => {
    // Deliberate, not incidental: a plugin type whose loader has not run yet
    // must keep its disabled entry, and the test tiers' stub content type
    // appears in no census — this is what lets them drive the real gate.
    expect(isContentTypeEnabled(['stub'], 'stub')).toBe(false)
  })

  it('ships with every type enabled', () => {
    for (const manifest of CONTENT_TYPE_MANIFESTS) {
      expect(isContentTypeEnabled(DEFAULT_SETTINGS.disabledContentTypes, manifest.type)).toBe(true)
    }
  })
})

describe('sanitizeDisabledContentTypes', () => {
  it('keeps a well-formed list', () => {
    expect(sanitizeDisabledContentTypes(['terminal', 'browser'])).toEqual(['terminal', 'browser'])
  })

  it('drops duplicates', () => {
    expect(sanitizeDisabledContentTypes(['browser', 'browser'])).toEqual(['browser'])
  })

  it('degrades any non-list to an empty list rather than throwing', () => {
    // Totality matters here specifically: a throw out of migrateSettings falls
    // back to DEFAULT_SETTINGS wholesale, and the next debounced save persists
    // that wipe (see loadSettings in src/main/settings.ts).
    for (const hostile of [undefined, null, 'browser', 42, {}, { browser: true }]) {
      expect(sanitizeDisabledContentTypes(hostile)).toEqual([])
    }
  })

  it('drops non-string entries from a list', () => {
    expect(sanitizeDisabledContentTypes(['browser', 7, null, {}, 'terminal'])).toEqual([
      'browser',
      'terminal'
    ])
  })

  it('returns a fresh array, so no caller can come to alias another', () => {
    const input = ['browser']
    expect(sanitizeDisabledContentTypes(input)).not.toBe(input)
    expect(sanitizeDisabledContentTypes([])).not.toBe(DEFAULT_SETTINGS.disabledContentTypes)
  })
})

describe('togglableContentTypes', () => {
  it('offers exactly the census entries that allow it', () => {
    expect(togglableContentTypes()).toEqual(
      CONTENT_TYPE_MANIFESTS.filter((manifest) => manifest.canDisable)
    )
  })

  it('is not vacuous — the built-ins really are togglable', () => {
    expect(togglableContentTypes().map((manifest) => manifest.type)).toEqual([
      'terminal',
      'browser',
      'gitTree'
    ])
  })
})

describe('migrateSettings, for this key', () => {
  it('defaults a file that predates the key to nothing disabled', () => {
    expect(migrateSettings({ showNavFlash: false }).disabledContentTypes).toEqual([])
  })

  it('carries a well-formed list through', () => {
    expect(migrateSettings({ disabledContentTypes: ['browser'] }).disabledContentTypes).toEqual([
      'browser'
    ])
  })

  it('sanitizes a hostile value instead of letting it through as-is', () => {
    // Without the explicit sanitize call this key would ride through
    // migrateSettings' `...rest` spread untouched, exactly as written.
    expect(migrateSettings({ disabledContentTypes: 'browser' }).disabledContentTypes).toEqual([])
    expect(migrateSettings({ disabledContentTypes: [1, 'browser'] }).disabledContentTypes).toEqual([
      'browser'
    ])
  })
})
