import type { ControlRequest, ControlResponse } from '@shared/externalControl'
import type { WebviewTag } from 'electron'
import type { EditingCommand, ElementDescription, KeyModifier } from '../shared/externalControl'
import { EDITING_COMMANDS } from '../shared/externalControl'
import { suppressGuestActivation } from './guestActivation'
import { editingCommandScript, fillFocusedScript, scrollScript } from './pageScripts'
import { delay } from './pageWait'
import { clickAt, describeForError, focusTypingTarget, resolveClickTarget } from './targeting'
import { evalInGuest, evalOutcomeInGuest } from './verbSupport'

/**
 * The verbs that drive a page with input — click, hover, type, key, scroll
 * and formInput — and the host-focus guard they run under.
 */

/**
 * Runs an input verb, then puts host focus back where it was — and keeps the
 * pane it drove from becoming the active one.
 *
 * None of the verbs focus the webview themselves, but the *guest* pulls host
 * focus onto the `<webview>` element anyway when a script inside it calls
 * `el.focus()` or a synthesized click lands (same propagation an iframe
 * gets) — measured in the e2e focus test. Left alone, that yanks the
 * keyboard away from the terminal the user is typing in every time an agent
 * drives its pane. Restoring costs the verbs nothing: `sendInputEvent`
 * injects straight into the guest, and the guest's internal activeElement
 * survives the host-side blur, so later verbs still land where they should.
 *
 * Suppressing activation is the same stance one layer up, and is required
 * rather than tidy: since a guest press now activates its pane
 * (src/plugins/browser/main/guestActivation.ts), an agent's `click` would move the
 * active-pane highlight, and core's focus-follows-active would then call the
 * browser handle's `focus()` — landing the keyboard in the webview by the
 * very route the focus restore above exists to prevent.
 *
 * Accepted residual: a *genuine* user click into that same guest during the
 * verb and its 50ms tail is swallowed. It's a ~50ms window against an agent
 * actively driving that pane, and the user's second click lands.
 *
 * Applied at registration (browserExternalControl.ts) rather than inside each handler, and browser
 * knowledge rather than core's: which verbs can pull host focus is a fact
 * about `<webview>` guests, so the dispatcher must not need to know it.
 */
export async function withHostFocusRestored<T>(action: () => Promise<T>): Promise<T> {
  const previous = document.activeElement
  const allowActivationAgain = suppressGuestActivation()
  try {
    return await action()
  } finally {
    // The pull can land a tick after the last injected event.
    await delay(50)
    allowActivationAgain()
    if (
      document.activeElement !== previous &&
      document.activeElement?.tagName === 'WEBVIEW' &&
      previous instanceof HTMLElement &&
      previous.isConnected
    ) {
      previous.focus()
    }
  }
}

export async function handleClick(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'click' }>
): Promise<ControlResponse> {
  const point = await resolveClickTarget(webview, request.target)
  if ('error' in point) return { ok: false, error: point.error }
  // Deliberately no webview.focus() — sendInputEvent injects straight into
  // the guest's input pipeline; what focus the guest pulls anyway is undone
  // by withHostFocusRestored at the dispatch site.
  //
  // One executeJavaScript→sendInputEvent round trip remains between the
  // hit-test above and the events landing — unclosable without giving up
  // real input events, since dispatch is host-side by design. The window
  // shrank from scroll+round-trip+queue to just the round trip.
  clickAt(webview, point.x, point.y)
  return {
    ok: true,
    result: { x: point.x, y: point.y, ...(point.element ? { element: point.element } : {}) }
  }
}

/**
 * Moves the pointer onto the target and stops there — no press.
 *
 * Resolution is `click`'s, unchanged: the same `resolveClickTarget`, so a ref
 * is scrolled into view and hit-tested, a covered element fails naming both,
 * and a coordinate is taken as given. What differs is only the dispatch, which
 * is why this reads as three lines rather than as a parallel implementation.
 *
 * The hover *persists* — Chromium holds the hovered element until the next
 * pointer event reaches the guest — so the follow-up read that inspects what
 * appeared does not need to re-hover to keep a menu open. A second hover onto
 * the same point is still a real `mousemove`, but produces no fresh
 * `mouseenter`, which is exactly what a real pointer sitting still does.
 */
export async function handleHover(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'hover' }>
): Promise<ControlResponse> {
  const point = await resolveClickTarget(webview, request.target)
  if ('error' in point) return { ok: false, error: point.error }
  webview.sendInputEvent({ type: 'mouseMove', x: point.x, y: point.y })
  return {
    ok: true,
    result: { x: point.x, y: point.y, ...(point.element ? { element: point.element } : {}) }
  }
}

/** Sends `text` as real per-character events to whatever the guest has focused. */
function typeChars(webview: WebviewTag, text: string): void {
  for (const character of text) {
    webview.sendInputEvent({ type: 'char', keyCode: character })
  }
}

