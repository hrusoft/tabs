import { sanitizeDisabledContentTypes } from './content/enablement'
import { CONTENT_TYPE_MANIFESTS } from './content/registry'
import { asRecord, type ContentTypeSettingsDescriptor } from './content/settingsDescriptor'
import { DEFAULT_NEW_PANE_SPAWN_POSITION, type NewPaneSpawnPosition } from './model/floating'
import { type ShortcutOverrides, sanitizeShortcutOverrides } from './shortcuts'
import type { ThemeSetting } from './theme'

export interface Settings {
  /**
   * Which color theme the app's chrome paints with, or `system` to follow the
   * OS preference live (see shared/theme.ts). Covers app chrome only — a
   * content type's own colors, notably the terminal's palette under
   * `contentTypes.terminal.appearance`, are user data with their own editor
   * and deliberately do not switch with this.
   */
  colorTheme: ThemeSetting
  /** Whether cmd+arrow pane navigation flashes a direction overlay. */
  showNavFlash: boolean
  /**
   * Whether tabs/panes are saved to disk and restored on the next launch
   * (see main/layout.ts), including each open terminal's live cwd at quit
   * time so a restored terminal reopens in the directory it was in.
   */
  persistLayoutOnExit: boolean
  /** Whether inactive panes' content (not their tab strip/header chrome) is faded, to make the active pane stand out. */
  dimInactivePanes: boolean
  /**
   * Strength of the fade applied by `dimInactivePanes`, from 0 (no effect) to
   * 1 (strongest). Drives both the grayscale amount and the brightness drop
   * together — see the `.pane-dimmed` rule in global.css: `grayscale(V)` and
   * `brightness(1 - 0.7 * V)`, so full intensity still tops out at 30%
   * brightness rather than going fully black.
   */
  dimInactivePanesIntensity: number
  /**
   * Whether a pane signalling for attention (today: a terminal's bell, xterm's
   * onBell from a \x07 byte) flashes a bell icon on its pane/tab handle and,
   * if the app window isn't focused, bounces the Dock icon. Core rather than
   * per-content-type: bellStore is keyed by pane id and content-agnostic, so
   * any content type can raise the same signal.
   */
  enableBellIndicator: boolean
  /**
   * Whether a pane currently owned by another pane through the
   * external-control ownership ledger (see main/externalControl.ts's
   * `ownerOf`) pulses a robot icon and highlights its own content border in
   * light purple. Generalizes enableBellIndicator's mechanism to a different
   * signal — an agent driving this pane via tabs-ctl rather than a terminal
   * bell — with one deliberate difference: this never propagates to a parent
   * tab, since it marks one specific pane being watched, not a subtree
   * demanding attention.
   */
  enableControlIndicator: boolean
  /**
   * Whether dragging a split's resize separator snaps to the position of
   * other separators elsewhere in the layout when the drag gets close to
   * them (see SEPARATOR_SNAP_THRESHOLD_PX in shared/model/separatorSnap.ts),
   * making it easy to produce perfectly aligned pane edges.
   */
  snapResizeSeparators: boolean
  /**
   * Which of nine sections of the pane it was created from a new unpinned
   * (floating) pane appears in. The vocabulary and the geometry both live in
   * shared/model/floating.ts (`NewPaneSpawnPosition`, `spawnRectIn`), beside
   * the rest of the float model rather than here.
   *
   * Governs *creating* an unpinned pane only, never unpinning an existing one
   * — see `unpinPaneAt` in renderer content/floating/unpin.ts, whose doc
   * comment records why wiring this in there would break the second unpin.
   *
   * Not validated on load: an unrecognized value degrades at both read sites
   * through `resolveSpawnPosition`, the same contract `colorTheme` has through
   * `getTheme`.
   */
  newUnpinnedPanePosition: NewPaneSpawnPosition
  /**
   * User overrides for the app's keyboard shortcuts, sparse: an absent action
   * id keeps its shipped default, an explicit `null` means the user unbound it
   * (see ShortcutOverrides in shared/shortcuts.ts, which also holds the action
   * registry and the defaults themselves).
   *
   * Write contract: always written WHOLE. Unlike `contentTypes` below there is
   * no per-key merge anywhere — main's settings:set replaces flat keys
   * wholesale — so a writer holding a stale copy would silently drop every
   * other rebinding. The Settings page always sends the complete record.
   */
  shortcuts: ShortcutOverrides
  /**
   * Content types the user has turned off, by ContentNode.type. Sparse in the
   * "absent means enabled" sense, so a type that ships later defaults on
   * rather than needing every existing settings.json to name it.
   *
   * Flat rather than a flag inside `contentTypes` below: whether a type is
   * offered at all is core's decision about its own UI, not a preference the
   * type owns — and a type must stay disable-able whether or not it
   * contributes a settings blob (all three currently do; nothing requires it). See
   * content/enablement.ts for exactly what disabling does, and for why the
   * gate honours this list for any type while `canDisable` governs only which
   * checkboxes the Settings window offers.
   *
   * Write contract: written WHOLE, like `shortcuts` and unlike `contentTypes`
   * — main's settings:set replaces flat keys wholesale.
   */
  disabledContentTypes: string[]
  /**
   * One opaque blob per content type, keyed by ContentNode.type. Core never
   * reads inside a blob; each type declares its shape, defaults, and merge
   * via ContentTypeSettingsDescriptor (see CONTENT_TYPE_SETTINGS). Write
   * contract: a blob is always written WHOLE — merges happen at this
   * record's level only, in main's settings:set handler and settingsStore's
   * onChange mirror, so a write to one type can never clobber a sibling's.
   */
  contentTypes: Record<string, unknown>
}

