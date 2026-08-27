import { describe, expect, it } from 'vitest'
import { compilePattern, createRingLog, patternFilterError } from '../ringLog'

interface Entry {
  seq: number
  text: string
}

describe('createRingLog', () => {
  it('assigns increasing sequence numbers from 1', () => {
    const log = createRingLog<Entry>(10)
    expect(log.add({ text: 'a' }).seq).toBe(1)
    expect(log.add({ text: 'b' }).seq).toBe(2)
  })

  it('evicts the oldest entries once capacity is exceeded', () => {
    const log = createRingLog<Entry>(3)
    for (const text of ['a', 'b', 'c', 'd', 'e']) log.add({ text })

    expect(log.list().map((entry) => entry.text)).toEqual(['c', 'd', 'e'])
  })

  it('keeps sequence numbers stable across eviction, so sinceSeq stays correct', () => {
    const log = createRingLog<Entry>(2)
    log.add({ text: 'a' })
    log.add({ text: 'b' })
    const third = log.add({ text: 'c' })

    // 'a' is gone, but 'c' is still seq 3 — a caller that had read up to 2
    // gets exactly what it hasn't seen, not a replay.
    expect(third.seq).toBe(3)
    expect(log.list(2).map((entry) => entry.text)).toEqual(['c'])
  })

  it('returns entries strictly after sinceSeq', () => {
    const log = createRingLog<Entry>(10)
    for (const text of ['a', 'b', 'c']) log.add({ text })

    expect(log.list(0).map((e) => e.text)).toEqual(['a', 'b', 'c'])
    expect(log.list(2).map((e) => e.text)).toEqual(['c'])
    expect(log.list(3)).toEqual([])
  })

  it('does not rewind sequence numbers on clear, so a stale sinceSeq cannot replay', () => {
    const log = createRingLog<Entry>(10)
    log.add({ text: 'old page' })
    log.add({ text: 'old page 2' })
    log.clear()
    const fresh = log.add({ text: 'new page' })

    expect(log.list()).toHaveLength(1)
    expect(fresh.seq).toBe(3)
    expect(log.list(2).map((e) => e.text)).toEqual(['new page'])
  })

  it('removes an entry by seq, reporting whether it was present', () => {
    const log = createRingLog<Entry>(10)
    log.add({ text: 'a' })
    const b = log.add({ text: 'b' })
    log.add({ text: 'c' })

    expect(log.remove(b.seq)).toBe(true)
    expect(log.list().map((entry) => entry.text)).toEqual(['a', 'c'])
    // Already gone — a second remove reports that rather than throwing.
    expect(log.remove(b.seq)).toBe(false)
  })

  it('reports an evicted entry as absent from remove, and never reuses its seq', () => {
    const log = createRingLog<Entry>(2)
    const a = log.add({ text: 'a' })
    log.add({ text: 'b' })
    log.add({ text: 'c' })

    expect(log.remove(a.seq)).toBe(false)
    expect(log.add({ text: 'd' }).seq).toBe(4)
  })

  it('hands back the stored object so an in-flight entry can be completed later', () => {
    const log = createRingLog<Entry>(10)
    const entry = log.add({ text: 'pending' })
    entry.text = 'done'

    expect(log.list()[0]!.text).toBe('done')
  })
})

describe('compilePattern', () => {
  it('matches everything when no pattern is given', () => {
    expect(compilePattern()('anything')).toBe(true)
    expect(compilePattern('')('anything')).toBe(true)
  })

  it('treats the pattern as a regular expression', () => {
    const matches = compilePattern('^GET')
    expect(matches('GET /api/users')).toBe(true)
    expect(matches('POST /api/users')).toBe(false)
  })

  it('falls back to a substring test when the pattern is not valid regex', () => {
    // An unbalanced group is a plausible thing to filter for literally.
    const matches = compilePattern('console.log(')
    expect(matches('console.log( x )')).toBe(true)
    expect(matches('console.warn(x)')).toBe(false)
  })
})

describe('patternFilterError', () => {
  it('is undefined for a valid pattern, and for no pattern at all', () => {
    expect(patternFilterError('^GET')).toBeUndefined()
    expect(patternFilterError(undefined)).toBeUndefined()
    expect(patternFilterError('')).toBeUndefined()
  })

  it('names the parse failure for an unterminated character class', () => {
    const error = patternFilterError('[')
    expect(error).toContain('--pattern')
    expect(error).toContain('[')
    // The engine's own reason, not a generic "invalid pattern" — this is
    // what "naming the parse failure" means in practice.
    expect(error?.toLowerCase()).toContain('unterminated character class')
  })

  it('refuses without ever falling back to a substring match', () => {
    // compilePattern's own fallback exists for exactly this input — this
    // function is for callers that want the opposite answer.
    expect(compilePattern('[')('[')).toBe(true)
    expect(patternFilterError('[')).toBeDefined()
  })
})