/**
 * Characters `typeChars` cannot deliver: Chromium's keyboard pipeline drops a
 * `char` event whose character has no key behind it — every C0 control
 * (newline included) and DEL — on the floor, with nothing observable to the
 * sender. `type` therefore refuses such text up front rather than silently
 * sending fewer keystrokes than asked; the error names the exact character
 * and where multiline values should go instead. A charCode walk rather
 * than a regex: biome refuses control characters in regex literals even
 * escaped (noControlCharactersInRegex).
 */
function untypeableCharError(text: string): string | null {
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index)
    if (code >= 0x20 && code !== 0x7f) continue
    const described =
      code === 10
        ? 'a newline'
        : code === 13
          ? 'a carriage return'
          : code === 9
            ? 'a tab'
            : `control character 0x${code.toString(16).padStart(2, '0')}`
    return `text contains ${described} at index ${index}, which keystrokes cannot enter — use form-input to set a multiline value verbatim, or key (e.g. --key Enter, --key Tab) to press the key itself`
  }
  return null
}
/**
 * Sends `text` as real character events to whatever the target focuses, then
 * optionally an Enter. Text the char pipeline cannot carry is refused before
 * anything is focused, so a rejected call leaves the page untouched.
 */
export async function handleType(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'type' }>
): Promise<ControlResponse> {
  const untypeable = untypeableCharError(request.text)
  if (untypeable) return { ok: false, error: untypeable }

  // focusTypingTarget's errors arrive complete — a semantic failure already
  // names its candidates or its remedy, and a generic suffix appended here
  // would read as noise after them.
  const focusError = await focusTypingTarget(webview, request.target)
  if (focusError) {
    return { ok: false, error: focusError }
  }

  typeChars(webview, request.text)
  if (request.submit) sendKey(webview, 'Enter')
  return { ok: true }
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

function sendKey(webview: WebviewTag, key: string, modifiers: KeyModifier[] = []): void {
  const keyCode = DOM_TO_ACCELERATOR_KEY[key] ?? key
  webview.sendInputEvent({ type: 'keyDown', keyCode, modifiers })
  // A printable key also needs the char event to actually insert anything —
  // keyDown alone fires the handler but leaves the field empty.
  if (keyCode.length === 1) webview.sendInputEvent({ type: 'char', keyCode, modifiers })
  webview.sendInputEvent({ type: 'keyUp', keyCode, modifiers })
}

/**
 * The wire's kebab-case command names → `document.execCommand`'s own spelling.
 * Two vocabularies rather than one because the wire name is a CLI flag value
 * and `selectAll` reads wrong beside `--role`/`--max-length`; the mapping is
 * one line each and keeps `EDITING_COMMANDS` free to be the caller-facing
 * list. See editingCommandScript for why this is execCommand and not the
 * `WebContents` methods of the same names, which are measurably inert on a
 * `<webview>` guest.
 */
const EDITING_COMMAND_NAMES: Record<EditingCommand, string> = {
  'select-all': 'selectAll',
  undo: 'undo',
  redo: 'redo',
  delete: 'delete'
}

/**
 * Letters Chromium claims for its own editing commands under meta/control. A
 * chord naming one is delivered faithfully and still does nothing to the
 * selection or the clipboard, which is the silent-corruption trap this note
 * exists to break: the verb answered `ok: true`, a follow-up Backspace also
 * answered `ok: true`, and between them a field lost one character instead of
 * all of them.
 *
 * The chord is **not refused**. A page's own JS shortcut handlers do fire for
 * it — measured — so refusing would break the legitimate case (an app that
 * binds Cmd+K) to protect the illegitimate one. Reporting alongside the
 * success is what makes the answer honest without taking a capability away.
 */
const EDITING_CHORD_KEYS = new Set(['a', 'c', 'v', 'x', 'z', 'y'])

function editingChordNote(request: Extract<ControlRequest, { type: 'key' }>): string | undefined {
  const modifiers = request.modifiers ?? []
  if (!modifiers.includes('meta') && !modifiers.includes('control')) return undefined
  if (typeof request.key !== 'string' || !EDITING_CHORD_KEYS.has(request.key.toLowerCase())) {
    return undefined
  }
  return "the keystroke was delivered and the page's own handlers saw it, but Chromium's built-in editing commands do not respond to a synthesized chord — the selection and clipboard are unchanged. Use --command (select-all, undo, redo, delete) for those, or form-input to replace a field's value"
}

export async function handleKey(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'key' }>
): Promise<ControlResponse> {
  const named = typeof request.key === 'string' && request.key !== ''
  const commanded = request.command !== undefined
  if (named === commanded) {
    return {
      ok: false,
      error: named
        ? 'pass only one of key or command — a keystroke and an editing command are different things'
        : `key needs one of key (a keystroke) or command (${EDITING_COMMANDS.join(', ')})`
    }
  }
  if (commanded) {
    const execName = EDITING_COMMAND_NAMES[request.command as EditingCommand]
    if (!execName) {
      return {
        ok: false,
        error: `unknown command ${JSON.stringify(request.command)} — one of ${EDITING_COMMANDS.join(', ')}`
      }
    }
    // Acts on whatever the guest has focused, exactly as the menu item would.
    const run = await evalOutcomeInGuest<{ applied: boolean; element: ElementDescription | null }>(
      webview,
      editingCommandScript(execName)
    )
    if ('error' in run) return { ok: false, error: run.error }
    const outcome = run.value
    if (!outcome.applied) {
      return {
        ok: false,
        error: `the page refused the ${request.command} command${outcome.element ? ` on ${describeForError(outcome.element)}` : ' (nothing is focused)'}`
      }
    }
    return {
      ok: true,
      result: {
        command: request.command,
        ...(outcome.element ? { element: outcome.element } : {})
      }
    }
  }
  sendKey(webview, request.key as string, request.modifiers ?? [])
  const note = editingChordNote(request)
  return { ok: true, ...(note ? { result: { note } } : {}) }
}

