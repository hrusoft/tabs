import { beforeEach, describe, expect, it } from 'vitest'
import { NETWORK_BODY_MAX, NETWORK_LOG_CAPACITY } from '../../shared/externalControl'
import type { NetworkReadOptions } from '../networkLog'
import {
  listRequests,
  methodFilterError,
  NETWORK_METHODS,
  NETWORK_RESOURCE_TYPES,
  networkFilterError,
  parseStatusSpec,
  REDACTED,
  recordRequestStart,
  recordRequestUpdate,
  recordResponseBody,
  redactHeaders,
  resetNetworkLogsForTests,
  resourceTypeFilterError,
  statusFilterError
} from '../networkLog'

describe('redactHeaders', () => {
  it('strips credential-bearing values but keeps the header names', () => {
    const redacted = redactHeaders(
      { Authorization: 'Bearer abc123', 'Content-Type': 'application/json' },
      false
    )

    expect(redacted).toEqual({ Authorization: REDACTED, 'Content-Type': 'application/json' })
  })

  it('matches header names case-insensitively', () => {
    expect(redactHeaders({ cookie: 'a=1', 'SET-COOKIE': 'b=2' }, false)).toEqual({
      cookie: REDACTED,
      'SET-COOKIE': REDACTED
    })
  })

  it('passes everything through untouched when unredacted is set', () => {
    const headers = { Authorization: 'Bearer abc123' }
    expect(redactHeaders(headers, true)).toEqual(headers)
  })

  it('handles a missing header set', () => {
    expect(redactHeaders(undefined, false)).toBeUndefined()
  })
})

describe('the per-guest request log', () => {
  beforeEach(() => {
    resetNetworkLogsForTests()
  })

  const GUEST = 42
  const start = (guestId: number, id: number, url: string, resourceType = 'xhr'): void =>
    recordRequestStart(guestId, id, { method: 'GET', url, resourceType, startedAt: 1 })

  it("keeps one guest's requests separate from another's", () => {
    start(1, 1, 'https://a.example/one')
    start(2, 2, 'https://b.example/two')

    expect(listRequests(1).map((r) => r.url)).toEqual(['https://a.example/one'])
    expect(listRequests(2).map((r) => r.url)).toEqual(['https://b.example/two'])
  })

  it('returns nothing when the pane has no guest to resolve to', () => {
    expect(listRequests(undefined)).toEqual([])
  })

  it('merges a completion into the entry its start created', () => {
    start(GUEST, 7, 'https://example.com/data')
    recordRequestUpdate(7, { status: 200, completedAt: 5 })

    expect(listRequests(GUEST)[0]).toMatchObject({ status: 200, completedAt: 5 })
  })

  it('resets the log when a new top-level document starts, keeping that document as the first entry', () => {
    start(GUEST, 1, 'https://example.com/first', 'mainFrame')
    start(GUEST, 2, 'https://example.com/first.css', 'stylesheet')
    start(GUEST, 3, 'https://example.com/second', 'mainFrame')

    // The old page's requests are gone; the new document's own request is not.
    expect(listRequests(GUEST).map((r) => r.url)).toEqual(['https://example.com/second'])
  })

  it("leaves another guest's in-flight requests alone when a new document starts elsewhere", () => {
    start(1, 101, 'https://a.example/api')
    // A new top-level document in guest 2 — request ids are session-global,
    // so a global in-flight clear here silently orphaned guest 1's entry and
    // its completion below never landed.
    start(2, 201, 'https://b.example/', 'mainFrame')
    recordRequestUpdate(101, { status: 200, completedAt: 5 })

    expect(listRequests(1)[0]).toMatchObject({ status: 200, completedAt: 5 })
  })

  it('redacts headers by default and only on request', () => {
    start(GUEST, 1, 'https://example.com/data')
    recordRequestUpdate(1, {
      requestHeaders: { Cookie: 'session=secret' },
      responseHeaders: { 'Set-Cookie': 'session=secret' }
    })

    expect(listRequests(GUEST)[0]!.requestHeaders).toEqual({ Cookie: REDACTED })
    expect(listRequests(GUEST)[0]!.responseHeaders).toEqual({ 'Set-Cookie': REDACTED })
    expect(listRequests(GUEST, { unredacted: true })[0]!.requestHeaders).toEqual({
      Cookie: 'session=secret'
    })
  })

  it('does not let a redacted read mutate what is stored', () => {
    start(GUEST, 1, 'https://example.com/data')
    recordRequestUpdate(1, { requestHeaders: { Cookie: 'session=secret' } })

    listRequests(GUEST)
    expect(listRequests(GUEST, { unredacted: true })[0]!.requestHeaders).toEqual({
      Cookie: 'session=secret'
    })
  })

  it('filters by URL pattern and sinceSeq', () => {
    start(GUEST, 1, 'https://example.com/a.js')
    start(GUEST, 2, 'https://example.com/b.css')
    start(GUEST, 3, 'https://example.com/c.js')

    expect(listRequests(GUEST, { pattern: '\\.js$' }).map((r) => r.url)).toEqual([
      'https://example.com/a.js',
      'https://example.com/c.js'
    ])
    expect(listRequests(GUEST, { sinceSeq: 2 }).map((r) => r.url)).toEqual([
      'https://example.com/c.js'
    ])
  })

  it('returns nothing for a guest that never loaded anything', () => {
    expect(listRequests(999)).toEqual([])
  })
})

