import {
  asRecord,
  type ContentTypeSettingsDescriptor
} from '../../../shared/content/settingsDescriptor'

/**
 * Where `createBrowserPane` (the ctl/tabs-skill verb) places a newly created
 * browser pane relative to the caller's own pane — see handleCreateBrowserPane
 * in ../renderer/browserExternalControl.ts. Has no effect on panes a person
 * opens by hand (New Tab, the split shortcuts, the pane-header button all go
 * through content/placement.ts directly and never read this setting).
 */
export const BROWSER_NEW_PANE_PLACEMENTS = [
  'tab',
  'split-horizontal',
  'split-vertical',
  'unpinned'
] as const

export type BrowserNewPanePlacement = (typeof BROWSER_NEW_PANE_PLACEMENTS)[number]

export const DEFAULT_BROWSER_NEW_PANE_PLACEMENT: BrowserNewPanePlacement = 'tab'

/**
 * `value` as a known placement, or the default for anything else (unset,
 * hand-edited garbage, an older/newer app version's since-renamed value) —
 * the same tolerant-reader shape as resolveSpawnPosition in
 * @shared/model/floating, needed here for the same reason: this value drives
 * a branch in handleCreateBrowserPane, not just a CSS variable, so a caller
 * must never see anything outside the known set.
 */
export function resolveNewPanePlacement(value: unknown): BrowserNewPanePlacement {
  const known = BROWSER_NEW_PANE_PLACEMENTS.find((placement) => placement === value)
  return known ?? DEFAULT_BROWSER_NEW_PANE_PLACEMENT
}

/** The browser content type's slice of Settings.contentTypes. */
export interface BrowserSettings {
  controlledPanePlacement: BrowserNewPanePlacement
}

export const DEFAULT_BROWSER_SETTINGS: BrowserSettings = {
  controlledPanePlacement: DEFAULT_BROWSER_NEW_PANE_PLACEMENT
}

/**
 * Total merge of a persisted browser blob over the defaults. Resolved through
 * resolveNewPanePlacement rather than spread verbatim like a flat boolean
 * would be: everything downstream trusts this value to be one of the four
 * known placements, so garbage is normalized here rather than at every read
 * site.
 */
export function mergeBrowserSettings(persisted: unknown): BrowserSettings {
  const blob = asRecord(persisted)
  return {
    ...DEFAULT_BROWSER_SETTINGS,
    ...blob,
    controlledPanePlacement: resolveNewPanePlacement(blob.controlledPanePlacement)
  }
}

export const browserSettingsDescriptor: ContentTypeSettingsDescriptor<BrowserSettings> = {
  type: 'browser',
  defaults: DEFAULT_BROWSER_SETTINGS,
  merge: mergeBrowserSettings
}
