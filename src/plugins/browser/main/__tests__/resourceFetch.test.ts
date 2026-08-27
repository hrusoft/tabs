import { describe, expect, it } from 'vitest'
import { MAX_RESOURCE_BYTES } from '../../shared/externalControl'
import { decodeDataUrl, extensionFor } from '../resourceFetch'
import { isAllowedResourceUrl } from '../urlPolicy'

/**
 * The pure halves of save-resource's fetch layer: the read-from scheme policy,
 * data: decoding, and extension inference. The scheme-routed fetches (net, CDP)
 * are the subject of the Electron-tier spec — here we pin only what is testable
 * without a guest, which is where the security-relevant decisions live.
 */

describe('isAllowedResourceUrl', () => {
  it('allows the four read-from schemes', () => {
    expect(isAllowedResourceUrl('http://example.com/a.png')).toBe(true)
    expect(isAllowedResourceUrl('https://example.com/a.png')).toBe(true)
    expect(isAllowedResourceUrl('blob:http://example.com/uuid')).toBe(true)
    expect(isAllowedResourceUrl('data:text/plain,hi')).toBe(true)
  })

  it('refuses file: and every other scheme — the load-bearing overlap with the http(s) net route', () => {
    expect(isAllowedResourceUrl('file:///etc/hosts')).toBe(false)
    expect(isAllowedResourceUrl('chrome://version')).toBe(false)
    expect(isAllowedResourceUrl('javascript:alert(1)')).toBe(false)
    expect(isAllowedResourceUrl('ftp://example.com/x')).toBe(false)
    expect(isAllowedResourceUrl('not a url')).toBe(false)
  })
})

describe('decodeDataUrl', () => {
  it('decodes a base64 data: URL and reports its mediatype', () => {
    const bytes = new Uint8Array([1, 2, 3, 4])
    const url = `data:application/pdf;base64,${Buffer.from(bytes).toString('base64')}`
    const result = decodeDataUrl(url)
    if ('error' in result) throw new Error(result.error)
    expect([...result.bytes]).toEqual([1, 2, 3, 4])
    expect(result.contentType).toBe('application/pdf')
  })

  it('decodes a percent-encoded (non-base64) data: URL', () => {
    const result = decodeDataUrl('data:text/plain,Hello%20%26%20bye')
    if ('error' in result) throw new Error(result.error)
    expect(Buffer.from(result.bytes).toString('utf8')).toBe('Hello & bye')
    expect(result.contentType).toBe('text/plain')
  })

  it('rejects a malformed data: URL rather than guessing', () => {
    expect(decodeDataUrl('data:nothinghere')).toEqual({ error: 'malformed data: URL' })
  })

  it('refuses a data: URL over the byte cap', () => {
    const big = Buffer.alloc(MAX_RESOURCE_BYTES + 1).toString('base64')
    const result = decodeDataUrl(`data:application/octet-stream;base64,${big}`)
    expect('error' in result && result.error).toContain('too large')
  })
})

describe('extensionFor', () => {
  const empty = new Uint8Array()

  it('prefers a known content type', () => {
    expect(extensionFor('https://x/y', 'application/pdf', empty)).toBe('pdf')
    expect(extensionFor('https://x/y', 'image/jpeg', empty)).toBe('jpg')
    expect(extensionFor('https://x/y', 'IMAGE/PNG', empty)).toBe('png')
  })

  it('sniffs magic bytes when the type is unknown — the blob case, where CDP reports none', () => {
    expect(
      extensionFor('blob:https://x/uuid', undefined, new Uint8Array([0x25, 0x50, 0x44, 0x46]))
    ).toBe('pdf')
    expect(
      extensionFor('blob:https://x/uuid', undefined, new Uint8Array([0x89, 0x50, 0x4e, 0x47]))
    ).toBe('png')
    expect(extensionFor('blob:https://x/uuid', undefined, new Uint8Array([0xff, 0xd8, 0xff]))).toBe(
      'jpg'
    )
  })

  it('falls back to the URL path extension, then to bin', () => {
    expect(extensionFor('https://x/report.csv', undefined, empty)).toBe('csv')
    expect(extensionFor('https://x/nofile', undefined, empty)).toBe('bin')
    expect(extensionFor('blob:https://x/uuid', undefined, empty)).toBe('bin')
  })
})
