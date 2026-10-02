import { describe, expect, it } from 'vitest'
import { isLinkActivationEvent } from '../links'

/** Only the three fields isLinkActivationEvent reads — vitest runs in `node`, no DOM. */
function mouseEvent(partial: Partial<MouseEvent>): MouseEvent {
  return { button: 0, metaKey: false, ctrlKey: false, ...partial } as MouseEvent
}

describe('isLinkActivationEvent', () => {
  it('ignores a plain left click, which is how a terminal pane gets focused', () => {
    expect(isLinkActivationEvent(mouseEvent({}))).toBe(false)
  })

  it('follows a Cmd-click (macOS) or Ctrl-click (elsewhere)', () => {
    expect(isLinkActivationEvent(mouseEvent({ metaKey: true }))).toBe(true)
    expect(isLinkActivationEvent(mouseEvent({ ctrlKey: true }))).toBe(true)
  })

  it('ignores any non-left button, modifier or not', () => {
    // xterm's Linkifier fires activate from mouseup without checking the
    // button, so a right-click would otherwise follow the link. On macOS this
    // is also what rejects Ctrl+left-click, delivered by Chromium as button 2.
    expect(isLinkActivationEvent(mouseEvent({ button: 2, ctrlKey: true }))).toBe(false)
    expect(isLinkActivationEvent(mouseEvent({ button: 2, metaKey: true }))).toBe(false)
    expect(isLinkActivationEvent(mouseEvent({ button: 1, metaKey: true }))).toBe(false)
  })
})
