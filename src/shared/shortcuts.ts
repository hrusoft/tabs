/**
 * The app's rebindable keyboard shortcuts: one canonical action registry, one
 * serializable binding representation, and the derivations that carry a single
 * binding to each of the layers that can actually enforce it.
 *
 * Three layers enforce bindings, and a binding change has to reach all of
 * them or it half-works in a way that is very hard to read as a bug:
 *   - a native application-menu accelerator (src/main/menu.ts's buildMenu),
 *   - the renderer's window keydown handler (content/spatialNav.ts),
 *   - and main's `before-input-event` on `<webview>` guests
 *     (src/plugins/browser/main/guestNavKeys.ts), which exists because a focused guest
 *     swallows every keydown before the host window can see it.
 * The nav actions live in the last two *simultaneously* — rebinding only the
 * renderer's copy leaves navigation working everywhere except inside a browser
 * pane. `matchesBinding` below is deliberately shaped to serve both: it takes a
 * plain `KeyChord` rather than a DOM `KeyboardEvent`, so main can feed it an
 * Electron `Input` and this module can stay free of DOM and Electron types.
 * `navDirectionForChord` goes one step further and owns the whole nav lookup,
 * so those two enforcers share the action→direction table as well as the
 * matcher, and each is left with nothing but its own six-line chord adapter.
 */

import type { NavDirection } from './model/navigation'

/** Which platform's modifier conventions to apply. Passed in — `src/shared` can't read `process`. */
export type Platform = 'darwin' | 'other'

/**
 * One key combination, stored by physical key (`KeyboardEvent.code`) rather
 * than by produced character.
 *
 * `code` is layout-independent and unaffected by shift (`Comma` stays `Comma`
 * whether it produces "," or "<"), which makes the renderer matcher exact and
 * the JSON stable. The tradeoff, accepted knowingly: Electron matches *menu*
 * accelerators by character, so on a keyboard layout that moves letters around
 * (AZERTY's A/Q/Z/W), a rebound menu action can end up on a different physical
 * key than the one that was recorded. The renderer-enforced actions are
 * unaffected. See CLAUDE.md.
 */
export interface KeyBinding {
  /** `KeyboardEvent.code` — 'KeyT', 'ArrowLeft', 'Comma', 'Digit1'. */
  code: string
  /** The platform's primary accelerator modifier: ⌘ on macOS, Ctrl elsewhere (Electron's CmdOrCtrl). */
  mod?: boolean
  /**
   * The literal Control key, which on macOS is a modifier of its own (⌃)
   * alongside ⌘. Off macOS Control *is* `mod`, so recording never sets this
   * there and both being set is treated as plain `mod`.
   */
  ctrl?: boolean
  alt?: boolean
  shift?: boolean
}

/** A pressed combination, normalized off whatever event object the caller has. */
export interface KeyChord {
  code: string
  meta: boolean
  ctrl: boolean
  alt: boolean
  shift: boolean
}

export type ShortcutActionId =
  | 'open-settings'
  | 'command-palette'
  | 'new-tab'
  | 'split-horizontal'
  | 'split-vertical'
  | 'new-unpinned-pane'
  | 'close-pane'
  | 'clear-buffer'
  | 'refresh-pane'
  | 'nav-left'
  | 'nav-right'
  | 'nav-up'
  | 'nav-down'

export interface ShortcutActionDef {
  id: ShortcutActionId
  label: string
  description: string
  group: 'Application' | 'Panes & Tabs' | 'Navigation'
  /**
   * Which layer enforces this action, and — for a native menu item — who
   * answers it: `menu` items forward to the renderer's handler table
   * (content/paneShortcuts.ts), `main` items are answered by the menu item's
   * own click handler in the main process, and `renderer` actions are a
   * `keydown` listener with no menu item at all. Two gates read it: the
   * jsdom check that every `menu` action has a renderer handler
   * (`unhandledShortcutActions`), and the e2e menu assertion
   * (e2e/keyboard-shortcuts.spec.ts derives the expected menu items from
   * `layer !== 'renderer'`), which catches a menu action shipped without its
   * paneShortcutItem. It's also the difference between "a rebind takes effect
   * when the menu is rebuilt" and "a rebind takes effect on the next
   * keypress", which matters when one of them looks broken.
   */
  layer: 'main' | 'menu' | 'renderer'
  defaultBinding: KeyBinding
}

