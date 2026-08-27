import { resolvePluginEntries } from '@shared/plugin/entries'
import { KeyboardIcon, SettingsIcon, SkillIcon, SplitHorizontalIcon } from '../content/icons'
import type { SettingsPluginContext } from '../plugin/settingsApi'
import { createSettingsPluginContext } from '../plugin/settingsContext'
import { GeneralSettings } from './GeneralSettings'
import { KeyboardSettings } from './KeyboardSettings'
import { PanesSettings } from './PanesSettings'
import { SkillsSettings } from './SkillsSettings'
import { hasSettingsPage, registerSettingsPage } from './settingsPageRegistry'

/**
 * The Settings window's activation point: core's own pages, then every
 * package's settings entry — discovered by glob and reconciled against the
 * manifests (shared/plugin/entries.ts), each activated against a context
 * bound to its type. A package with no settings ships no entry and declares
 * none, which is why the browser appears nowhere here rather than as an
 * exemption; the manifest reconciliation also holds the pair the old
 * `ContentTypeIdWithSettings` key enforced at compile time — a settings
 * *descriptor* and a settings *entry* come together or not at all.
 *
 * This glob must stay per-boundary: the Settings window is its own entry
 * point (settings-main.tsx) that never runs registerBuiltins, so globbing a
 * package's *renderer* entry from here would pull xterm and the `<webview>`
 * tag into a window that only draws a sidebar. Each package keeps its
 * settings entry in its own settings/ folder for exactly that reason.
 *
 * Sidebar position comes from `order` — core pages carry their own, and each
 * package's is stamped by its context from its census position — so the
 * *activation sequence* here still carries no meaning, while the sidebar ends
 * up in PLUGIN_PACKAGES order all the same (like the pane-header buttons,
 * arrived at differently).
 */
const settingsEntries = import.meta.glob<{ activate: (ctx: SettingsPluginContext) => void }>(
  '../../../plugins/*/settings/index.ts',
  { eager: true }
)

/**
 * Registers the built-in Settings pages: core's own, then each package's.
 * Called from settings-main.tsx before the first render; guarded so a double
 * call (e.g. React strict-mode dev remounts of the entry) isn't a
 * duplicate-registration error.
 */
export function registerBuiltinSettingsPages(): void {
  if (hasSettingsPage('general')) return

  // Core's pages pin the ends of the sidebar (General 0, Skills 100); content
  // types sit between them.
  registerSettingsPage({
    id: 'general',
    label: 'General',
    Icon: SettingsIcon,
    Component: GeneralSettings,
    order: 0
  })
  registerSettingsPage({
    id: 'panes',
    label: 'Panes & Tabs',
    Icon: SplitHorizontalIcon,
    Component: PanesSettings,
    order: 1
  })
  registerSettingsPage({
    id: 'keyboard',
    label: 'Keyboard',
    Icon: KeyboardIcon,
    Component: KeyboardSettings,
    order: 5
  })
  registerSettingsPage({
    id: 'skills',
    label: 'Skills',
    Icon: SkillIcon,
    Component: SkillsSettings,
    order: 100
  })

  for (const [type, entry] of resolvePluginEntries('settings', settingsEntries)) {
    entry.activate(createSettingsPluginContext(type))
  }
}
