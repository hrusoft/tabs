import { EventEmitter } from 'node:events'
import type { Debugger, WebContents } from 'electron'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { resetGuestDebuggersForTests } from '../guestDebugger'
import {
  disableBodyCapture,
  dropGuestBodySession,
  enableBodyCapture,
  isBodyCaptureLive,
  resetNetworkBodyCaptureForTests
} from '../networkBodyCapture'
import * as networkLog from '../networkLog'

vi.mock('../networkLog', () => ({ recordResponseBody: vi.fn() }))

/**
 * A minimal fake CDP `Debugger`: an EventEmitter (guestDebugger.ts listens for
 * 'message') with the three methods guestDebugger.ts/networkBodyCapture.ts
 * actually call. `sendCommand` answers `Network.getResponseBody` so
 * fetchBody's happy path completes.
 */
class FakeDebugger extends EventEmitter implements Partial<Debugger> {
  attached = false
  attach = vi.fn(() => {
    this.attached = true
  })
  detach = vi.fn(() => {
    this.attached = false
  })
  isAttached = vi.fn(() => this.attached)
  sendCommand = vi.fn(async (method: string) => {
    if (method === 'Network.getResponseBody') return { body: 'hi', base64Encoded: false }
    return {}
  })
}

function fakeGuest(id: number): WebContents & { debugger: FakeDebugger } {
  const emitter = new EventEmitter()
  return Object.assign(emitter, {
    id,
    debugger: new FakeDebugger(),
    isDestroyed: () => false
  }) as unknown as WebContents & { debugger: FakeDebugger }
}

afterEach(() => {
  resetNetworkBodyCaptureForTests()
  resetGuestDebuggersForTests()
  vi.clearAllMocks()
})

describe('enableBodyCapture', () => {
  it('two concurrent enables for the same guest join one session instead of racing', async () => {
    const guest = fakeGuest(1)

    const [a, b] = await Promise.all([
      enableBodyCapture('pane-a', guest),
      enableBodyCapture('pane-b', guest)
    ])

    expect(a).toEqual({})
    expect(b).toEqual({})
    expect(guest.debugger.attach).toHaveBeenCalledTimes(1)

    // A single CDP event must be processed exactly once, not once per
    // concurrent caller — the pre-fix bug registered a listener per caller,
    // sharing the guestDebugger-level fan-out but each independently mutating
    // the one surviving BodySession's `pending` entry. `dataReceived` has no
    // delete-then-check guard (unlike `loadingFinished`), so a duplicate
    // listener double-counts its byte total — the cleanest observable symptom.
    guest.debugger.emit('message', {}, 'Network.requestWillBeSent', {
      requestId: 'req-1',
      request: { method: 'GET', url: 'https://example.com/x' }
    })
    guest.debugger.emit('message', {}, 'Network.dataReceived', {
      requestId: 'req-1',
      dataLength: 100
    })
    guest.debugger.emit('message', {}, 'Network.loadingFinished', { requestId: 'req-1' })
    await Promise.resolve()
    await Promise.resolve()

    expect(vi.mocked(networkLog.recordResponseBody)).toHaveBeenCalledTimes(1)
    expect(vi.mocked(networkLog.recordResponseBody)).toHaveBeenCalledWith(
      guest.id,
      expect.objectContaining({ receivedBytes: 100 })
    )

    // Both panes' intents were recorded, and turning capture off (which
    // releases exactly one lease) must fully detach the shared debugger —
    // it would not if a second, orphaned lease from the race were still
    // holding the refcount above zero.
    expect(isBodyCaptureLive('pane-a', guest.id)).toBe(true)
    expect(isBodyCaptureLive('pane-b', guest.id)).toBe(true)
    dropGuestBodySession(guest.id)
    expect(guest.debugger.detach).toHaveBeenCalledTimes(1)
  })

  it('a second enable while the first is still attaching does not start a second attach', async () => {
    const guest = fakeGuest(2)

    const first = enableBodyCapture('pane-a', guest)
    const second = enableBodyCapture('pane-b', guest)

    await Promise.all([first, second])

    expect(guest.debugger.attach).toHaveBeenCalledTimes(1)
    expect(guest.debugger.sendCommand).toHaveBeenCalledWith('Network.enable', expect.anything())
    expect(
      vi.mocked(guest.debugger.sendCommand).mock.calls.filter(([m]) => m === 'Network.enable')
    ).toHaveLength(1)
  })

  it('disableBodyCapture after concurrent enables still detaches cleanly', async () => {
    const guest = fakeGuest(3)

    await Promise.all([enableBodyCapture('pane-a', guest), enableBodyCapture('pane-b', guest)])
    disableBodyCapture('pane-a', guest.id)

    expect(guest.debugger.detach).toHaveBeenCalledTimes(1)
    expect(isBodyCaptureLive('pane-b', guest.id)).toBe(false)
  })
})
