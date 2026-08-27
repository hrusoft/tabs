import { afterEach, describe, expect, it } from 'vitest'
import {
  type CloseBlockerProvider,
  collectCloseBlockers,
  listQuitBlockersSync,
  registerCloseBlockerProvider
} from '../closeBlockers'

// The provider Set is module state; every registration must be undone or it
// leaks into the next test.
const disposers: (() => void)[] = []

function register(provider: CloseBlockerProvider): void {
  disposers.push(registerCloseBlockerProvider(provider))
}

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
})

describe('collectCloseBlockers', () => {
  it('resolves empty with no providers registered', async () => {
    await expect(collectCloseBlockers(['a', 'b'])).resolves.toEqual([])
  })

  it('passes the ids through to each provider verbatim', async () => {
    const seen: string[][] = []
    register({
      collectBlockers: async (ids) => {
        seen.push(ids)
        return []
      },
      listBlockersSync: () => []
    })
    await collectCloseBlockers(['a', 'b'])
    expect(seen).toEqual([['a', 'b']])
  })

  it('concatenates blockers across providers', async () => {
    register({
      collectBlockers: async () => [{ command: 'vim' }],
      listBlockersSync: () => []
    })
    register({
      collectBlockers: async () => [{ command: 'sleep' }, { command: undefined }],
      listBlockersSync: () => []
    })
    await expect(collectCloseBlockers(['a'])).resolves.toEqual([
      { command: 'vim' },
      { command: 'sleep' },
      { command: undefined }
    ])
  })

  it('a rejecting provider contributes nothing while others still report', async () => {
    register({
      collectBlockers: async () => {
        throw new Error('broken provider')
      },
      listBlockersSync: () => []
    })
    register({
      collectBlockers: async () => [{ command: 'vim' }],
      listBlockersSync: () => []
    })
    await expect(collectCloseBlockers(['a'])).resolves.toEqual([{ command: 'vim' }])
  })
})

describe('listQuitBlockersSync', () => {
  it('returns empty with no providers registered', () => {
    expect(listQuitBlockersSync()).toEqual([])
  })

  it('concatenates blockers across providers', () => {
    register({
      collectBlockers: async () => [],
      listBlockersSync: () => [{ command: 'vim' }]
    })
    register({
      collectBlockers: async () => [],
      listBlockersSync: () => [{ command: 'sleep' }]
    })
    expect(listQuitBlockersSync()).toEqual([{ command: 'vim' }, { command: 'sleep' }])
  })

  it('a throwing provider contributes nothing while others still report', () => {
    register({
      collectBlockers: async () => [],
      listBlockersSync: () => {
        throw new Error('broken provider')
      }
    })
    register({
      collectBlockers: async () => [],
      listBlockersSync: () => [{ command: 'vim' }]
    })
    expect(listQuitBlockersSync()).toEqual([{ command: 'vim' }])
  })
})

describe('registerCloseBlockerProvider', () => {
  it('the returned disposer removes the provider from both paths', async () => {
    const dispose = registerCloseBlockerProvider({
      collectBlockers: async () => [{ command: 'vim' }],
      listBlockersSync: () => [{ command: 'vim' }]
    })
    dispose()
    await expect(collectCloseBlockers(['a'])).resolves.toEqual([])
    expect(listQuitBlockersSync()).toEqual([])
  })
})