describe('read filters', () => {
  const GUEST = 42
  const ROOT = 'https://a.example/'
  const SAVE = 'https://a.example/api/save'
  const PIC = 'https://a.example/pic.png'
  const POLL = 'https://a.example/api/poll'
  const PENDING = 'https://a.example/pending'

  beforeEach(() => {
    resetNetworkLogsForTests()
    recordRequestStart(GUEST, 1, {
      method: 'GET',
      url: ROOT,
      resourceType: 'mainFrame',
      startedAt: 1
    })
    recordRequestUpdate(1, { status: 200, completedAt: 2 })
    recordRequestStart(GUEST, 2, { method: 'POST', url: SAVE, resourceType: 'xhr', startedAt: 3 })
    recordRequestUpdate(2, { status: 500, completedAt: 4 })
    recordRequestStart(GUEST, 3, { method: 'GET', url: PIC, resourceType: 'image', startedAt: 5 })
    recordRequestUpdate(3, { error: 'net::ERR_FAILED', completedAt: 6 })
    recordRequestStart(GUEST, 4, { method: 'GET', url: POLL, resourceType: 'xhr', startedAt: 7 })
    recordRequestUpdate(4, { status: 404, completedAt: 8 })
    // Still in flight — no status, no error, no outcome to filter on.
    recordRequestStart(GUEST, 5, {
      method: 'GET',
      url: PENDING,
      resourceType: 'xhr',
      startedAt: 9
    })
  })

  const urls = (options: NetworkReadOptions): string[] =>
    listRequests(GUEST, options).map((entry) => entry.url)

  it('narrows by method, case-insensitively', () => {
    expect(urls({ method: 'post' })).toEqual([SAVE])
    expect(urls({ method: 'GET' })).toEqual([ROOT, PIC, POLL, PENDING])
  })

  it('narrows by resource type', () => {
    expect(urls({ resourceType: 'xhr' })).toEqual([SAVE, POLL, PENDING])
    expect(urls({ resourceType: 'mainFrame' })).toEqual([ROOT])
  })

  it('narrows by status: exact, class, and range', () => {
    expect(urls({ status: '404' })).toEqual([POLL])
    expect(urls({ status: '5xx' })).toEqual([SAVE])
    expect(urls({ status: '200-404' })).toEqual([ROOT, POLL])
    // No status yet (in flight) or never (network error) is not a match.
    expect(urls({ status: '2xx' })).toEqual([ROOT])
  })

  it('an unparsable status spec matches nothing rather than everything', () => {
    // Defensive only — the verb refuses the spec before this module sees it.
    expect(urls({ status: 'flaky' })).toEqual([])
  })

  it('failed means a 4xx/5xx answer or a network error, never an in-flight request', () => {
    expect(urls({ failed: true })).toEqual([SAVE, PIC, POLL])
  })

  it('filters compose with the URL pattern and each other', () => {
    expect(urls({ failed: true, pattern: 'api/' })).toEqual([SAVE, POLL])
    expect(urls({ failed: true, pattern: 'api/', method: 'get' })).toEqual([POLL])
  })

  describe('parseStatusSpec', () => {
    it('parses the three forms', () => {
      expect(parseStatusSpec('404')).toEqual({ min: 404, max: 404 })
      expect(parseStatusSpec('4xx')).toEqual({ min: 400, max: 499 })
      expect(parseStatusSpec('4XX')).toEqual({ min: 400, max: 499 })
      expect(parseStatusSpec('400-499')).toEqual({ min: 400, max: 499 })
      expect(parseStatusSpec('307-307')).toEqual({ min: 307, max: 307 })
    })

    it('refuses anything else', () => {
      for (const bad of ['', '40', '4040', '6xx', 'xx4', '499-400', '4x', 'ok', '404-']) {
        expect(parseStatusSpec(bad), `spec ${JSON.stringify(bad)}`).toBeUndefined()
      }
    })
  })
})

