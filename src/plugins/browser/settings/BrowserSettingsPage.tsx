import type { PluginSettingsPageDef } from '../../../renderer/src/plugin/settingsApi'
import { SettingsSelectRow } from '../../../renderer/src/plugin/settingsApi'
import { BrowserIcon } from '../renderer/browserIcons'
import { updateBrowserSettings, useBrowserSetting } from '../renderer/browserSettingsAccess'
import { manifest as browserManifest } from '../shared/manifest'
import { BROWSER_NEW_PANE_PLACEMENTS, type BrowserNewPanePlacement } from '../shared/settings'

const PLACEMENT_LABELS: Record<BrowserNewPanePlacement, string> = {
  tab: 'New tab',
  'split-horizontal': 'Horizontal split',
  'split-vertical': 'Vertical split',
  unpinned: 'Unpinned window'
}

/** Built from the shared list, so a placement added there can't be missing here. */
const PLACEMENT_OPTIONS = BROWSER_NEW_PANE_PLACEMENTS.map((value) => ({
  value,
  label: PLACEMENT_LABELS[value]
}))

/**
 * The browser content type's settings page — currently a single row. All
 * writes go through updateBrowserSettings, which persists the whole browser
 * blob (the contentTypes write contract).
 */
function BrowserSettingsPage() {
  const browser = useBrowserSetting((settings) => settings)

  return (
    <div data-testid="settings-page-browser">
      <h1 className="settings-page-title">Browser</h1>
      <section className="settings-section">
        <SettingsSelectRow
          testId="settings-browser-controlled-pane-placement-select"
          title="New pane placement"
          description="Where a browser pane created by an agent (via the tabs skill's createBrowserPane) appears relative to the pane that created it."
          value={browser.controlledPanePlacement}
          options={PLACEMENT_OPTIONS}
          onChange={(controlledPanePlacement) => updateBrowserSettings({ controlledPanePlacement })}
        />
      </section>
    </div>
  )
}

/**
 * The browser's sidebar contribution — registered by this package's settings
 * `activate`. Id and label come from the shared census, matching the pane
 * header's own source (see shared/content/registry.ts).
 */
export const browserSettingsPageDef: PluginSettingsPageDef = {
  id: browserManifest.type,
  label: browserManifest.displayName,
  Icon: BrowserIcon,
  Component: BrowserSettingsPage
}