/**
 * Scrolls the document and reports where it landed — the *settled* position,
 * not a snapshot taken mid-animation. See scrollScript for both halves of why
 * that used to be wrong (a smooth page's animation, and a zero-sized step on a
 * backgrounded pane); neither needs anything from the host, which is why this
 * handler no longer measures the element.
 */
export async function handleScroll(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'scroll' }>
): Promise<ControlResponse> {
  const run = await evalInGuest<unknown>(webview, scrollScript(request.direction, request.amount))
  if ('error' in run) return { ok: false, error: run.error }
  return { ok: true, result: { position: run.value } }
}

/** What `fillFocusedScript` reports back — see its doc in pageScripts.ts. */
type FillOutcome =
  | { mode: 'none' }
  | { mode: 'unfillable'; element: ElementDescription }
  | { mode: 'select'; matched: boolean; options?: string[]; length?: number }
  | { mode: 'set'; length: number; tag: string }
  | { mode: 'editable'; length: number }
  | { mode: 'error'; error: string }

/**
 * Fills fields in order, replacing whatever each already contains. Sequential
 * rather than parallel because focus is a single shared resource — filling
 * two fields at once would race for it — and a field that fails is reported
 * and skipped rather than aborting the rest of the form.
 *
 * Every value is written in-script by `fillFocusedScript` — nothing here
 * types characters, because the char-event pipeline silently drops `\n` and
 * every other key-less character (see that script's doc; `type` keeps the
 * pipeline because its contract is keystrokes, and it refuses such text).
 *
 * The response reports what each element actually holds after its fill:
 * `fields` carries `{index, length}` per filled field, read back from the
 * element itself, so a caller can check `length` against the value it sent in
 * one glance. An `<input>`/`<textarea>` whose read-back length differs from
 * the requested value's goes to `errors` instead of counting as filled —
 * Chromium sanitizes on write (a single-line `<input>` strips newlines), and
 * "the field doesn't hold what you sent" must never report as success.
 * Contenteditable is exempt from that strict check: its `length` is measured
 * on `innerText`, which normalizes blank lines, so a byte-exact comparison
 * would fail legitimate fills.
 */
export async function handleFormInput(
  webview: WebviewTag,
  request: Extract<ControlRequest, { type: 'formInput' }>
): Promise<ControlResponse> {
  let filled = 0
  const fields: { index: number; length: number }[] = []
  const errors: { index: number; error: string }[] = []
  for (const [index, field] of request.fields.entries()) {
    const focusError = await focusTypingTarget(webview, field.target)
    if (focusError) {
      errors.push({ index, error: focusError })
      continue
    }
    // The script catches its own throws; an error here means the guest
    // couldn't run script at all (navigated away mid-fill, an error page).
    const run = await evalOutcomeInGuest<FillOutcome>(webview, fillFocusedScript(field.value))
    if ('error' in run) {
      errors.push({ index, error: run.error })
      continue
    }
    const outcome = run.value
    switch (outcome.mode) {
      case 'select':
        if (outcome.matched) {
          filled++
          fields.push({ index, length: outcome.length ?? field.value.length })
        } else {
          const options = outcome.options?.length ? ` (options: ${outcome.options.join(', ')})` : ''
          errors.push({
            index,
            error: `no option matching ${JSON.stringify(field.value)}${options}`
          })
        }
        break
      case 'set':
        if (outcome.length === field.value.length) {
          filled++
          fields.push({ index, length: outcome.length })
        } else {
          const why =
            outcome.tag === 'input' && /[\r\n]/.test(field.value)
              ? 'a single-line <input> cannot hold newlines; target a <textarea> instead'
              : 'the element rewrote or refused part of the value'
          errors.push({
            index,
            error: `the field holds ${outcome.length} of the ${field.value.length} characters sent — ${why}`
          })
        }
        break
      case 'editable':
        filled++
        fields.push({ index, length: outcome.length })
        break
      case 'unfillable':
        errors.push({
          index,
          error: `${describeForError(outcome.element)} is not a fillable field — use click for buttons, checkboxes and radios`
        })
        break
      case 'error':
        errors.push({ index, error: `could not set the value: ${outcome.error}` })
        break
      default:
        errors.push({
          index,
          error: 'the target did not leave a field focused, so there is nothing to fill'
        })
    }
  }
  return {
    ok: true,
    result: {
      filled,
      ...(fields.length > 0 ? { fields } : {}),
      ...(errors.length > 0 ? { errors } : {})
    }
  }
}
