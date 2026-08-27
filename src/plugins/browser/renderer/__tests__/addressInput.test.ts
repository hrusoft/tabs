import { describe, expect, it } from 'vitest'
import { resolveAddressInput } from '../addressInput'

describe('resolveAddressInput', () => {
  it('prepends https:// to a bare domain', () => {
    expect(resolveAddressInput('example.com')).toBe('https://example.com')
  })

  it('prepends https:// to a bare domain with a path', () => {
    expect(resolveAddressInput('example.com/docs')).toBe('https://example.com/docs')
  })

  it('passes an already-schemed URL through unchanged', () => {
    expect(resolveAddressInput('http://example.com')).toBe('http://example.com')
    expect(resolveAddressInput('https://example.com')).toBe('https://example.com')
    expect(resolveAddressInput('about:blank')).toBe('about:blank')
  })

  it('treats localhost with a port as a URL, not a search', () => {
    expect(resolveAddressInput('localhost:3000')).toBe('https://localhost:3000')
  })

  it('treats a multi-word phrase as a search query', () => {
    expect(resolveAddressInput('claude code docs')).toBe(
      'https://www.google.com/search?q=claude%20code%20docs'
    )
  })

  it('treats a single word with no dot as a search query', () => {
    expect(resolveAddressInput('cats')).toBe('https://www.google.com/search?q=cats')
  })

  it('treats a dotted phrase containing a space as a search query', () => {
    expect(resolveAddressInput('example.com is great')).toBe(
      'https://www.google.com/search?q=example.com%20is%20great'
    )
  })

  it('returns null for blank input', () => {
    expect(resolveAddressInput('')).toBeNull()
    expect(resolveAddressInput('   ')).toBeNull()
  })

  it('trims surrounding whitespace before resolving', () => {
    expect(resolveAddressInput('  example.com  ')).toBe('https://example.com')
  })
})
