import { describe, expect, test, vi } from 'vitest'
import { createGuestReporter } from '../guestReport'

/**
 * The e2e tier can only observe this race, never force it — an unfixed build
 * passes the reparent test in browser.spec.ts roughly one run in three, since
 * whether `getWebContentsId()` is readable at `did-attach` is a matter of
 * timing. Here the throw is the premise rather than the weather, so the
 * contract is checked exactly.
 */

/** A `getWebContentsId` that throws exactly like Electron's until `readyAfter` calls have passed. */
function guestIdReadableAfter(readyAfter: number, id = 7): () => number {
  let calls = 0
  return () => {
    calls++
    if (calls <= readyAfter) {
      throw new Error(
        'The WebView must be attached to the DOM and the dom-ready event emitted before this method can be called.'
      )
    }
    return id
  }
}

describe('createGuestReporter', () => {
  test('sends nothing while the guest id is still unreadable', () => {
    const send = vi.fn()
    const report = createGuestReporter(
      'pane-1',
      guestIdReadableAfter(Number.MAX_SAFE_INTEGER),
      send
    )

    report()
    report()

    expect(send).not.toHaveBeenCalled()
  })

  test('a throw at did-attach does not stop a later report point from landing', () => {
    const send = vi.fn()
    // Throws for the synchronous did-attach attempt, readable from the next.
    const report = createGuestReporter('pane-1', guestIdReadableAfter(1), send)

    report()
    expect(send).not.toHaveBeenCalled()

    report()
    expect(send).toHaveBeenCalledExactlyOnceWith('pane-1', 7)
  })

  test('the redundant report points cost one send per guest, not one per call', () => {
    const send = vi.fn()
    const report = createGuestReporter('pane-1', () => 7, send)

    report()
    report()
    report()

    expect(send).toHaveBeenCalledExactlyOnceWith('pane-1', 7)
  })

  test('a reparent that rebuilds the guest under the same element re-reports', () => {
    const send = vi.fn()
    let live = 7
    const report = createGuestReporter('pane-1', () => live, send)

    report()
    // A structural reparent destroys the guest and builds a new one with a new
    // id under the same <webview> — the case that made re-reporting necessary.
    live = 8
    report()

    expect(send.mock.calls).toEqual([
      ['pane-1', 7],
      ['pane-1', 8]
    ])
  })

  test('a guest that only becomes readable at dom-ready is still reported', () => {
    const send = vi.fn()
    // Throws for did-attach and for the macrotask retry; readable only by the
    // third point, which is what dom-ready is the backstop for.
    const report = createGuestReporter('pane-1', guestIdReadableAfter(2), send)

    report()
    report()
    expect(send).not.toHaveBeenCalled()

    report()
    expect(send).toHaveBeenCalledExactlyOnceWith('pane-1', 7)
  })
})
