import {
  asRecord,
  type ContentTypeSettingsDescriptor
} from '../../../shared/content/settingsDescriptor'

/** Shape of the terminal's text cursor — mirrors Terminal.app's CursorType profile key. */
export type TerminalCursorStyle = 'block' | 'bar' | 'underline'

/** The 16-color ANSI palette (8 normal + 8 bright), as hex strings. */
export interface TerminalAnsiColors {
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
}

/** Font and color configuration for every terminal pane — see TerminalRenderer.tsx. */
export interface TerminalAppearance {
  fontFamily: string
  fontSize: number
  lineHeight: number
  cursorStyle: TerminalCursorStyle
  cursorBlink: boolean
  background: string
  foreground: string
  cursorColor: string
  selectionBackground: string
  ansi: TerminalAnsiColors
}

/** The terminal content type's slice of Settings.contentTypes. */
export interface TerminalSettings {
  /** Whether a split/new-tab created from a terminal starts in that terminal's live cwd (see src/plugins/terminal/main/terminal.ts's getTerminalCwd) instead of its stale creation-time one. */
  inheritCwdOnNewPane: boolean
  /** Whether new terminal panes load @xterm/addon-webgl for GPU-accelerated rendering. Only affects panes created after the toggle — see TerminalRenderer.tsx. */
  enableWebglRendering: boolean
  /** Lines of history xterm.js retains above the visible viewport, per pane. Applied live to already-open panes — see TerminalRenderer.tsx. xterm.js's own default (and this setting's default) is 1000; 0 disables scrollback entirely rather than making it unlimited. */
  scrollback: number
  /** Font and color configuration applied to every terminal pane. */
  appearance: TerminalAppearance
}

/**
 * Seeded from a real macOS Terminal.app "Clear Dark" profile (decoded via
 * NSKeyedUnarchiver) rather than an arbitrary palette, so first run already
 * looks like a plausible terminal theme instead of a placeholder. A shared
 * singleton like DEFAULT_SETTINGS — no generated ids involved, so a plain
 * literal is fine to reuse across calls (contrast with DEFAULT_LAYOUT in
 * main/layout.ts, which must be computed once because it mints a uuid).
 */
export const DEFAULT_TERMINAL_APPEARANCE: TerminalAppearance = {
  fontFamily: 'JetBrains Mono NL',
  fontSize: 15,
  lineHeight: 1,
  cursorStyle: 'bar',
  cursorBlink: true,
  background: '#06225f',
  foreground: '#e0e0e0',
  cursorColor: '#ffffff',
  selectionBackground: '#273d4c',
  ansi: {
    black: '#35424c',
    red: '#b45648',
    green: '#6caa71',
    yellow: '#c4ac62',
    blue: '#6d96b4',
    magenta: '#bd7bcd',
    cyan: '#7ccbcd',
    white: '#dee5eb',
    brightBlack: '#465c6d',
    brightRed: '#df6c5a',
    brightGreen: '#79be7e',
    brightYellow: '#e5c872',
    brightBlue: '#67b5ed',
    brightMagenta: '#d389e5',
    brightCyan: '#84dde0',
    brightWhite: '#e5eff5'
  }
}

export const DEFAULT_TERMINAL_SETTINGS: TerminalSettings = {
  inheritCwdOnNewPane: true,
  enableWebglRendering: true,
  scrollback: 1000,
  appearance: DEFAULT_TERMINAL_APPEARANCE
}

/**
 * Total merge of a persisted terminal blob over the defaults. `appearance`
 * (and its nested `ansi` palette) is merged one level deeper than the rest:
 * a plain spread only fills in a *missing* `appearance` key wholesale, so a
 * settings.json written before some future new appearance field was added
 * would otherwise carry that field as `undefined` forever instead of falling
 * back to its default like every flat key does for free. Every slot goes
 * through asRecord, so garbage anywhere degrades to defaults for that slot
 * rather than throwing (the descriptor contract).
 */
