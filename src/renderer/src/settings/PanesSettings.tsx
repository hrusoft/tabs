import { useSettingsStore } from '../core/store/settingsStore'
import type { SettingsRowSection } from './settingsRows'
import { SettingsRowGroup } from './settingsRows'

// Exported for the coverage witness in __tests__/settingsCoverage.test.tsx:
// nothing ties a new flat Settings key to a row here at compile time (the row
// types check the other direction), so the test asserts every key has a
// control and this is one of the lists it reads.
export const PANES_SECTIONS: SettingsRowSection[] = [
  {
    // Untitled: the page's own <h1> already says "Panes & Tabs" — same
    // pattern as the first section of TerminalSettingsPage/SkillsSettings.
    rows: [
      {
        type: 'checkbox',
        key: 'showNavFlash',
        testId: 'settings-nav-flash-checkbox',
        title: 'Direction overlay',
        description:
          'Show a brief overlay indicating direction when navigating panes with the keyboard.'
      },
      {
        type: 'checkbox',
        key: 'dimInactivePanes',
        testId: 'settings-dim-inactive-panes-checkbox',
        title: 'Dim inactive panes',
        description: "Fade inactive panes' content so the active pane stands out."
      },
      {
        type: 'range',
        key: 'dimInactivePanesIntensity',
        testId: 'settings-dim-inactive-panes-intensity-slider',
        title: 'Dimming intensity',
        description: 'How strongly inactive panes are desaturated and darkened.',
        min: 0,
        max: 1,
        step: 0.01,
        enabledBy: 'dimInactivePanes'
      },
      {
        type: 'checkbox',
        key: 'enableBellIndicator',
        testId: 'settings-bell-indicator-checkbox',
        title: 'Bell indicator',
        description: 'Pulse a bell icon and bounce the Dock icon when a pane signals for attention.'
      },
      {
        type: 'checkbox',
        key: 'enableControlIndicator',
        testId: 'settings-control-indicator-checkbox',
        title: 'Control indicator',
        description:
          "Pulse a robot icon and highlight a pane's own border while another pane is controlling it."
      },
      {
        type: 'checkbox',
        key: 'snapResizeSeparators',
        testId: 'settings-snap-resize-separators-checkbox',
        title: 'Snap resize to aligned separators',
        description:
          "While dragging a pane divider, snap to other dividers' positions when close, to line up pane edges exactly."
      },
      {
        type: 'anchor',
        key: 'newUnpinnedPanePosition',
        testId: 'settings-unpinned-position',
        title: 'New unpinned pane position',
        description:
          'Where a new unpinned pane appears within the pane it was created from. Unpinning an existing pane still lifts it off in place.'
      }
    ]
  }
]

export function PanesSettings() {
  const settings = useSettingsStore()
  return (
    <div data-testid="settings-page-panes">
      <h1 className="settings-page-title">Panes & Tabs</h1>
      {PANES_SECTIONS.map((section, index) => (
        <SettingsRowGroup key={section.title ?? index} section={section} settings={settings} />
      ))}
    </div>
  )
}
