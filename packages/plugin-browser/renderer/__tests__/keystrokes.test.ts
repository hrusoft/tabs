import { describe, expect, it } from 'vitest'
import { keystrokeEvents, typingEvents } from '../keystrokes'

/** Just the event types, for the cases where only the shape of the press matters. */
const types = (events: { type: string }[]) => events.map((event) => event.type)

describe('keystrokeEvents', () => {
  it('presses Enter as keydown, keypress and keyup, which is what submits a form', () => {
    expect(keystrokeEvents('Enter')).toEqual([
      { type: 'keyDown', keyCode: 'Enter', modifiers: [] },
      { type: 'char', keyCode: 'Enter', modifiers: [] },
      { type: 'keyUp', keyCode: 'Enter', modifiers: [] }
    ])
    expect(types(keystrokeEvents('Return'))).toEqual(['keyDown', 'char', 'keyUp'])
    expect(types(keystrokeEvents('Space'))).toEqual(['keyDown', 'char', 'keyUp'])
  })

  it('gives a printable key its character, and shift to a capital letter', () => {
    expect(types(keystrokeEvents('a'))).toEqual(['keyDown', 'char', 'keyUp'])
    expect(keystrokeEvents('A')).toEqual([
      { type: 'keyDown', keyCode: 'A', modifiers: ['shift'] },
      { type: 'char', keyCode: 'A', modifiers: ['shift'] },
      { type: 'keyUp', keyCode: 'A', modifiers: ['shift'] }
    ])
    // Not doubled when the caller already holds it.
    expect(keystrokeEvents('A', ['shift'])[0]?.modifiers).toEqual(['shift'])
    // Symbols get their shift from Electron itself — nothing added here.
    expect(keystrokeEvents('!')[0]?.modifiers).toEqual([])
  })

  it('sends no character for a named key that produces none', () => {
    // A char for F5 would type the text "F5" into the field.
    for (const key of ['F5', 'Tab', 'Escape', 'Backspace', 'Delete', 'Home', 'ArrowLeft']) {
      expect(types(keystrokeEvents(key)), key).toEqual(['keyDown', 'keyUp'])
    }
  })

  it('drops the character whenever meta or control is held', () => {
    for (const modifier of ['meta', 'control'] as const) {
      expect(types(keystrokeEvents('Enter', [modifier])), modifier).toEqual(['keyDown', 'keyUp'])
      expect(types(keystrokeEvents('k', [modifier])), modifier).toEqual(['keyDown', 'keyUp'])
      expect(keystrokeEvents('k', [modifier])[0]?.modifiers).toEqual([modifier])
    }
    // Shift and alt still produce one: shift+Enter is a line break in a textarea.
    expect(types(keystrokeEvents('Enter', ['shift']))).toEqual(['keyDown', 'char', 'keyUp'])
    expect(types(keystrokeEvents('a', ['alt']))).toEqual(['keyDown', 'char', 'keyUp'])
  })

  it('translates the DOM arrow names to the accelerator tokens sendInputEvent needs', () => {
    expect(keystrokeEvents('ArrowLeft', ['alt'])).toEqual([
      { type: 'keyDown', keyCode: 'Left', modifiers: ['alt'] },
      { type: 'keyUp', keyCode: 'Left', modifiers: ['alt'] }
    ])
    expect(keystrokeEvents('ArrowDown')[0]?.keyCode).toBe('Down')
  })
})

describe('typingEvents', () => {
  it('types each printable ASCII character as a full keystroke', () => {
    const events = typingEvents('Hi!')
    expect(events.map(({ type, keyCode }) => `${type}:${keyCode}`)).toEqual([
      'keyDown:H',
      'char:H',
      'keyUp:H',
      'keyDown:i',
      'char:i',
      'keyUp:i',
      'keyDown:!',
      'char:!',
      'keyUp:!'
    ])
    // Exactly one character event per character typed: nothing can double.
    expect(events.filter((event) => event.type === 'char')).toHaveLength(3)
  })

  it('sends a character with no key behind it as a lone char', () => {
    expect(typingEvents('é日')).toEqual([
      { type: 'char', keyCode: 'é', modifiers: [] },
      { type: 'char', keyCode: '日', modifiers: [] }
    ])
    // Iterated by code point, so an astral character stays whole.
    expect(typingEvents('😀')).toEqual([{ type: 'char', keyCode: '😀', modifiers: [] }])
  })
})