// Every read-network filter fails loud on a bad value rather than quietly
// matching nothing — an agent can't distinguish "the filter is wrong" from
// "nothing matched" without one of those turning into an error. See
// networkFilterError, called once by the verb before any of listRequests's
// own (defensive, fail-closed) filter comparisons run.
describe('filter refusals', () => {
  describe('methodFilterError', () => {
    it('accepts every standard method, case-insensitively', () => {
      for (const method of NETWORK_METHODS) {
        expect(methodFilterError(method), method).toBeUndefined()
        expect(methodFilterError(method.toLowerCase()), method.toLowerCase()).toBeUndefined()
      }
    })

    it('refuses anything else, naming the accepted methods', () => {
      const error = methodFilterError('FROBNICATE')
      expect(error).toContain('FROBNICATE')
      expect(error).toContain('GET')
      expect(error).toContain('POST')
    })
  })

  describe('resourceTypeFilterError', () => {
    it('accepts every Electron resource type, exact-case', () => {
      for (const resourceType of NETWORK_RESOURCE_TYPES) {
        expect(resourceTypeFilterError(resourceType), resourceType).toBeUndefined()
      }
    })

    it('refuses a wrong-case value the same as an unknown one', () => {
      // The underlying filter compares exact-case (see listRequests), so a
      // spec that would never match is refused rather than silently
      // matching nothing.
      expect(resourceTypeFilterError('MainFrame')).toBeDefined()
    })

    it('refuses an unrecognized type, naming the accepted ones', () => {
      const error = resourceTypeFilterError('widget')
      expect(error).toContain('widget')
      expect(error).toContain('xhr')
      // No hint for a value that isn't the specific documented trap.
      expect(error?.toLowerCase()).not.toContain('fetch')
    })

    it('names xhr as what fetch traffic reports as — the documented trap', () => {
      for (const value of ['fetch', 'Fetch', 'FETCH']) {
        const error = resourceTypeFilterError(value)
        expect(error, value).toContain('xhr')
        expect(error, value).toContain('fetch')
      }
    })
  })

  describe('statusFilterError', () => {
    it('agrees with parseStatusSpec', () => {
      expect(statusFilterError('404')).toBeUndefined()
      expect(statusFilterError('4xx')).toBeUndefined()
      const error = statusFilterError('flaky')
      expect(error).toContain('flaky')
      expect(error).toContain('404')
    })
  })

  describe('networkFilterError', () => {
    it('is undefined when every supplied filter is valid', () => {
      expect(
        networkFilterError({ method: 'get', status: '4xx', resourceType: 'xhr', pattern: '^/api' })
      ).toBeUndefined()
      expect(networkFilterError({})).toBeUndefined()
    })

    it('reports whichever filter is bad, without requiring the others', () => {
      expect(networkFilterError({ method: 'FROBNICATE' })).toContain('FROBNICATE')
      expect(networkFilterError({ resourceType: 'fetch' })).toContain('xhr')
      expect(networkFilterError({ pattern: '[' })).toContain('--pattern')
    })
  })
})