/**
 * Every shortcut a user can rebind. Deliberately not every key the app
 * responds to: the stock Electron `role` menu items (Quit, Copy, Undo, Reload,
 * zoom…) keep their OS-standard accelerators and are reserved below instead,
 * and contextual keys scoped to one widget (Escape cancelling a drag, Enter in
 * the address bar) are not shortcuts in this sense at all.
 */
export const SHORTCUT_ACTIONS: readonly ShortcutActionDef[] = [
  {
    id: 'open-settings',
    label: 'Open Settings',
    description: 'Open the Settings window.',
    group: 'Application',
    layer: 'main',
    defaultBinding: { mod: true, code: 'Comma' }
  },
  {
    id: 'command-palette',
    label: 'New Content…',
    description: 'Open the command palette for creating new content.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, code: 'KeyP' }
  },
  {
    id: 'new-tab',
    label: 'New Tab',
    description: 'Open a new tab in the active pane.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, code: 'KeyT' }
  },
  {
    id: 'split-horizontal',
    label: 'New Horizontal Split',
    description: 'Split the active pane horizontally with new content.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, shift: true, code: 'KeyT' }
  },
  {
    id: 'split-vertical',
    label: 'New Vertical Split',
    description: 'Split the active pane vertically with new content.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, alt: true, code: 'KeyT' }
  },
  {
    id: 'new-unpinned-pane',
    label: 'New Unpinned Pane',
    description:
      'Open a new floating, unpinned pane over the active pane, in the position set in Settings.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, alt: true, shift: true, code: 'KeyT' }
  },
  {
    id: 'close-pane',
    label: 'Close Pane',
    description: 'Close the active pane, confirming first if it still has work running.',
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, code: 'KeyW' }
  },
  {
    id: 'clear-buffer',
    label: 'Clear Buffer',
    description: "Clear the active pane's scrollback, where supported.",
    group: 'Panes & Tabs',
    layer: 'menu',
    defaultBinding: { mod: true, code: 'KeyK' }
  },
  {
    id: 'refresh-pane',
    label: 'Refresh',
    description: "Re-read the active pane's content, where supported.",
    group: 'Panes & Tabs',
    layer: 'menu',
    // Frees Electron's stock Reload/Force Reload role items (which used to
    // own CommandOrControl+R and +Shift+R) — see buildMenu's View submenu,
    // hand-spelled without them for exactly this binding.
    defaultBinding: { mod: true, code: 'KeyR' }
  },
  {
    id: 'nav-left',
    label: 'Focus Pane Left',
    description: 'Move pane focus one step left.',
    group: 'Navigation',
    layer: 'renderer',
    defaultBinding: { mod: true, code: 'ArrowLeft' }
  },
  {
    id: 'nav-right',
    label: 'Focus Pane Right',
    description: 'Move pane focus one step right.',
    group: 'Navigation',
    layer: 'renderer',
    defaultBinding: { mod: true, code: 'ArrowRight' }
  },
  {
    id: 'nav-up',
    label: 'Focus Pane Up',
    description: 'Move pane focus one step up.',
    group: 'Navigation',
    layer: 'renderer',
    defaultBinding: { mod: true, code: 'ArrowUp' }
  },
  {
    id: 'nav-down',
    label: 'Focus Pane Down',
    description: 'Move pane focus one step down.',
    group: 'Navigation',
    layer: 'renderer',
    defaultBinding: { mod: true, code: 'ArrowDown' }
  }
]

const ACTION_BY_ID = new Map<string, ShortcutActionDef>(
  SHORTCUT_ACTIONS.map((action) => [action.id, action])
)

/**
 * The definition of `id` — total, since `ShortcutActionId` is derived from
 * SHORTCUT_ACTIONS itself. Callers holding a typed id get the action back
 * without a linear scan and without a defensive miss branch that can't happen.
 */
export function shortcutAction(id: ShortcutActionId): ShortcutActionDef {
  // Non-null: the map is built from the same array the id type comes from.
  return ACTION_BY_ID.get(id)!
}

/**
 * User overrides, sparse: an absent id means "use the default", and an
 * explicitly stored `null` means "the user deliberately unbound this". That
 * distinction is the whole reason this isn't a complete record — a new action
 * shipped in a later version arrives with its default already in effect, with
 * no migration and no way for a stale file to silently unbind it.
 *
 * Keyed by plain string rather than ShortcutActionId so an id written by a
 * newer version survives a round-trip through an older one.
 */