function mergeTerminalSettings(persisted: unknown): TerminalSettings {
  const blob = asRecord(persisted)
  const appearance = asRecord(blob.appearance)
  // The cast is sound by construction: defaults underneath fill every key,
  // and like the pre-namespace flat merge this deliberately trusts persisted
  // primitives' types rather than validating them field by field.
  return {
    ...DEFAULT_TERMINAL_SETTINGS,
    ...blob,
    appearance: {
      ...DEFAULT_TERMINAL_APPEARANCE,
      ...appearance,
      ansi: { ...DEFAULT_TERMINAL_APPEARANCE.ansi, ...asRecord(appearance.ansi) }
    }
  } as TerminalSettings
}

/**
 * The three root keys the terminal owned before `Settings.contentTypes`
 * existed: two flat booleans, plus a `terminal` key that *was* the appearance
 * object (not a settings blob with an `appearance` inside it — hence the
 * asymmetry below).
 *
 * Returned as `consumed` on every call, not only when one was present, so a
 * current-shape file that still carries a stale copy gets it stripped too.
 * One table drives both the hoists and the consumed list — a legacy key added
 * to one but not the other is the "persisted forever at both levels" failure
 * the descriptor contract calls out.
 */
const LEGACY_KEY_MAP = [
  ['inheritCwdOnNewPane', 'inheritCwdOnNewPane'],
  ['enableWebglRendering', 'enableWebglRendering'],
  // The old top-level `terminal` key was just the appearance object.
  ['terminal', 'appearance']
] as const

const LEGACY_ROOT_KEYS = LEGACY_KEY_MAP.map(([legacyKey]) => legacyKey)

/**
 * Hoists the pre-`contentTypes` flat terminal keys into the namespaced blob.
 *
 * Only fills keys that are ABSENT, so the namespaced value wins on conflict.
 * Legacy keys reappearing beside a `contentTypes` blob means an older app
 * version re-wrote the file (old versions preserve unknown keys, so the blob
 * survives a downgrade round-trip), and that version's flat keys came from
 * *its* defaults rather than the user's migrated values — preferring the blob
 * is the loss-proof direction, and edits made while downgraded are knowingly
 * discarded.
 *
 * Total by the descriptor contract: BOTH arguments go through `asRecord`
 * before anything reads them, and everything after that is an `in` check on a
 * plain object, so no input shape can throw. The root is guarded even though
 * migrateSettings only ever passes it an `asRecord` result — `in` against
 * undefined is a TypeError, and the cost of being wrong about who calls this
 * is a silently wiped settings file (see
 * ContentTypeSettingsDescriptor.migrate).
 */
export function migrateTerminalSettings(
  legacyRoot: Record<string, unknown>,
  blob: unknown
): { blob: TerminalSettings | Record<string, unknown>; consumed: readonly string[] } {
  const root = asRecord(legacyRoot)
  const terminal = { ...asRecord(blob) }
  for (const [legacyKey, blobKey] of LEGACY_KEY_MAP) {
    if (!(blobKey in terminal) && legacyKey in root) {
      terminal[blobKey] = root[legacyKey]
    }
  }
  return { blob: terminal, consumed: LEGACY_ROOT_KEYS }
}

export const terminalSettingsDescriptor: ContentTypeSettingsDescriptor<TerminalSettings> = {
  type: 'terminal',
  defaults: DEFAULT_TERMINAL_SETTINGS,
  merge: mergeTerminalSettings,
  migrate: migrateTerminalSettings,
  // The e2e suite reads terminal contents as DOM text (the prompt wait in
  // e2e/helpers/terminal.ts, and every `toContainText` against a terminal), but
  // @xterm/addon-webgl paints to a canvas and leaves `.xterm-rows` empty — so
  // with the shipping default every terminal-dependent test would wait out its
  // timeout against text that will never arrive. Baseline only: terminal
  // .spec.ts's "enabling WebGL rendering…" test ticks the real checkbox and
  // still covers the WebGL path.
  testBaseline: { enableWebglRendering: false }
}
