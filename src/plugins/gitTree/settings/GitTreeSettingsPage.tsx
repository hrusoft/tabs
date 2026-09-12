import type { PluginSettingsPageDef } from '../../../renderer/src/plugin/settingsApi'
import { SettingsCheckboxRow } from '../../../renderer/src/plugin/settingsApi'
import { GitTreeIcon } from '../renderer/gitTreeIcons'
import { updateGitTreeSettings, useGitTreeSetting } from '../renderer/gitTreeSettingsAccess'
import { manifest as gitTreeManifest } from '../shared/manifest'

function GitTreeSettingsPage() {
  const autoRefreshOnFocus = useGitTreeSetting((settings) => settings.autoRefreshOnFocus)
  const showAuthorColumn = useGitTreeSetting((settings) => settings.showAuthorColumn)
  const showDateColumn = useGitTreeSetting((settings) => settings.showDateColumn)

  return (
    <div data-testid="settings-page-gitTree">
      <h1 className="settings-page-title">Git tree</h1>
      <section className="settings-section">
        <SettingsCheckboxRow
          testId="settings-auto-refresh-checkbox"
          title="Auto-refresh on focus"
          description="Re-read a git tree pane's history whenever it becomes active while the window is focused."
          checked={autoRefreshOnFocus}
          onChange={(checked) => updateGitTreeSettings({ autoRefreshOnFocus: checked })}
        />
        <SettingsCheckboxRow
          testId="settings-show-author-column-checkbox"
          title="Show author column"
          description="Show who authored each commit in the commit list, alongside its hash and message."
          checked={showAuthorColumn}
          onChange={(checked) => updateGitTreeSettings({ showAuthorColumn: checked })}
        />
        <SettingsCheckboxRow
          testId="settings-show-date-column-checkbox"
          title="Show date column"
          description="Show each commit's date in the commit list, alongside its hash and message."
          checked={showDateColumn}
          onChange={(checked) => updateGitTreeSettings({ showDateColumn: checked })}
        />
      </section>
    </div>
  )
}

/**
 * The git tree's sidebar contribution — registered by this package's settings
 * `activate`. Id and label come from the shared census, same as the
 * terminal's page, so the `settings-tab-gitTree` test id and the sidebar text
 * follow the same source as the pane header's.
 */
export const gitTreeSettingsPageDef: PluginSettingsPageDef = {
  id: gitTreeManifest.type,
  label: gitTreeManifest.displayName,
  Icon: GitTreeIcon,
  Component: GitTreeSettingsPage
}