export type ShortcutOverrides = Record<string, KeyBinding | null>

/** The minimum a caller needs for `resolveBinding` — satisfied by `Settings` and by the renderer's store state. */
export interface ShortcutSettingsLike {
  shortcuts: ShortcutOverrides
}

/** The binding in effect for `id`: the user's override, their explicit unbinding, or the default. */
export function resolveBinding(
  settings: ShortcutSettingsLike,
  id: ShortcutActionId
): KeyBinding | null {
  if (Object.hasOwn(settings.shortcuts, id)) return settings.shortcuts[id] ?? null
  return shortcutAction(id).defaultBinding
}

/** True when `id` is bound to something other than its shipped default. */
export function isOverridden(settings: ShortcutSettingsLike, id: ShortcutActionId): boolean {
  return Object.hasOwn(settings.shortcuts, id)
}

/**
 * A stable string identity for a combination, for conflict and reserved-list
 * lookups. Not persisted — `KeyBinding` is the storage format; this is only
 * ever a map key. Exported for its unit tests; `bindingsEqual` is the public
 * form.
 */
export function bindingKey(binding: KeyBinding): string {
  return [
    binding.mod ? 'mod' : '',
    binding.ctrl ? 'ctrl' : '',
    binding.alt ? 'alt' : '',
    binding.shift ? 'shift' : '',
    binding.code
  ].join('+')
}

export function bindingsEqual(a: KeyBinding | null, b: KeyBinding | null): boolean {
  if (a === null || b === null) return a === b
  return bindingKey(a) === bindingKey(b)
}

/**
 * `KeyboardEvent.code` → the token Electron's accelerator parser accepts.
 * Anything absent here has no accelerator spelling, so it can't be bound to a
 * menu action — `toAccelerator` returns null and the capture UI refuses it
 * rather than storing a binding that would silently never fire.
 */
const ACCELERATOR_KEY: Record<string, string> = {
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowUp: 'Up',
  ArrowDown: 'Down',
  Comma: ',',
  Period: '.',
  Slash: '/',
  Backslash: '\\',
  Semicolon: ';',
  Quote: "'",
  BracketLeft: '[',
  BracketRight: ']',
  Minus: '-',
  Equal: '=',
  Backquote: '`',
  Space: 'Space',
  Enter: 'Return',
  Backspace: 'Backspace',
  Delete: 'Delete',
  Insert: 'Insert',
  Home: 'Home',
  End: 'End',
  PageUp: 'PageUp',
  PageDown: 'PageDown'
}

/** `KeyboardEvent.code` → the token a human reads or types for it — 'T', ',', 'Left'. */
function keyToken(code: string): string | null {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3)
  if (/^Digit[0-9]$/.test(code)) return code.slice(5)
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) return code
  return ACCELERATOR_KEY[code] ?? null
}

/**
 * The modifier names for `binding`, in the fixed order every spelling of a
 * combination uses, followed by `key` — the caller's spelling of the key
 * itself, since that is the one part the spellings disagree on (and the one
 * that may have no answer: see `keyToken`).
 *
 * Shared by `toAccelerator`, `formatChordAsQuery` and `formatBinding`'s
 * non-macOS spelling because they differ only in what each modifier is
 * *called*: the rules for which ones appear are the same, including the
 * non-obvious one below that a reader would not think to check in several
 * places.
 */
function chordParts(
  binding: KeyBinding,
  platform: Platform,
  names: { mod: string; ctrl: string; alt: string; shift: string },
  key: string
): string[] {
  const parts: string[] = []
  if (binding.mod) parts.push(names.mod)
  // Off macOS Control is already the platform modifier; emitting it twice
  // would describe a combination the user could never actually press.
  if (binding.ctrl && !(platform === 'other' && binding.mod)) parts.push(names.ctrl)
  if (binding.alt) parts.push(names.alt)
  if (binding.shift) parts.push(names.shift)
  parts.push(key)
  return parts
}

/** How the key reads in the settings list and in a menu — '←', 'Space', ','. */
const DISPLAY_KEY: Record<string, string> = {
  ArrowLeft: '←',
  ArrowRight: '→',
  ArrowUp: '↑',
  ArrowDown: '↓',
  Enter: 'Enter',
  Space: 'Space',
  Backspace: '⌫',
  Delete: '⌦'
}

