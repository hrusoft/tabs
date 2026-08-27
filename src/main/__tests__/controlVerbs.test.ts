import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ControlRequest } from '../../shared/externalControl'
import { CONTROL_REQUEST_TYPES } from '../../shared/externalControl'
import type { MainControlContext, MainControlVerbTable } from '../controlVerbs'
import {
  mainControlVerb,
  registerMainControlVerbs,
  relayBudgetFor,
  resetMainControlVerbsForTests,
  unhandledMainControlVerbs
} from '../controlVerbs'

/**
 * The registry in isolation. Core's own verbs are registered at module scope in
 * externalControl.ts, which pulls in Electron — so this file deliberately never
 * imports it, and every test starts from a genuinely empty registry.
 */

type PingRequest = Extract<ControlRequest, { type: 'ping' }>
type NavigateRequest = Extract<ControlRequest, { type: 'navigate' }>

const context: MainControlContext = {
  relay: async () => ({ ok: true }),
  grantOwnership: () => {}
}

function pingTable(
  handle: MainControlVerbTable<PingRequest>['ping']['handle'] = () => ({ ok: true })
): MainControlVerbTable<PingRequest> {
  return { ping: { timeoutMs: 1000, handle } }
}

beforeEach(() => {
  resetMainControlVerbsForTests()
})

describe('the main-process control verb registry', () => {
  it('stores a table entry under each of its verb names', () => {
    registerMainControlVerbs(pingTable())
    expect(mainControlVerb('ping')?.timeoutMs).toBe(1000)
    expect(mainControlVerb('navigate')).toBeUndefined()
  })

  it('hands a verb its own request and the context core lends it', async () => {
    const handle = vi.fn(() => ({ ok: true }) as const)
    registerMainControlVerbs(pingTable(handle))
    const request: PingRequest = { type: 'ping', paneId: 'pane-1' }

    await mainControlVerb('ping')?.handle(request, context)

    expect(handle).toHaveBeenCalledWith(request, context)
  })

  it('refuses a second claim on a verb rather than replacing the first', () => {
    registerMainControlVerbs(pingTable())
    expect(() => registerMainControlVerbs(pingTable())).toThrow(/already registered for "ping"/)
  })

  it('leaves an earlier registration intact when a later table collides', () => {
    registerMainControlVerbs(pingTable())
    const collidingTable: MainControlVerbTable<PingRequest> = {
      ping: { timeoutMs: 9999, handle: () => ({ ok: true }) }
    }
    expect(() => registerMainControlVerbs(collidingTable)).toThrow()
    expect(mainControlVerb('ping')?.timeoutMs).toBe(1000)
  })

  describe('batchability', () => {
    it('defaults to batchable, since most verbs are order-independent', () => {
      registerMainControlVerbs(pingTable())
      expect(mainControlVerb('ping')?.batchable).toBe(true)
    })

    it('honours a verb that opts out', () => {
      const table: MainControlVerbTable<NavigateRequest> = {
        navigate: { timeoutMs: 1000, batchable: false, handle: () => ({ ok: true }) }
      }
      registerMainControlVerbs(table)
      expect(mainControlVerb('navigate')?.batchable).toBe(false)
    })
  })

  describe('per-request relay budgets', () => {
    it('returns a number-form budget unchanged', () => {
      registerMainControlVerbs(pingTable())
      expect(relayBudgetFor({ type: 'ping', paneId: 'pane-1' })).toBe(1000)
    })

    it('evaluates a function-form budget against the request it prices', () => {
      // The shape waitFor needs: a verb whose wait is a field of the request,
      // so its relay budget must be derived per call rather than per verb.
      const table: MainControlVerbTable<NavigateRequest> = {
        navigate: {
          timeoutMs: (request) => (request.retryOnRedirect ? 9000 : 4000),
          handle: () => ({ ok: true })
        }
      }
      registerMainControlVerbs(table)
      const base = { type: 'navigate', paneId: 'p', targetPaneId: 't', url: 'about:blank' } as const

      expect(relayBudgetFor(base)).toBe(4000)
      expect(relayBudgetFor({ ...base, retryOnRedirect: true })).toBe(9000)
    })

    it('is undefined for an unclaimed verb, leaving the fallback to the relay', () => {
      expect(relayBudgetFor({ type: 'ping', paneId: 'pane-1' })).toBeUndefined()
    })
  })

  describe('coverage reporting', () => {
    it('names every protocol verb while nothing has registered', () => {
      expect(unhandledMainControlVerbs()).toEqual([...CONTROL_REQUEST_TYPES])
    })

    it('drops a verb from the report once some table claims it', () => {
      registerMainControlVerbs(pingTable())
      expect(unhandledMainControlVerbs()).not.toContain('ping')
      // The point of the report: everything else is still uncovered, which is
      // what the e2e gate asserts against for a fully-registered app.
      expect(unhandledMainControlVerbs()).toContain('navigate')
    })

    it('reports only protocol verbs, so a stray name cannot mask a real gap', () => {
      registerMainControlVerbs(pingTable())
      for (const verb of unhandledMainControlVerbs()) {
        expect(CONTROL_REQUEST_TYPES).toContain(verb)
      }
    })
  })
})