describe('request dedup', () => {
  beforeEach(() => {
    resetNetworkLogsForTests()
  })

  const GUEST = 42
  const start = (
    id: number,
    url: string,
    options: { method?: string; resourceType?: string; startedAt?: number } = {}
  ): void =>
    recordRequestStart(GUEST, id, {
      method: options.method ?? 'GET',
      url,
      resourceType: options.resourceType ?? 'xhr',
      startedAt: options.startedAt ?? 1
    })
  const complete = (id: number, status: number, completedAt = 2): void =>
    recordRequestUpdate(id, { status, completedAt })
  const fail = (id: number, error: string, completedAt = 2): void =>
    recordRequestUpdate(id, { error, completedAt })

  it('collapses a run of identical completions into one counted entry', () => {
    start(1, 'https://a.example/poll', { startedAt: 10 })
    complete(1, 200, 11)
    start(2, 'https://a.example/poll', { startedAt: 20 })
    complete(2, 200, 21)
    start(3, 'https://a.example/poll', { startedAt: 30 })
    complete(3, 200, 31)

    const entries = listRequests(GUEST)
    expect(entries).toHaveLength(1)
    expect(entries[0]).toMatchObject({
      status: 200,
      count: 3,
      firstStartedAt: 10,
      // Everything but count/firstStartedAt describes the latest occurrence.
      startedAt: 30,
      completedAt: 31
    })
  })

  it('keeps a lone completion byte-identical to what it always was', () => {
    start(1, 'https://a.example/once')
    complete(1, 200)

    const entry = listRequests(GUEST)[0]!
    expect('count' in entry).toBe(false)
    expect('firstStartedAt' in entry).toBe(false)
  })

  it('a status change starts a new entry, and a return to the old status never merges backwards', () => {
    start(1, 'https://a.example/poll')
    complete(1, 200)
    start(2, 'https://a.example/poll')
    complete(2, 200)
    start(3, 'https://a.example/poll')
    complete(3, 404)
    start(4, 'https://a.example/poll')
    complete(4, 200)

    // The transition reads in true order: the run, the failure, the recovery.
    expect(listRequests(GUEST).map((entry) => [entry.status, entry.count ?? 1])).toEqual([
      [200, 2],
      [404, 1],
      [200, 1]
    ])
  })

  it('treats an error change as a transition too, while identical errors collapse', () => {
    start(1, 'https://a.example/poll')
    fail(1, 'net::ERR_CONNECTION_REFUSED')
    start(2, 'https://a.example/poll')
    fail(2, 'net::ERR_CONNECTION_REFUSED')
    start(3, 'https://a.example/poll')
    fail(3, 'net::ERR_TIMED_OUT')

    expect(listRequests(GUEST).map((entry) => [entry.error, entry.count ?? 1])).toEqual([
      ['net::ERR_CONNECTION_REFUSED', 2],
      ['net::ERR_TIMED_OUT', 1]
    ])
  })

  it('collapses interleaved pollers independently', () => {
    start(1, 'https://a.example/status')
    complete(1, 200)
    start(2, 'https://a.example/progress')
    complete(2, 200)
    start(3, 'https://a.example/status')
    complete(3, 200)
    start(4, 'https://a.example/progress')
    complete(4, 200)

    expect(listRequests(GUEST).map((entry) => [entry.url, entry.count])).toEqual([
      ['https://a.example/status', 2],
      ['https://a.example/progress', 2]
    ])
  })

  it('never merges requests that differ in method or resource type', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    start(2, 'https://a.example/api', { method: 'POST' })
    complete(2, 200)
    start(3, 'https://a.example/api', { resourceType: 'image' })
    complete(3, 200)

    expect(listRequests(GUEST)).toHaveLength(3)
  })

  it('in-flight repeats never merge, and out-of-order completions still collapse', () => {
    start(1, 'https://a.example/poll', { startedAt: 10 })
    start(2, 'https://a.example/poll', { startedAt: 20 })
    // Neither has completed yet — two entries, no candidate to merge into.
    expect(listRequests(GUEST)).toHaveLength(2)

    complete(2, 200, 21)
    complete(1, 200, 25)

    const entries = listRequests(GUEST)
    expect(entries).toHaveLength(1)
    expect(entries[0]!.count).toBe(2)
    // "When the run began" is by start time, whatever the completion order.
    expect(entries[0]!.firstStartedAt).toBe(10)
    expect(entries[0]!.completedAt).toBe(25)
  })

  it('a repeat after a new top-level document starts fresh', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    recordRequestStart(GUEST, 2, {
      method: 'GET',
      url: 'https://a.example/next',
      resourceType: 'mainFrame',
      startedAt: 5
    })
    start(3, 'https://a.example/api')
    complete(3, 200)

    expect(listRequests(GUEST).map((entry) => [entry.url, entry.count ?? 1])).toEqual([
      ['https://a.example/next', 1],
      ['https://a.example/api', 1]
    ])
  })

  it('a merge assigns a fresh seq, so sinceSeq polling sees the updated count', () => {
    start(1, 'https://a.example/status')
    complete(1, 200)
    const seqAfterFirst = listRequests(GUEST)[0]!.seq
    start(2, 'https://a.example/status')
    complete(2, 200)

    const delta = listRequests(GUEST, { sinceSeq: seqAfterFirst })
    expect(delta).toHaveLength(1)
    expect(delta[0]!.count).toBe(2)
  })

  it('never merges into an entry the ring already evicted', () => {
    start(1, 'https://a.example/poll')
    complete(1, 200)
    // Push the poll entry out of the ring with unrelated traffic.
    for (let i = 0; i < NETWORK_LOG_CAPACITY; i++) {
      start(10 + i, `https://a.example/r${i}`)
    }
    start(9999, 'https://a.example/poll')
    complete(9999, 200)

    // A fresh entry, not a ghost merge: no count, and nothing resurrected.
    const polls = listRequests(GUEST).filter((entry) => entry.url === 'https://a.example/poll')
    expect(polls).toHaveLength(1)
    expect(polls[0]!.count).toBeUndefined()
  })

  it('a poll loop cannot evict unrelated traffic — the observed failure', () => {
    // The POST that mattered lands first...
    start(1, 'https://a.example/generate', { method: 'POST', startedAt: 1 })
    complete(1, 200)
    // ...then a status poll fires well past the whole buffer's capacity.
    for (let i = 0; i < NETWORK_LOG_CAPACITY + 50; i++) {
      start(1000 + i, 'https://a.example/status', { startedAt: 2 + i })
      complete(1000 + i, 200, 3 + i)
    }

    const entries = listRequests(GUEST)
    expect(entries).toHaveLength(2)
    expect(entries[0]).toMatchObject({ url: 'https://a.example/generate', method: 'POST' })
    expect(entries[1]).toMatchObject({
      url: 'https://a.example/status',
      count: NETWORK_LOG_CAPACITY + 50
    })
  })
})

