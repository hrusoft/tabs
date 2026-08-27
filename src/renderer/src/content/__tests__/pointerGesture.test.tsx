import { beforeEach, describe, expect, it } from 'vitest'
import { beginPointerGesture, endPointerGesture } from '../pointerGesture'

// `.tsx` despite holding no JSX: the vitest projects are split by extension,
// not by content (see vitest.config.ts), and the module under test writes to
// `document.body` — so it needs the jsdom tier, which is the `.tsx` one.

const flagged = (): boolean => document.body.classList.contains('pointer-gesture')

describe('pointerGesture', () => {
  beforeEach(() => {
    document.body.className = ''
    // The module holds its owner set at module scope, so drain whatever a
    // previous test left armed rather than reloading it.
    endPointerGesture('pane-drag')
    endPointerGesture('floating')
  })

  it('flags the body for the duration of a gesture', () => {
    expect(flagged()).toBe(false)
    beginPointerGesture('pane-drag')
    expect(flagged()).toBe(true)
    endPointerGesture('pane-drag')
    expect(flagged()).toBe(false)
  })

  // The reason this is owner-keyed at all: a pane drag left armed (its release
  // swallowed somewhere the host never saw) is still in flight when the user
  // grabs a floating window, and that window's release must not un-neutralize
  // the guests the drag still depends on.
  it('holds the flag until every owner has finished', () => {
    beginPointerGesture('pane-drag')
    beginPointerGesture('floating')
    endPointerGesture('floating')
    expect(flagged()).toBe(true)
    endPointerGesture('pane-drag')
    expect(flagged()).toBe(false)
  })

  // Both halves are idempotent on purpose: an unbalanced `begin` would leave
  // every `<webview>` permanently inert, a worse failure than the stalled
  // gesture the flag exists to prevent.
  it('is idempotent in both directions', () => {
    beginPointerGesture('pane-drag')
    beginPointerGesture('pane-drag')
    endPointerGesture('pane-drag')
    expect(flagged()).toBe(false)
    endPointerGesture('pane-drag')
    expect(flagged()).toBe(false)
  })
})
