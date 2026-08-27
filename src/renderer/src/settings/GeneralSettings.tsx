import { isContentTypeEnabled, togglableContentTypes } from '@shared/content/enablement'
import { themeSettingOptions } from '@shared/theme'
import { useSettingsStore } from '../core/store/settingsStore'
import type { SettingsRowSection } from './settingsRows'
import { SettingsCheckboxRow, SettingsRowGroup } from './settingsRows'

// Exported for the coverage witness in __tests__/settingsCoverage.test.tsx:
// nothing ties a new flat Settings key to a row here at compile time (the row
// types check the other direction), so the test asserts every key has a
// control and this is one of the lists it reads.
export const GENERAL_SECTIONS: SettingsRowSection[] = [
  {
    title: 'Appearance',
    rows: [
      {
        type: 'select',
        key: 'colorTheme',
        testId: 'settings-color-theme-select',
        title: 'Color theme',
        description:
          'Colors for the app\'s own chrome. "System" follows the OS appearance, including while the app is running.',
        // Derived from the theme registry, so shipping a third theme adds an
        // option here with no edit to this file — see shared/theme.ts.
        options: themeSettingOptions()
      }
    ]
  },
  {
    title: 'Startup',
    rows: [
      {
        type: 'checkbox',
        key: 'persistLayoutOnExit',
        testId: 'settings-persist-layout-checkbox',
        title: 'Restore layout on relaunch',
        description: 'Reopen your tabs and panes, and what each was showing, when relaunching.'
      }
    ]
  }
]

/**
 * One checkbox per content type the census marks as togglable, driven by
 * `togglableContentTypes()` — so a type that ships later appears here with no
 * edit to this file, which is what `canDisable` on the manifest is for.
 *
 * Not a `SettingsRowSection` like the groups above: those rows are typed
 * against a boolean/string/number key of `Settings`, and this section drives a
 * single `string[]`. It composes the bare `SettingsCheckboxRow` instead, the
 * same way a content type's own settings page does.
 *
 * The copy is deliberately generic and derived from each manifest's
 * `displayName`, so core names no content type. Unchecking is never
 * destructive: the type's own settings blob is untouched, and its open panes
 * keep running — only new ones are refused.
 */
function ContentTypesSection({
  disabledContentTypes,
  onChange
}: {
  disabledContentTypes: string[]
  onChange: (next: string[]) => void
}) {
  const manifests = togglableContentTypes()
  if (manifests.length === 0) return null
  return (
    <section className="settings-section">
      <h3 className="settings-section-title">Content types</h3>
      {manifests.map(({ type, displayName }) => {
        const enabled = isContentTypeEnabled(disabledContentTypes, type)
        return (
          <SettingsCheckboxRow
            key={type}
            testId={`settings-content-type-${type}-checkbox`}
            title={displayName}
            description={`Offer new ${displayName.toLowerCase()} panes in pane headers, keyboard shortcuts and to agents. Panes already open keep working either way.`}
            checked={enabled}
            onChange={(checked) =>
              // Always a fresh array — the setting is written whole, and
              // DEFAULT_SETTINGS' own copy is a shared singleton.
              onChange(
                checked
                  ? disabledContentTypes.filter((entry) => entry !== type)
                  : [...disabledContentTypes, type]
              )
            }
          />
        )
      })}
    </section>
  )
}

export function GeneralSettings() {
  const settings = useSettingsStore()
  return (
    <div data-testid="settings-page-general">
      <h1 className="settings-page-title">General</h1>
      {GENERAL_SECTIONS.map((section) => (
        <SettingsRowGroup key={section.title} section={section} settings={settings} />
      ))}
      <ContentTypesSection
        disabledContentTypes={settings.disabledContentTypes}
        onChange={(next) => settings.setSetting('disabledContentTypes', next)}
      />
    </div>
  )
}
