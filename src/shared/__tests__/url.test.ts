import { describe, expect, it } from 'vitest'
import { isSafeExternalUrl } from '../url'

describe('isSafeExternalUrl', () => {
  it('accepts http and https URLs', () => {
    expect(isSafeExternalUrl('http://example.com')).toBe(true)
    expect(isSafeExternalUrl('https://example.com/docs?q=1#frag')).toBe(true)
    expect(isSafeExternalUrl('https://localhost:3000')).toBe(true)
  })

  it('accepts mailto links', () => {
    expect(isSafeExternalUrl('mailto:someone@example.com')).toBe(true)
  })

  it('rejects protocols that would run code or read the filesystem', () => {
    expect(isSafeExternalUrl('javascript:alert(1)')).toBe(false)
    expect(isSafeExternalUrl('file:///etc/passwd')).toBe(false)
    expect(isSafeExternalUrl('data:text/html,<script>alert(1)</script>')).toBe(false)
    expect(isSafeExternalUrl('vbscript:msgbox(1)')).toBe(false)
  })

  it('rejects custom schemes that could hand off to another installed app', () => {
    expect(isSafeExternalUrl('ssh://root@example.com')).toBe(false)
    expect(isSafeExternalUrl('smb://example.com/share')).toBe(false)
  })

  it('rejects anything that is not a parseable absolute URL', () => {
    expect(isSafeExternalUrl('example.com')).toBe(false)
    expect(isSafeExternalUrl('/etc/passwd')).toBe(false)
    expect(isSafeExternalUrl('')).toBe(false)
    expect(isSafeExternalUrl('not a url at all')).toBe(false)
  })

  it('is case-insensitive about the scheme, as URL parsing already normalizes it', () => {
    expect(isSafeExternalUrl('HTTPS://example.com')).toBe(true)
    expect(isSafeExternalUrl('JavaScript:alert(1)')).toBe(false)
  })
})
