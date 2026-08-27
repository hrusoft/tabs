import {
  bindingsEqual,
  findConflict,
  formatBinding,
  formatChordAsQuery,
  hasRequiredModifier,
  isBareCtrlLetterChord,
  isOverridden,
  isReservedBinding,
  type KeyBinding,
  parseSearchChord,
  resolveBinding,
  SHORTCUT_ACTIONS,
  type ShortcutActionDef,
  type ShortcutActionId,
  type ShortcutOverrides,
  type ShortcutSettingsLike,
  shortcutAction,
  toAccelerator
} from '@shared/shortcuts'
import { type KeyboardEvent as ReactKeyboardEvent, useEffect, useRef, useState } from 'react'
import { flushSync } from 'react-dom'
import { platform } from '../core/platform'
import { useSettingsStore } from '../core/store/settingsStore'

/** Keys that only ever modify another key — held down while a combination is being formed. */
const MODIFIER_KEYS = new Set(['Meta', 'Control', 'Alt', 'Shift', 'CapsLock', 'AltGraph'])

/** One-line feedback under a row's title, replacing its description until the next interaction. */
interface Notice {
  id: ShortcutActionId
  text: string
  tone: 'error' | 'info'
}

/** The combination `event` describes, with the pressed modifiers folded into `mod`/`ctrl`. */
function bindingFromEvent(event: KeyboardEvent): KeyBinding {
  const binding: KeyBinding = { code: event.code }
  // Off macOS, Control *is* the platform modifier, so it lands in `mod` and
  // `ctrl` is never set — see KeyBinding.
  if (platform === 'darwin' ? event.metaKey : event.ctrlKey) binding.mod = true
  if (platform === 'darwin' && event.ctrlKey) binding.ctrl = true
  if (event.altKey) binding.alt = true
  if (event.shiftKey) binding.shift = true
  return binding
}

/** The modifiers currently held, for the live preview while a combination is still forming. */
function heldModifiers(event: KeyboardEvent): string {
  const held = bindingFromEvent(event)
  held.code = ''
  return formatBinding(held, platform, '')
}

const MODIFIER_HINT = platform === 'darwin' ? '⌘, ⌃ or ⌥' : 'Ctrl or Alt'

/**
 * The visible actions for `query`, grouped in registration order: empty
 * matches everything; a parseable combination matches the action currently
 * bound to it exactly (see parseSearchChord); otherwise a case-insensitive
 * substring of the label, description, or group name matches. The two are
 * independent, not exclusive — a query that happens to parse as a chord still
 * falls back to the text check too, though in practice the two rarely both hit
 * the same query.
 *
 * Grouped in the same single pass that filters, and the query is parsed once
 * for the whole pass rather than per action: this runs on every keystroke in
 * the search box, and the action registry is the thing that grows.
 */
function visibleGroups(
  query: string,
  settings: ShortcutSettingsLike
): Array<[string, ShortcutActionDef[]]> {
  const trimmed = query.trim()
  const needle = trimmed.toLowerCase()
  const chord = trimmed === '' ? null : parseSearchChord(trimmed, platform)
  const grouped = new Map<string, ShortcutActionDef[]>()
  for (const action of SHORTCUT_ACTIONS) {
    const matches =
      trimmed === '' ||
      (chord && bindingsEqual(chord, resolveBinding(settings, action.id))) ||
      action.label.toLowerCase().includes(needle) ||
      action.description.toLowerCase().includes(needle) ||
      action.group.toLowerCase().includes(needle)
    if (!matches) continue
    const bucket = grouped.get(action.group)
    if (bucket) bucket.push(action)
    else grouped.set(action.group, [action])
  }
  return [...grouped]
}