/**
 * The Electron accelerator string for `binding`, or null when the key has no
 * accelerator spelling. `mod` becomes CommandOrControl so a single stored
 * binding keeps working on both platforms.
 */
export function toAccelerator(binding: KeyBinding, platform: Platform): string | null {
  const key = keyToken(binding.code)
  if (key === null) return null
  return chordParts(
    binding,
    platform,
    { mod: 'CommandOrControl', ctrl: 'Control', alt: 'Alt', shift: 'Shift' },
    key
  ).join('+')
}

/** How `binding` reads to a human — '⌘T' on macOS, 'Ctrl+T' elsewhere. */
export function formatBinding(
  binding: KeyBinding | null,
  platform: Platform,
  unboundLabel = 'Not set'
): string {
  if (!binding) return unboundLabel
  const key = DISPLAY_KEY[binding.code] ?? keyToken(binding.code) ?? binding.code
  if (platform === 'darwin') {
    // The order macOS itself uses in menus, regardless of press order.
    return `${binding.ctrl ? '⌃' : ''}${binding.alt ? '⌥' : ''}${binding.shift ? '⇧' : ''}${
      binding.mod ? '⌘' : ''
    }${key}`
  }
  return chordParts(
    binding,
    platform,
    { mod: 'Ctrl', ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift' },
    key
  ).join('+')
}

/**
 * Whether a pressed chord is exactly `binding` — every modifier compared,
 * including the ones that must be *absent*. That exactness is deliberate:
 * cmd+arrow navigates,
 * but cmd+ctrl+arrow and cmd+shift+arrow deliberately fall through to whatever
 * else wants them.
 *
 * Exported for its unit tests; the enforcers reach it through
 * `navDirectionForChord` below.
 */
export function matchesBinding(
  binding: KeyBinding | null,
  chord: KeyChord,
  platform: Platform
): boolean {
  if (!binding) return false
  if (chord.code !== binding.code) return false
  const expectedMeta = platform === 'darwin' ? !!binding.mod : false
  const expectedCtrl = platform === 'darwin' ? !!binding.ctrl : !!binding.mod || !!binding.ctrl
  return (
    chord.meta === expectedMeta &&
    chord.ctrl === expectedCtrl &&
    chord.alt === !!binding.alt &&
    chord.shift === !!binding.shift
  )
}

/**
 * The four pane-navigation actions, paired with the direction each moves focus.
 *
 * Lives here rather than in either enforcer because both of them need it: the
 * renderer's window keydown handler (content/spatialNav.ts) and main's
 * `before-input-event` on `<webview>` guests (src/plugins/browser/main/guestNavKeys.ts), which
 * exists because a focused guest swallows every keydown. A fifth direction, or
 * a renamed action id, is now one edit rather than two that must agree.
 */
const NAV_ACTIONS: ReadonlyArray<readonly [ShortcutActionId, NavDirection]> = [
  ['nav-left', 'left'],
  ['nav-right', 'right'],
  ['nav-up', 'up'],
  ['nav-down', 'down']
]

/**
 * The direction a nav action moves focus, or undefined for any other action —
 * the same table `navDirectionForChord` walks, for a consumer that already
 * holds an action id rather than a chord (the tui's action dispatch).
 */
export function navDirectionForAction(id: ShortcutActionId): NavDirection | undefined {
  return NAV_ACTIONS.find(([action]) => action === id)?.[1]
}

/**
 * Which direction (if any) a pressed chord moves pane focus — the whole nav
 * lookup, shared by both enforcers so the table and the matching rule can't
 * drift apart between them. Each caller supplies only the adapter from its own
 * event type to a `KeyChord` (a DOM `KeyboardEvent` in the renderer, an
 * Electron `Input` in main) and its own settings source.
 *
 * Bindings are resolved per call rather than cached, so a rebind takes effect
 * on the next keypress — which for main's guests means already-attached ones,
 * not just panes opened afterwards.
 */
export function navDirectionForChord(
  settings: ShortcutSettingsLike,
  chord: KeyChord,
  platform: Platform
): NavDirection | undefined {
  for (const [id, direction] of NAV_ACTIONS) {
    if (matchesBinding(resolveBinding(settings, id), chord, platform)) return direction
  }
  return undefined
}

/**
 * Combinations the stock Electron `role` menu items already own (see
 * buildMenu's appMenu/edit/view/window roles). Binding an action to one of
 * these would leave macOS with two menu items claiming the same key
 * equivalent, which it resolves silently and arbitrarily — the user's Copy
 * would just stop working with no error anywhere. Refused at capture time
 * instead.
 */
const RESERVED: readonly KeyBinding[] = [
  { mod: true, code: 'KeyQ' },
  { mod: true, code: 'KeyH' },
  { mod: true, alt: true, code: 'KeyH' },
  { mod: true, code: 'KeyZ' },
  { mod: true, shift: true, code: 'KeyZ' },
  { mod: true, code: 'KeyY' },
  { mod: true, code: 'KeyX' },
  { mod: true, code: 'KeyC' },
  { mod: true, code: 'KeyV' },
  { mod: true, shift: true, code: 'KeyV' },
  { mod: true, code: 'KeyA' },
  { mod: true, code: 'KeyM' },
  { mod: true, alt: true, code: 'KeyI' },
  { mod: true, shift: true, code: 'KeyI' },
  { mod: true, code: 'Digit0' },
  { mod: true, code: 'Minus' },
  { mod: true, shift: true, code: 'Equal' },
  { mod: true, ctrl: true, code: 'KeyF' }
]

const RESERVED_KEYS = new Set(RESERVED.map(bindingKey))

export function isReservedBinding(binding: KeyBinding): boolean {
  return RESERVED_KEYS.has(bindingKey(binding))
}

/**
 * Every binding needs a real modifier — Shift alone doesn't count. This is
 * what keeps a bare keystroke from being stolen out from under a terminal
 * pane: the renderer's handler runs in the capture phase, ahead of xterm, so a
 * modifier-less binding would make that key unusable in every shell in the app.
 */
export function hasRequiredModifier(binding: KeyBinding): boolean {
  return !!(binding.mod || binding.ctrl || binding.alt)
}

/**
 * A bare ⌃+letter on macOS — Control plus a letter, with neither Command nor
 * Option. Pure key-shape logic, which is all this module can honestly know:
 * whether such a chord is worth warning about depends on what the pane under
 * it does with the key, so the judgement and the wording both live with the
 * UI that renders the warning (see KeyboardSettings.tsx, which knows the app
 * ships a terminal and that ⌃C is the concrete thing at stake).
 */
export function isBareCtrlLetterChord(binding: KeyBinding, platform: Platform): boolean {
  return (
    platform === 'darwin' &&
    !!binding.ctrl &&
    !binding.mod &&
    !binding.alt &&
    /^Key[A-Z]$/.test(binding.code)
  )
}

/** The action currently bound to `binding`, ignoring `except`. Null when the combination is free. */
export function findConflict(
  settings: ShortcutSettingsLike,
  binding: KeyBinding,
  except: ShortcutActionId
): ShortcutActionDef | null {
  const key = bindingKey(binding)
  for (const action of SHORTCUT_ACTIONS) {
    if (action.id === except) continue
    const current = resolveBinding(settings, action.id)
    if (current && bindingKey(current) === key) return action
  }
  return null
}

function asBinding(value: unknown): KeyBinding | null | undefined {
  if (value === null) return null
  if (typeof value !== 'object') return undefined
  const record = value as Record<string, unknown>
  if (typeof record.code !== 'string' || record.code === '') return undefined
  const binding: KeyBinding = { code: record.code }
  if (record.mod === true) binding.mod = true
  if (record.ctrl === true) binding.ctrl = true
  if (record.alt === true) binding.alt = true
  if (record.shift === true) binding.shift = true
  return binding
}

/**
 * Turns whatever was in settings.json into usable overrides. Total by
 * contract, like the rest of migrateSettings: a malformed entry is dropped
 * (falling back to that action's default) rather than throwing, since a throw
 * here would take the *whole* settings file down to defaults.
 *
 * Unknown action ids ride through untouched, in the same forward-compat spirit
 * as `contentTypes`: they're a newer version's actions, and silently deleting
 * them would make a downgrade-then-upgrade round-trip lose real user edits.
 */
export function sanitizeShortcutOverrides(raw: unknown): ShortcutOverrides {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return {}
  const result: ShortcutOverrides = {}
  for (const [id, value] of Object.entries(raw as Record<string, unknown>)) {
    const binding = asBinding(value)
    if (binding !== undefined) result[id] = binding
  }
  return result
}

// ---------------------------------------------------------------------------
// Search-query parsing — the Keyboard settings page's search box
// (KeyboardSettings.tsx) only. Separate from everything above: this isn't
// part of the binding model any enforcer reads, it's a small text grammar
// for typing (or having a pressed chord spell out) a combination like
// "cmd+shift+t" into a plain search field, matched against `resolveBinding`.
// ---------------------------------------------------------------------------

/**
 * The `+`-joined, case-insensitive modifier words a search query may use,
 * folded to the `KeyBinding` field each one sets. `ctrl`/`control` is the one
 * that isn't a plain lookup — see the platform note at its use below.
 */
const MODIFIER_FIELD: Record<string, 'mod' | 'ctrl' | 'alt' | 'shift'> = {
  cmd: 'mod',
  command: 'mod',
  mod: 'mod',
  ctrl: 'ctrl',
  control: 'ctrl',
  alt: 'alt',
  option: 'alt',
  shift: 'shift'
}

/** `ACCELERATOR_KEY` inverted, built once — `parseKeyToken` runs per keystroke. */
const CODE_BY_TOKEN = new Map(
  Object.entries(ACCELERATOR_KEY).map(([code, token]) => [token.toLowerCase(), code])
)

/** Reverse of `keyToken`: the key portion of a search query → a `KeyboardEvent.code`. */
function parseKeyToken(token: string): string | null {
  if (/^[a-z]$/.test(token)) return `Key${token.toUpperCase()}`
  if (/^[0-9]$/.test(token)) return `Digit${token}`
  if (/^f([1-9]|1[0-9]|2[0-4])$/.test(token)) return token.toUpperCase()
  return CODE_BY_TOKEN.get(token) ?? null
}

/**
 * Parses a search-box query as a key combination, or null when it isn't one
 * — including when it's ordinary text that happens to contain a `+`. Requires
 * at least one recognized modifier word and exactly one remaining token that
 * resolves to a key; that isn't just pickiness, it's entailed by
 * `hasRequiredModifier`'s own invariant that every real binding has a
 * modifier, so a modifier-less "chord" could never match one regardless.
 * Order of the tokens doesn't matter — "shift+cmd+n" and "cmd+shift+n" parse
 * identically.
 */
export function parseSearchChord(query: string, platform: Platform): KeyBinding | null {
  const tokens = query
    .split('+')
    .map((token) => token.trim().toLowerCase())
    .filter((token) => token.length > 0)

  const binding: KeyBinding = { code: '' }
  let sawModifier = false
  const keyTokens: string[] = []
  for (const token of tokens) {
    const field = MODIFIER_FIELD[token]
    if (field === undefined) {
      keyTokens.push(token)
      continue
    }
    sawModifier = true
    // Off macOS, physical Control already *is* the platform modifier, so a
    // typed "ctrl" sets `mod` there rather than the separate `ctrl` field mac
    // uses for literal ⌃ — the same split `bindingFromEvent` makes from a real
    // keypress in KeyboardSettings.tsx.
    binding[field === 'ctrl' && platform !== 'darwin' ? 'mod' : field] = true
  }
  if (!sawModifier || keyTokens.length !== 1) return null

  const code = parseKeyToken(keyTokens[0]!)
  if (code === null) return null
  binding.code = code
  return binding
}

/**
 * The inverse of `parseSearchChord`: canonical search-query text for a
 * pressed (or stored) chord — "cmd+shift+t". What gets spliced into the
 * search box when the matching combination is physically pressed while it's
 * focused, so the box ends up holding exactly what parseSearchChord would
 * need to find the same binding again. Shares `toAccelerator`'s composition
 * outright (see `chordParts`) and differs only in what each modifier is
 * called, so the two can't disagree about which modifiers a combination has;
 * the parser above doesn't care about order, so that part is purely what looks
 * natural once typed out.
 */
export function formatChordAsQuery(binding: KeyBinding, platform: Platform): string | null {
  const key = keyToken(binding.code)
  if (key === null) return null
  return chordParts(
    binding,
    platform,
    { mod: platform === 'darwin' ? 'cmd' : 'ctrl', ctrl: 'ctrl', alt: 'alt', shift: 'shift' },
    key
  )
    .join('+')
    .toLowerCase()
}
