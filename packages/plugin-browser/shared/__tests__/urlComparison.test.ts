import { describe, expect, it } from 'vitest'
import { isTrivialUrlChange } from '../urlComparison'

/**
 * Pins the rule behind the navigation verbs' `redirected` flag. The stakes:
 * too loose and an auth bounce to /dashboard reads as success (the bug the
 * flag exists to catch), too strict and every http→https upgrade nags a
 * caller who got exactly the page they asked for.
 */
describe('isTrivialUrlChange', () => {
  const base = 'http://127.0.0.1:5100'

  it('treats the same URL as trivial', () => {
    expect(isTrivialUrlChange(`${base}/page`, `${base}/page`)).toBe(true)
  })

  it('ignores a trailing slash, in both directions', () => {
    expect(isTrivialUrlChange(`${base}/docs`, `${base}/docs/`)).toBe(true)
    expect(isTrivialUrlChange(`${base}/docs/`, `${base}/docs`)).toBe(true)
    // A bare origin and its root path are the same place.
    expect(isTrivialUrlChange(base, `${base}/`)).toBe(true)
  })

  it('ignores query parameters the destination added', () => {
    expect(isTrivialUrlChange(`${base}/page`, `${base}/page?session=abc`)).toBe(true)
    expect(isTrivialUrlChange(`${base}/page?a=1`, `${base}/page?a=1&b=2`)).toBe(true)
  })

  it('flags a requested query parameter that was dropped or changed', () => {
    // The deep-link-in-query case: the redirect discarded what was asked for.
    expect(isTrivialUrlChange(`${base}/app?next=%2Fdeep`, `${base}/app`)).toBe(false)
    expect(isTrivialUrlChange(`${base}/search?q=a`, `${base}/search?q=b`)).toBe(false)
    // A repeated parameter losing one of its values is a loss too.
    expect(isTrivialUrlChange(`${base}/list?tag=x&tag=y`, `${base}/list?tag=x`)).toBe(false)
  })

  it('ignores the scheme, so an https upgrade is not a redirect', () => {
    expect(isTrivialUrlChange('http://example.com/page', 'https://example.com/page')).toBe(true)
  })

  it('ignores the fragment', () => {
    expect(isTrivialUrlChange(`${base}/page`, `${base}/page#section`)).toBe(true)
  })

  it('flags a different path — the auth-bounce shape', () => {
    expect(isTrivialUrlChange(`${base}/screening`, `${base}/dashboard`)).toBe(false)
    // A subpath is still a different place, not a variant of the parent.
    expect(isTrivialUrlChange(`${base}/docs`, `${base}/docs/intro`)).toBe(false)
  })

  it('flags a different host or explicit port', () => {
    expect(isTrivialUrlChange('http://app.example.com/', 'http://login.example.com/')).toBe(false)
    expect(isTrivialUrlChange('http://localhost:3000/', 'http://localhost:4000/')).toBe(false)
  })

  it('falls back to plain string comparison for URLs that do not parse', () => {
    expect(isTrivialUrlChange('about:blank', 'about:blank')).toBe(true)
    expect(isTrivialUrlChange('not a url', 'not a url')).toBe(true)
    expect(isTrivialUrlChange('not a url', 'also not a url')).toBe(false)
  })
})