export function KeyboardSettings() {
  // The one key this page reads plus the setter, never the whole store: a
  // whole-store subscription re-renders every row (and re-runs visibleGroups
  // over the action registry) on every tick of a sibling page's slider drag —
  // the same narrowing useCreationActions documents.
  const shortcuts = useSettingsStore((state) => state.shortcuts)
  const setSetting = useSettingsStore((state) => state.setSetting)
  const settings: ShortcutSettingsLike = { shortcuts }
  const [capturing, setCapturing] = useState<ShortcutActionId | null>(null)
  const [preview, setPreview] = useState('')
  const [notice, setNotice] = useState<Notice | null>(null)
  const [query, setQuery] = useState('')
  const [searchFocused, setSearchFocused] = useState(false)
  const searchInputRef = useRef<HTMLInputElement>(null)

  /**
   * Writes the whole overrides record — never a patch. `shortcuts` is a flat
   * settings key, so main replaces it wholesale (see Settings.shortcuts);
   * sending only the changed entry would drop every other rebinding.
   */
  const write = (mutate: (next: ShortcutOverrides) => void): void => {
    const next: ShortcutOverrides = { ...shortcuts }
    mutate(next)
    setSetting('shortcuts', next)
  }

  const commit = (id: ShortcutActionId, binding: KeyBinding): void => {
    if (toAccelerator(binding, platform) === null) {
      setNotice({ id, text: 'That key cannot be used as a shortcut.', tone: 'error' })
      return
    }
    if (!hasRequiredModifier(binding)) {
      // Without a modifier the capture-phase handler would take this key away
      // from every terminal pane in the app — see hasRequiredModifier.
      setNotice({ id, text: `Add ${MODIFIER_HINT} to the combination.`, tone: 'error' })
      return
    }
    if (isReservedBinding(binding)) {
      setNotice({
        id,
        text: `${formatBinding(binding, platform)} is reserved by the system.`,
        tone: 'error'
      })
      return
    }

    // Reassign rather than reject: two menu items sharing a key equivalent is
    // resolved silently and arbitrarily by macOS, so the one-combination-one-
    // action invariant has to hold. The loser is left visibly unbound, one
    // click from Reset, and told about below.
    const conflict = findConflict(settings, binding, id)
    write((next) => {
      if (conflict) next[conflict.id] = null
      // Back to the shipped default: drop the override entirely rather than
      // store a copy of it, so the row reads as un-overridden again.
      if (bindingsEqual(binding, shortcutAction(id).defaultBinding)) delete next[id]
      else next[id] = binding
    })
    setCapturing(null)

    if (conflict) {
      setNotice({ id, text: `Taken from ${conflict.label}, now unset.`, tone: 'info' })
      // The shared helper reports only the chord's shape; that this shape is
      // worth warning about — and that a terminal pane is what claims it — is
      // this window's judgement to make and word.
    } else if (isBareCtrlLetterChord(binding, platform)) {
      setNotice({
        id,
        text: `${formatBinding(binding, platform)} is also used by programs in terminal panes.`,
        tone: 'info'
      })
    } else {
      setNotice(null)
    }
  }

  // `commit` closes over the current settings, so the listener below has to
  // reach the latest one. Via a ref rather than an effect dependency: the
  // effect toggles capture mode, which rebuilds the real application menu, so
  // re-running it on every render (a held modifier updates the preview on each
  // keypress) would thrash the menu several times per recorded combination.
  // Written from an (undepped) effect rather than in the render body, so a
  // render React discards can never leave the ref pointing at a closure over
  // state that was never committed.
  const commitRef = useRef(commit)
  useEffect(() => {
    commitRef.current = commit
  })

  // Suspends every customizable menu accelerator while either of this page's
  // two reasons to want the keystroke itself is live: a chip recording a new
  // combination, and the search box, where pressing a bound combination must
  // type it out as text rather than perform it. Both need the same thing —
  // macOS matches a menu key equivalent before the keystroke reaches any
  // renderer, so a `preventDefault` here can't stop something the menu already
  // claimed, and ⌘T, ⌘W, ⌘K and ⌘, would never arrive.
  //
  // Deliberately ONE effect over a derived flag rather than one per reason:
  // main models capture as a single owning webContents id with no nesting and
  // no refcount (see src/main/shortcuts.ts), so a second arm from this window
  // is a no-op while *any* disarm clears it outright. Two effects would let
  // whichever released first hand the accelerators back while the other still
  // needed them — blurring the search box would silently un-suspend the menu
  // with a chip still reading "Press keys…". Main also releases it by itself
  // if this window closes mid-capture.
  //
  // The four renderer-enforced nav actions need none of this, for a simpler
  // reason than "something guards against it": content/spatialNav.ts's
  // listener is installed only by App.tsx's mount effect, and this Settings
  // window (settings-main.tsx) never renders App, so no nav-key enforcement
  // runs in this renderer at all.
  const captureArmed = capturing !== null || searchFocused
  useEffect(() => {
    if (!captureArmed) return
    window.api.shortcuts.setCaptureMode(true)
    return () => {
      window.api.shortcuts.setCaptureMode(false)
    }
  }, [captureArmed])

  useEffect(() => {
    if (!capturing) return

    const onKeyDown = (event: KeyboardEvent): void => {
      // Tab keeps moving focus, so the page stays keyboard-navigable and there
      // is always a way out that isn't the mouse. Deliberately not bindable.
      if (event.key === 'Tab') {
        setCapturing(null)
        return
      }
      event.preventDefault()
      event.stopPropagation()
      if (event.key === 'Escape') {
        setCapturing(null)
        return
      }
      if (MODIFIER_KEYS.has(event.key)) {
        setPreview(heldModifiers(event))
        return
      }
      commitRef.current(capturing, bindingFromEvent(event))
    }
    const onKeyUp = (event: KeyboardEvent): void => {
      if (MODIFIER_KEYS.has(event.key)) setPreview(heldModifiers(event))
    }
    const onBlur = (): void => setCapturing(null)

    window.addEventListener('keydown', onKeyDown, true)
    window.addEventListener('keyup', onKeyUp, true)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener('keydown', onKeyDown, true)
      window.removeEventListener('keyup', onKeyUp, true)
      window.removeEventListener('blur', onBlur)
      setPreview('')
    }
  }, [capturing])

  /**
   * A real modifier held (mod/ctrl/alt — bare Shift is ordinary typing, e.g.
   * a capital letter) means this keystroke is a shortcut, not text: spliced
   * into the query at the cursor as its canonical search text instead of
   * whatever the key would otherwise have done, exactly as if that text had
   * been typed by hand. Everything else — letters, digits, arrows,
   * Backspace — passes through untouched.
   */
  const handleSearchKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>): void => {
    if (MODIFIER_KEYS.has(event.key)) return
    const chord = bindingFromEvent(event.nativeEvent)
    if (!hasRequiredModifier(chord)) return
    const text = formatChordAsQuery(chord, platform)
    if (text === null) return
    event.preventDefault()
    event.stopPropagation()
    const input = event.currentTarget
    const start = input.selectionStart ?? query.length
    const end = input.selectionEnd ?? query.length
    // Flushed rather than deferred to an effect: React resets a controlled
    // input's cursor to the end on a value change, so the caret has to be put
    // back after the DOM has the new value but before the browser paints —
    // otherwise typing a combination into the middle of an existing query
    // jumps the cursor. Sanctioned here because this is already an event
    // handler, which is the one place flushSync costs nothing extra.
    flushSync(() => setQuery(query.slice(0, start) + text + query.slice(end)))
    const caret = start + text.length
    input.setSelectionRange(caret, caret)
  }

  const startCapture = (id: ShortcutActionId): void => {
    setNotice(null)
    setPreview('')
    setCapturing((current) => (current === id ? null : id))
  }

  // Every mutation that isn't itself a capture settles the recorder first:
  // clear the notice, leave capture mode, then apply.
  const settleAnd = (apply: () => void): void => {
    setNotice(null)
    setCapturing(null)
    apply()
  }

  const groups = visibleGroups(query, settings)

  return (
    <div data-testid="settings-page-keyboard">
      <h1 className="settings-page-title">Keyboard</h1>
      <section className="settings-section">
        <div className="settings-search">
          <input
            ref={searchInputRef}
            type="text"
            className="settings-search-input"
            data-testid="settings-shortcut-search"
            placeholder="Search shortcuts, or press a combination…"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onFocus={() => {
              // Ends any chip recording first: its window-level capture-phase
              // keydown listener preventDefaults every keystroke, so leaving it
              // armed would make this box impossible to type in — and each
              // letter would be offered to the chip as a combination.
              setCapturing(null)
              setSearchFocused(true)
            }}
            onBlur={() => setSearchFocused(false)}
            onKeyDown={handleSearchKeyDown}
          />
          <button
            type="button"
            className="settings-search-clear"
            data-testid="settings-shortcut-search-clear"
            aria-label="Clear search"
            disabled={query === ''}
            onClick={() => {
              setQuery('')
              searchInputRef.current?.focus()
            }}
          >
            ×
          </button>
        </div>
      </section>
      <section className="settings-section">
        <p className="settings-section-desc">
          Click a shortcut to record a new combination, then press it. Escape cancels. Combinations
          the system owns (Copy, Quit, Undo…) and keys scoped to one control (Escape, Enter, Tab)
          can&rsquo;t be reassigned.
        </p>
      </section>
      {groups.length === 0 && (
        <section className="settings-section">
          <p className="settings-section-desc" data-testid="settings-shortcuts-empty">
            No shortcuts match your search.
          </p>
        </section>
      )}
      {groups.map(([group, actions]) => (
        <section className="settings-section" key={group}>
          <h3 className="settings-section-title">{group}</h3>
          {actions.map((action) => (
            <ShortcutRow
              key={action.id}
              action={action}
              binding={resolveBinding(settings, action.id)}
              overridden={isOverridden(settings, action.id)}
              capturing={capturing === action.id}
              preview={preview}
              notice={notice?.id === action.id ? notice : null}
              onCapture={() => startCapture(action.id)}
              onClear={() =>
                settleAnd(() =>
                  write((next) => {
                    next[action.id] = null
                  })
                )
              }
              onReset={() =>
                settleAnd(() =>
                  write((next) => {
                    delete next[action.id]
                  })
                )
              }
            />
          ))}
        </section>
      ))}
      <section className="settings-section">
        <div className="settings-row settings-row-action">
          <span className="settings-row-text">
            <span className="settings-row-title">Restore defaults</span>
            <span className="settings-row-desc">
              Put every shortcut back to the combination it ships with.
            </span>
          </span>
          <span className="settings-row-buttons">
            <button
              type="button"
              className="settings-secondary-button"
              data-testid="settings-shortcuts-restore-defaults"
              onClick={() => settleAnd(() => setSetting('shortcuts', {}))}
            >
              Restore Defaults
            </button>
          </span>
        </div>
      </section>
    </div>
  )
}