describe('captured response bodies', () => {
  beforeEach(() => {
    resetNetworkLogsForTests()
  })

  const GUEST = 42
  const start = (id: number, url: string, method = 'GET', resourceType = 'xhr'): void =>
    recordRequestStart(GUEST, id, { method, url, resourceType, startedAt: 1 })
  const complete = (id: number, status: number): void =>
    recordRequestUpdate(id, { status, completedAt: 2 })
  const body = (url: string, status: number, text: string, method = 'GET'): void =>
    recordResponseBody(GUEST, {
      method,
      url,
      status,
      mimeType: 'application/json',
      body: text,
      base64Encoded: false
    })

  it('joins a body onto its entry only when withBodies is asked', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    body('https://a.example/api', 200, '{"ok":true}')

    expect(listRequests(GUEST)[0]!.responseBody).toBeUndefined()
    expect(listRequests(GUEST, { withBodies: true })[0]!.responseBody).toEqual({
      body: '{"ok":true}',
      truncated: false,
      size: 11,
      mimeType: 'application/json'
    })
  })

  it('never mutates the stored entry — the join lands on the returned copy', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    body('https://a.example/api', 200, '{"ok":true}')

    listRequests(GUEST, { withBodies: true })
    expect(listRequests(GUEST)[0]!.responseBody).toBeUndefined()
  })

  it('keys the join on status, so a 200 poll and the 500 that matters never swap bodies', () => {
    start(1, 'https://a.example/poll')
    complete(1, 200)
    body('https://a.example/poll', 200, '{"state":"running"}')
    start(2, 'https://a.example/poll')
    complete(2, 500)
    body('https://a.example/poll', 500, '{"error":"boom"}')

    const entries = listRequests(GUEST, { withBodies: true })
    expect(entries[0]!.responseBody?.body).toBe('{"state":"running"}')
    expect(entries[1]!.responseBody?.body).toBe('{"error":"boom"}')
  })

  it('attaches the newest body to a collapsed run — latest body wins, disclosed by count', () => {
    // Two identical 200s collapse into one entry (see the dedup describe);
    // bodies stay per-occurrence, and the merged entry claims the newest.
    start(1, 'https://a.example/poll')
    complete(1, 200)
    body('https://a.example/poll', 200, 'first')
    start(2, 'https://a.example/poll')
    complete(2, 200)
    body('https://a.example/poll', 200, 'second')

    const entries = listRequests(GUEST, { withBodies: true })
    expect(entries).toHaveLength(1)
    expect(entries[0]!.count).toBe(2)
    expect(entries[0]!.responseBody?.body).toBe('second')
  })

  it('claims each body once across a status transition, newest first', () => {
    start(1, 'https://a.example/poll')
    complete(1, 200)
    body('https://a.example/poll', 200, 'ok before')
    start(2, 'https://a.example/poll')
    complete(2, 500)
    body('https://a.example/poll', 500, 'boom')
    // The recovery never merges backwards, so two 200-keyed entries coexist
    // and the claim-once pairing has to hand each its own body.
    start(3, 'https://a.example/poll')
    complete(3, 200)
    body('https://a.example/poll', 200, 'ok after')

    const entries = listRequests(GUEST, { withBodies: true })
    expect(entries.map((entry) => entry.responseBody?.body)).toEqual([
      'ok before',
      'boom',
      'ok after'
    ])
  })

  it('truncates a long text body explicitly, reporting the full size', () => {
    const long = 'x'.repeat(NETWORK_BODY_MAX + 500)
    start(1, 'https://a.example/big')
    complete(1, 200)
    body('https://a.example/big', 200, long)

    const attached = listRequests(GUEST, { withBodies: true })[0]!.responseBody
    expect(attached?.truncated).toBe(true)
    expect(attached?.size).toBe(NETWORK_BODY_MAX + 500)
    expect(attached?.body).toHaveLength(NETWORK_BODY_MAX)
  })

  it('reports a binary body as type and size only, never content', () => {
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3, 4, 5])
    start(1, 'https://a.example/pic.png')
    complete(1, 200)
    recordResponseBody(GUEST, {
      method: 'GET',
      url: 'https://a.example/pic.png',
      status: 200,
      mimeType: 'image/png',
      body: bytes.toString('base64'),
      base64Encoded: true
    })

    expect(listRequests(GUEST, { withBodies: true })[0]!.responseBody).toEqual({
      truncated: false,
      size: bytes.byteLength,
      mimeType: 'image/png',
      binary: true
    })
  })

  it('sizes a withheld binary body from the stream count CDP reported', () => {
    // getResponseBody answers *empty* (not an error) for bodies Chromium
    // never buffered — images, measured — so the dataReceived sum is the
    // honest size for a report whose content was never going to be inlined.
    start(1, 'https://a.example/pic.png')
    complete(1, 200)
    recordResponseBody(GUEST, {
      method: 'GET',
      url: 'https://a.example/pic.png',
      status: 200,
      mimeType: 'image/png',
      body: '',
      base64Encoded: true,
      receivedBytes: 520
    })

    expect(listRequests(GUEST, { withBodies: true })[0]!.responseBody).toEqual({
      truncated: false,
      size: 520,
      mimeType: 'image/png',
      binary: true
    })
  })

  it('decodes a base64-delivered textual body rather than calling it binary', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    recordResponseBody(GUEST, {
      method: 'GET',
      url: 'https://a.example/api',
      status: 200,
      mimeType: 'application/json; charset=utf-8',
      body: Buffer.from('{"ok":1}', 'utf8').toString('base64'),
      base64Encoded: true
    })

    expect(listRequests(GUEST, { withBodies: true })[0]!.responseBody).toMatchObject({
      body: '{"ok":1}',
      mimeType: 'application/json'
    })
  })

  it('treats an untyped body CDP sent as text as text', () => {
    start(1, 'https://a.example/naked')
    complete(1, 200)
    recordResponseBody(GUEST, {
      method: 'GET',
      url: 'https://a.example/naked',
      status: 200,
      body: 'plain enough',
      base64Encoded: false
    })

    expect(listRequests(GUEST, { withBodies: true })[0]!.responseBody).toEqual({
      body: 'plain enough',
      truncated: false,
      size: 12
    })
  })

  it('drops bodies with the log on a new top-level document, and on forget', () => {
    start(1, 'https://a.example/api')
    complete(1, 200)
    body('https://a.example/api', 200, 'stale')
    recordRequestStart(GUEST, 2, {
      method: 'GET',
      url: 'https://a.example/next',
      resourceType: 'mainFrame',
      startedAt: 3
    })
    // The same request repeated on the new page must not inherit the old body.
    start(3, 'https://a.example/api')
    complete(3, 200)

    const afterNav = listRequests(GUEST, { withBodies: true })
    expect(
      afterNav.find((entry) => entry.url === 'https://a.example/api')?.responseBody
    ).toBeUndefined()
  })

  it('leaves a body unclaimed by entries another filter removed', () => {
    start(1, 'https://a.example/one')
    complete(1, 200)
    start(2, 'https://a.example/two')
    complete(2, 200)
    body('https://a.example/two', 200, 'for two')

    const filtered = listRequests(GUEST, { withBodies: true, pattern: 'one' })
    expect(filtered).toHaveLength(1)
    expect(filtered[0]!.responseBody).toBeUndefined()
  })
})
