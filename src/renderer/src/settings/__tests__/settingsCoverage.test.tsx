import { DEFAULT_SETTINGS } from '@shared/settings'
import { expect, test } from 'vitest'
import { GENERAL_SECTIONS } from '../GeneralSettings'
import { PANES_SECTIONS } from '../PanesSettings'

/**
 * Every flat core setting has a row on *some* row-driven page. The row types
 * check one direction (a row can't name a key that doesn't exist); nothing
 * checks the other, so a Settings key added without a control would ship
 * silently invisible. The three exemptions each have a home of their own:
 * `shortcuts` is the Keyboard page, `disabledContentTypes` is the Content
 * types section on the General page, and `contentTypes` is each type's own
 * settings page.
 *
 * Spans both GENERAL_SECTIONS and PANES_SECTIONS rather than living inside
 * either page's own test file, since the two pages jointly own the flat
 * Settings surface — see GeneralSettings.tsx's comment on GENERAL_SECTIONS.
 */
test('every flat core setting has a row on the General or Panes & Tabs page', () => {
  const covered = new Set<string>(
    [...GENERAL_SECTIONS, ...PANES_SECTIONS].flatMap((section) =>
      section.rows.map((row) => row.key)
    )
  )
  const exempt = new Set(['shortcuts', 'disabledContentTypes', 'contentTypes'])
  const missing = Object.keys(DEFAULT_SETTINGS).filter(
    (key) => !exempt.has(key) && !covered.has(key)
  )

  expect(missing).toEqual([])
})