function ShortcutRow({
  action,
  binding,
  overridden,
  capturing,
  preview,
  notice,
  onCapture,
  onClear,
  onReset
}: {
  action: ShortcutActionDef
  binding: KeyBinding | null
  overridden: boolean
  capturing: boolean
  preview: string
  notice: Notice | null
  onCapture: () => void
  onClear: () => void
  onReset: () => void
}) {
  return (
    <div className="settings-row settings-row-action">
      <span className="settings-row-text">
        <span className="settings-row-title">{action.label}</span>
        <span className="settings-row-desc" data-tone={notice?.tone}>
          {notice?.text ?? action.description}
        </span>
      </span>
      <span className="settings-row-buttons">
        <button
          type="button"
          className="settings-shortcut-chip"
          data-testid={`settings-shortcut-${action.id}`}
          data-capturing={capturing || undefined}
          data-unbound={binding === null || undefined}
          onClick={onCapture}
        >
          {capturing ? preview || 'Press keys…' : formatBinding(binding, platform)}
        </button>
        <button
          type="button"
          className="settings-secondary-button"
          data-testid={`settings-shortcut-clear-${action.id}`}
          disabled={binding === null}
          onClick={onClear}
        >
          Clear
        </button>
        {overridden && (
          <button
            type="button"
            className="settings-secondary-button"
            data-testid={`settings-shortcut-reset-${action.id}`}
            onClick={onReset}
          >
            Reset
          </button>
        )}
      </span>
    </div>
  )
}
