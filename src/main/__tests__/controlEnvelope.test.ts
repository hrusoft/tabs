import { describe, expect, it } from 'vitest'
import { buildRequestFromEnvelope } from '../controlEnvelope'

/**
 * `buildRequestFromEnvelope` is what replaced `tabs-ctl`'s own hand-written
 * `buildRequest` (see resources/skills/tabs/scripts/tabs-ctl before this
 * ticket) — flag coercion now runs server-side, against the same specs
 * `capabilities`/`describe` serve. Messages here are not required to match
 * the old CLI's byte for byte (only the two "pane is gone" sentences
 * SKILL.md quotes verbatim are frozen, and neither is a flag-coercion
 * message), but every case that used to be refused before anything reached
 * the socket still is.
 *
 * Every browser command here also takes `--pane` (required), so most calls
 * include `pane: TARGET_PANE` even when the test's real subject is a
 * different flag — omitting it would fail on "--pane is required" before
 * ever reaching the behavior under test.
 */

const PANE = 'pane-1'
const TARGET_PANE = 'target-1'
const CWD = '/Users/agent/project'

describe('buildRequestFromEnvelope', () => {
  it('names the command when it is unknown', () => {
    const built = buildRequestFromEnvelope('nonsense', {}, PANE, CWD)
    expect(built.error).toContain('unknown command: nonsense')
  })

  it('names the valid flags when one is misspelled', () => {
    const built = buildRequestFromEnvelope('click', { panee: 'x' }, PANE, CWD)
    expect(built.error).toContain('unknown flag --panee')
    expect(built.error).toContain('--ref')
  })

  it('rejects a value outside a flag’s enum', () => {
    const built = buildRequestFromEnvelope(
      'scroll',
      { pane: TARGET_PANE, direction: 'sideways' },
      PANE,
      CWD
    )
    expect(built.error).toContain('must be one of up, down, left, right')
  })

  it('rejects a non-numeric value for a numeric flag', () => {
    const built = buildRequestFromEnvelope(
      'get-page-text',
      { pane: TARGET_PANE, 'max-length': 'abc' },
      PANE,
      CWD
    )
    expect(built.error).toContain('must be a number')
  })

  it('reports a missing required flag', () => {
    const built = buildRequestFromEnvelope('navigate', { pane: TARGET_PANE }, PANE, CWD)
    expect(built.error).toContain('--url is required')
  })

  it('reports the implicit --pane flag as missing too', () => {
    const built = buildRequestFromEnvelope('reload', {}, PANE, CWD)
    expect(built.error).toContain('--pane is required')
  })

  it('rejects numeric garbage below a flag’s floor', () => {
    expect(
      buildRequestFromEnvelope(
        'get-page-text',
        { pane: TARGET_PANE, 'max-length': '-5' },
        PANE,
        CWD
      ).error
    ).toContain('--max-length must be at least 1')
    expect(
      buildRequestFromEnvelope('read-console', { pane: TARGET_PANE, 'since-seq': '-1' }, PANE, CWD)
        .error
    ).toContain('--since-seq must be at least 0')
  })

  it('leaves a legitimate floor value alone (0 is a real sequence floor)', () => {
    const built = buildRequestFromEnvelope(
      'read-console',
      { pane: TARGET_PANE, 'since-seq': '0' },
      PANE,
      CWD
    )
    expect(built.error).toBeUndefined()
    expect(built.request).toMatchObject({ sinceSeq: 0 })
  })

  it('rejects malformed JSON for a JSON-valued flag', () => {
    const built = buildRequestFromEnvelope('batch', { requests: '{not json' }, PANE, CWD)
    expect(built.error).toContain('not valid JSON')
  })

  it('parses a well-formed JSON flag', () => {
    const built = buildRequestFromEnvelope('batch', { requests: '[{"type":"ping"}]' }, PANE, CWD)
    expect(built.request).toMatchObject({ requests: [{ type: 'ping' }] })
  })

  it('splits a csv flag on commas', () => {
    const built = buildRequestFromEnvelope(
      'key',
      { pane: TARGET_PANE, key: 'a', modifiers: 'meta,shift' },
      PANE,
      CWD
    )
    expect(built.request).toMatchObject({ modifiers: ['meta', 'shift'] })
  })

  it('maps a bare boolean flag to true, and an inverting flag to its declared value', () => {
    const on = buildRequestFromEnvelope('capture-bodies', { pane: TARGET_PANE }, PANE, CWD)
    expect(on.request).toMatchObject({ type: 'captureNetworkBodies' })
    expect(on.request).not.toHaveProperty('enabled')

    const off = buildRequestFromEnvelope(
      'capture-bodies',
      { pane: TARGET_PANE, off: true },
      PANE,
      CWD
    )
    expect(off.request).toMatchObject({ enabled: false })
  })

  it('resolves a path flag against the caller’s cwd, and passes bare/true through unresolved', () => {
    const named = buildRequestFromEnvelope(
      'execute-js',
      { pane: TARGET_PANE, code: '1', out: 'out/result.json' },
      PANE,
      CWD
    )
    expect(named.request).toMatchObject({ outPath: '/Users/agent/project/out/result.json' })

    const bare = buildRequestFromEnvelope(
      'execute-js',
      { pane: TARGET_PANE, code: '1', out: true },
      PANE,
      CWD
    )
    expect(bare.request).toMatchObject({ outPath: true })
  })

  describe('a value-taking flag given bare', () => {
    // parseArgs (tabs-ctl) turns a flag with nothing after it — end of argv,
    // or immediately followed by another flag — into `true`. That's correct
    // for a boolean flag and for a path flag's "generate one" bare form, and
    // wrong for everything else: left unchecked, Number(true) is 1 (a bare
    // --timeout silently became timeoutMs: 1, not "no timeout"), and
    // String(true) is "true" (a bare --ref silently became a real-looking
    // ref). Every case here used to build a corrupted request instead of
    // refusing.

    it('refuses a bare numeric flag rather than sending 1', () => {
      const built = buildRequestFromEnvelope(
        'wait-for',
        { pane: TARGET_PANE, text: 'x', timeout: true },
        PANE,
        CWD
      )
      expect(built.error).toBe('--timeout needs a value')
      expect(built.request).toBeUndefined()
    })

    it('refuses a bare plain-string flag', () => {
      const built = buildRequestFromEnvelope(
        'navigate',
        { pane: TARGET_PANE, url: true },
        PANE,
        CWD
      )
      expect(built.error).toBe('--url needs a value')
    })

    it('refuses a bare csv flag', () => {
      const built = buildRequestFromEnvelope(
        'key',
        { pane: TARGET_PANE, key: 'a', modifiers: true },
        PANE,
        CWD
      )
      expect(built.error).toBe('--modifiers needs a value')
    })

    it('refuses a bare json flag', () => {
      const built = buildRequestFromEnvelope('batch', { requests: true }, PANE, CWD)
      expect(built.error).toBe('--requests needs a value')
    })

    it('still accepts a bare boolean flag', () => {
      const built = buildRequestFromEnvelope(
        'read-network',
        { pane: TARGET_PANE, failed: true },
        PANE,
        CWD
      )
      expect(built.error).toBeUndefined()
      expect(built.request).toMatchObject({ failed: true })
    })

    it('still accepts a bare path flag ("generate one")', () => {
      const built = buildRequestFromEnvelope(
        'save-resource',
        { pane: TARGET_PANE, url: 'https://example.com/x.pdf', out: true },
        PANE,
        CWD
      )
      expect(built.error).toBeUndefined()
      expect(built.request).toMatchObject({ outPath: true })
    })

    it('refuses a bare --ref instead of sending {ref: "true"}', () => {
      const built = buildRequestFromEnvelope('click', { pane: TARGET_PANE, ref: true }, PANE, CWD)
      expect(built.error).toBe('--ref needs a value')
    })

    it('refuses a bare --x/--y instead of sending {x: 1, y: 1}', () => {
      const bareX = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, x: true, y: '10' },
        PANE,
        CWD
      )
      expect(bareX.error).toBe('--x needs a value')

      const bareY = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, x: '10', y: true },
        PANE,
        CWD
      )
      expect(bareY.error).toBe('--y needs a value')
    })

    it('refuses a bare --nth instead of sending nth: 1', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, role: 'button', nth: true },
        PANE,
        CWD
      )
      expect(built.error).toBe('--nth needs a value')
    })
  })

  describe('element-target composition', () => {
    it('builds a ref target', () => {
      const built = buildRequestFromEnvelope('click', { pane: TARGET_PANE, ref: 'e1' }, PANE, CWD)
      expect(built.request).toMatchObject({ target: { ref: 'e1' } })
    })

    it('builds a coordinate target, with no stray top-level x/y', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, x: '10', y: '20' },
        PANE,
        CWD
      )
      expect(built.request).toEqual({
        type: 'click',
        paneId: PANE,
        targetPaneId: TARGET_PANE,
        target: { x: 10, y: 20 }
      })
    })

    it('rejects a non-numeric coordinate instead of sending NaN', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, x: 'abc', y: '10' },
        PANE,
        CWD
      )
      expect(built.error).toContain('--x and --y must be numbers')
    })

    it('builds a semantic target with nth', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, role: 'button', name: 'Save', nth: '1' },
        PANE,
        CWD
      )
      expect(built.request).toMatchObject({ target: { role: 'button', name: 'Save', nth: 1 } })
    })

    it('requires at least one target form', () => {
      const built = buildRequestFromEnvelope('click', { pane: TARGET_PANE }, PANE, CWD)
      expect(built.error).toContain('--role/--name/--selector, --ref, or both --x and --y')
    })

    it('rejects a coordinate missing one axis', () => {
      const built = buildRequestFromEnvelope('click', { pane: TARGET_PANE, x: '10' }, PANE, CWD)
      expect(built.error).toContain('needs both --x and --y')
    })

    it('rejects mixing target forms', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, ref: 'e1', name: 'Save' },
        PANE,
        CWD
      )
      expect(built.error).toContain('pass only one')
    })

    it('rejects --nth without a semantic flag', () => {
      const built = buildRequestFromEnvelope(
        'click',
        { pane: TARGET_PANE, ref: 'e1', nth: '0' },
        PANE,
        CWD
      )
      expect(built.error).toContain('--nth only applies')
    })

    it('rejects a bare semantic flag rather than matching the string "true"', () => {
      const built = buildRequestFromEnvelope('click', { pane: TARGET_PANE, name: true }, PANE, CWD)
      expect(built.error).toContain('--name needs a value')
    })
  })

  it('builds an ordinary command, mapping --pane to targetPaneId', () => {
    const built = buildRequestFromEnvelope('reload', { pane: TARGET_PANE }, PANE, CWD)
    expect(built.error).toBeUndefined()
    expect(built.request).toEqual({ type: 'reload', paneId: PANE, targetPaneId: TARGET_PANE })
  })

  it('leaves an unknown capability for the describe handler to refuse, not coercion', () => {
    const built = buildRequestFromEnvelope('describe', { capability: 'nonexistent' }, PANE, CWD)
    // Coercion only checks the flag exists and is required — the capability
    // itself is validated by the describe handler, which knows the census.
    expect(built.error).toBeUndefined()
    expect(built.request).toMatchObject({ type: 'describe', capability: 'nonexistent' })
  })
})