/**
 * Every content type that contributes a settings blob — derived from the
 * content-type census (CONTENT_TYPE_MANIFESTS in shared/content/registry.ts)
 * rather than listed again here, so a type appears in exactly one list.
 *
 * Kept at this name and path on purpose: main's settings module reads it twice
 * (migrate and the e2e baseline) and neither needs to know a census exists.
 */
export const CONTENT_TYPE_SETTINGS: readonly ContentTypeSettingsDescriptor[] =
  CONTENT_TYPE_MANIFESTS.flatMap((manifest) => (manifest.settings ? [manifest.settings] : []))

export const DEFAULT_SETTINGS: Settings = {
  // Not `system`: the app had exactly one palette before themes existed, and
  // this is it, so an upgrade is a visual no-op until the user chooses
  // otherwise. It also keeps the e2e suite deterministic — under `system` the
  // resolved theme would depend on the dev machine's OS appearance.
  colorTheme: 'dark',
  showNavFlash: true,
  persistLayoutOnExit: true,
  dimInactivePanes: true,
  dimInactivePanesIntensity: 0.34,
  enableBellIndicator: true,
  enableControlIndicator: true,
  snapResizeSeparators: true,
  // The one corner new unpinned panes used before this was configurable, so
  // nobody's app behaves differently until they touch the picker.
  newUnpinnedPanePosition: DEFAULT_NEW_PANE_SPAWN_POSITION,
  // Empty means "every shortcut is at its default" — the defaults live on the
  // action registry, never copied in here (see shared/shortcuts.ts).
  shortcuts: {},
  // Empty means every content type is enabled. Like every default here it is a
  // shared singleton — `current` in main aliases this whole object after
  // resetSettingsForTests, so this array is replaced on a write, never
  // mutated in place.
  disabledContentTypes: [],
  // Descriptor defaults are shared singletons — never mutate a blob in place
  // (main's resetSettingsForTests aliases this whole object as `current`).
  contentTypes: Object.fromEntries(
    CONTENT_TYPE_SETTINGS.map((d): [string, unknown] => [d.type, d.defaults])
  )
}

/**
 * Turns whatever JSON.parse produced from a settings.json — current shape,
 * the pre-contentTypes flat shape, or garbage — into a complete Settings.
 * Runs on every load, so it must be idempotent (a current-shape file passes
 * through untouched) and total — no code path throws; a throw would wipe the
 * whole file (ContentTypeSettingsDescriptor.migrate carries the chain).
 * Unknown keys ride through at both levels — top-level and unrecognized
 * contentTypes entries (a future plugin's, or a newer version's).
 *
 * Hoisting an older file shape is each content type's own business, through
 * the descriptor's `migrate` hook: this function knows only that a type may
 * claim some root keys, never which. Both halves of that hook — the blob it
 * produces and the root keys it consumed — are applied here, so no legacy
 * schema is named in core. See ContentTypeSettingsDescriptor.migrate for the
 * conflict rule and the totality contract.
 */
export function migrateSettings(parsed: unknown): Settings {
  const record = asRecord(parsed)

  const contentTypes = { ...asRecord(record.contentTypes) }
  // Which root keys the content types have claimed for themselves. Collected
  // rather than listed here: naming them would put one type's legacy schema
  // back into core, which is the whole point of the migrate hook.
  const consumed = new Set<string>()
  for (const descriptor of CONTENT_TYPE_SETTINGS) {
    let blob = contentTypes[descriptor.type]
    if (descriptor.migrate) {
      const hoisted = descriptor.migrate(record, blob)
      blob = hoisted.blob
      for (const key of hoisted.consumed) consumed.add(key)
    }
    contentTypes[descriptor.type] = descriptor.merge(blob)
  }

  // Strip only the hoisted legacy keys; every other unknown key rides through,
  // in the same forward-compat spirit as the merge underneath.
  const rest = Object.fromEntries(
    Object.entries(record).filter(([key]) => !consumed.has(key))
  ) as Record<string, unknown>

  // Sanitized rather than trusted: a hand-edited or truncated file could put
  // anything here, and a malformed entry must degrade to that action's default
  // instead of throwing (which would reset the whole file — see loadSettings).
  const shortcuts = sanitizeShortcutOverrides(record.shortcuts)
  // Same reasoning, and the same totality contract: anything but a list of
  // strings degrades to "nothing is disabled" rather than throwing. Always a
  // fresh array, so `current` can never come to alias DEFAULT_SETTINGS'.
  const disabledContentTypes = sanitizeDisabledContentTypes(record.disabledContentTypes)

  return {
    ...DEFAULT_SETTINGS,
    ...rest,
    shortcuts,
    disabledContentTypes,
    contentTypes
  } as Settings
}
