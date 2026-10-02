import type { KeyModifier } from '../shared/externalControl'

/**
 * Which `sendInputEvent` keyboard events make up one keystroke — the rules
 * `key` and `type` share, kept free of Electron so they can be unit-tested.
 *
 * A physical key press reaches a page as `keydown`, then — for a key that
 * produces a character — `keypress` (plus `beforeinput`/`input` when it
 * inserts), then `keyup`. `sendInputEvent` builds that from three events:
 * `keyDown` for the keydown, `char` for the keypress and any insertion, and
 * `keyUp`. Measured on a real guest, each of the ways this used to deviate:
 *
 * - **Enter got no `char`**, so no `keypress` — and Chromium submits a form
 *   implicitly from Enter's keypress, so `key --key Enter` and `type
 *   --submit` never submitted a plain form. With the `char`, a text input
 *   submits its form exactly once and a textarea gains one line break.
 * - **`type` sent only `char`s**, so a page saw `keypress`/`input` but never
 *   `keydown`/`keyup` for typed text — invisible to key-driven autocompletes
 *   and every `onKeyDown` handler. Printable ASCII now gets all three, and a
 *   character still lands exactly once (the `keyDown` inserts nothing).
 * - **A capital letter arrived without Shift**: `keyDown 'H'` reports
 *   `key: 'h', shiftKey: false`, a keydown no keyboard can produce. Adding
 *   shift reports `key: 'H', shiftKey: true`. Symbols need nothing:
 *   Electron sets shift for `!`/`+` itself.
 *
 * And the ones that must stay without a `char`:
 *
 * - **Other named keys.** A `char` for `F5` *types the text "F5"* into the
 *   field; for Tab, Escape, Delete, Home and the arrows it does nothing. Only
 *   Enter/Return and Space produce a character.
 * - **Any chord with meta or control.** On macOS those produce no character
 *   — the page sees `keydown`/`keyup` only — and a `char` there would, for
 *   instance, let Cmd+Enter submit a form. This follows Chromium's physical
 *   behaviour as best measured without a real keyboard (the `char` *was*
 *   delivered with meta held, so this is a choice, not a limit).
 * - **A character with no key behind it** (é, 日, an emoji): `keyDown` for
 *   one produces a keydown with an empty `key` and `keyCode` 0, which is
 *   worse than none — so non-ASCII text arrives as `char` alone, the way an
 *   IME or the character palette delivers text.
 */
export interface KeystrokeEvent {
  type: 'keyDown' | 'char' | 'keyUp'
  keyCode: string
  modifiers: KeyModifier[]
}

/**
 * DOM `KeyboardEvent.key`/`code` spelling → Electron's Accelerator
 * vocabulary, for the one family measured to differ: the arrow keys.
 * `sendInputEvent`'s `keyCode` field must be a valid Accelerator token (its
 * own doc: "Should only use valid Accelerator key codes") — 'Left', not the
 * DOM 'ArrowLeft'. An unrecognized token doesn't fail gracefully or fail only
 * under some modifier: measured directly (a real guest's keydown listener,
 * every modifier crossed with all four arrows), `keyCode: 'ArrowLeft'`
 * produces a completely null `KeyboardEvent` — `key: '', code: '', keyCode:
 * 0` — regardless of which modifier rides along, alt included; `'Left'`
 * produces the correct `key`/`code` (and `altKey`/`shiftKey`/`ctrlKey` set
 * correctly) every time. Scoped to exactly the mismatched family: `'Enter'`,
 * `'Escape'`, `'Tab'` and single letters (the other names this app actually
 * sends) already match Electron's vocabulary and were never observed to
 * break, so they pass through untouched rather than guessing at a wider
 * translation nothing has shown is needed.
 */
const DOM_TO_ACCELERATOR_KEY: Record<string, string> = {
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowUp: 'Up',
  ArrowDown: 'Down'
}

/** Named keys whose press produces a character (and so a keypress) — measured. */
const CHARACTER_NAMED_KEYS = new Set(['Enter', 'Return', 'Space'])

/** One printable ASCII character: the range with a key behind every character. */
function isPrintableAscii(text: string): boolean {
  if (text.length !== 1) return false
  const code = text.charCodeAt(0)
  return code >= 0x20 && code <= 0x7e
}

/** The events for one press of `key` (a DOM key name or a single character) with `modifiers` held. */
export function keystrokeEvents(
  key: string,
  modifiers: readonly KeyModifier[] = []
): KeystrokeEvent[] {
  const keyCode = DOM_TO_ACCELERATOR_KEY[key] ?? key
  const held = [...modifiers]
  if (/^[A-Z]$/.test(keyCode) && !held.includes('shift')) held.push('shift')
  const chord = held.includes('meta') || held.includes('control')
  const producesCharacter = isPrintableAscii(keyCode) || CHARACTER_NAMED_KEYS.has(keyCode)
  return [
    { type: 'keyDown', keyCode, modifiers: held },
    ...(producesCharacter && !chord ? [{ type: 'char' as const, keyCode, modifiers: held }] : []),
    { type: 'keyUp', keyCode, modifiers: held }
  ]
}

/**
 * The events for typing `text`, character by character: a full keystroke for
 * printable ASCII, a lone `char` for anything else (see the module doc).
 * Control characters never reach here — `type` refuses them first.
 */
export function typingEvents(text: string): KeystrokeEvent[] {
  const events: KeystrokeEvent[] = []
  for (const character of text) {
    if (isPrintableAscii(character)) events.push(...keystrokeEvents(character))
    else events.push({ type: 'char', keyCode: character, modifiers: [] })
  }
  return events
}
