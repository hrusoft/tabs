import { describe, expect, it } from 'vitest'
import type { PageElement } from '../../shared/externalControl'
import { findElements, scoreElement } from '../findElements'

function element(partial: Partial<PageElement> & { name: string }): PageElement {
  return {
    ref: 'e1',
    role: 'button',
    tag: 'button',
    rect: { x: 0, y: 0, width: 10, height: 10 },
    ...partial
  }
}

describe('scoreElement', () => {
  it('ranks an exact name above a prefix, a prefix above a substring', () => {
    const exact = scoreElement(element({ name: 'Save' }), 'Save')
    const prefix = scoreElement(element({ name: 'Save changes' }), 'Save')
    const substring = scoreElement(element({ name: 'Autosave draft' }), 'save')

    expect(exact).toBeGreaterThan(prefix)
    expect(prefix).toBeGreaterThan(substring)
    expect(substring).toBeGreaterThan(0)
  })

  it('is case- and whitespace-insensitive', () => {
    expect(scoreElement(element({ name: '  SAVE   CHANGES ' }), 'save changes')).toBe(1)
  })

  it('scores a partial token overlap below any direct substring match', () => {
    const tokens = scoreElement(element({ name: 'Submit the order form' }), 'submit form')
    const substring = scoreElement(element({ name: 'Autosave draft' }), 'save')

    expect(tokens).toBeGreaterThan(0)
    expect(tokens).toBeLessThan(substring)
  })

  it('ignores stop words rather than letting them match everything', () => {
    expect(scoreElement(element({ name: 'Delete account' }), 'the')).toBe(0)
  })

  it('returns 0 for an element sharing nothing with the description', () => {
    expect(scoreElement(element({ name: 'Delete account' }), 'newsletter signup')).toBe(0)
  })

  it('lets a named role corroborate a match but never create one', () => {
    const corroborated = scoreElement(element({ name: 'Save', role: 'button' }), 'save button')
    const roleOnly = scoreElement(element({ name: 'Delete', role: 'button' }), 'button')

    expect(corroborated).toBeGreaterThan(0)
    // Naming only the role matches nothing — otherwise "button" would return
    // every button on the page.
    expect(roleOnly).toBe(0)
  })

  it('scores an empty description as no match at all', () => {
    expect(scoreElement(element({ name: 'Save' }), '   ')).toBe(0)
  })
})

describe('findElements', () => {
  const elements = [
    element({ ref: 'e1', name: 'Cancel' }),
    element({ ref: 'e2', name: 'Save changes' }),
    element({ ref: 'e3', name: 'Save' }),
    element({ ref: 'e4', name: 'Delete account' })
  ]

  it('returns matches strongest first and drops non-matches', () => {
    const matches = findElements(elements, 'save')

    expect(matches.map((match) => match.element.ref)).toEqual(['e3', 'e2'])
    expect(matches[0]!.score).toBeGreaterThan(matches[1]!.score)
  })

  it('caps the result count', () => {
    expect(findElements(elements, 'save', 1)).toHaveLength(1)
    expect(findElements(elements, 'save', 0)).toHaveLength(0)
  })

  it('returns nothing rather than a weak guess when nothing matches', () => {
    expect(findElements(elements, 'checkout basket')).toEqual([])
  })
})
